import Foundation

/// One completed active-transfer measurement from the source IO read path.
public struct AetherThroughputSample: Sendable, Equatable {
    /// Measured client<-origin throughput over the burst's ACTIVE transfer time.
    public let bitsPerSecond: Int
    /// Bytes counted toward the measurement (warm-up deliveries excluded).
    public let bytes: Int64
    /// Active transfer time the bytes were counted over.
    public let activeMs: Int
    /// The burst ended because the forward buffer hit high water and the reader parked the
    /// transfer. The link was never asked for more, so `bitsPerSecond` is a LOWER BOUND on
    /// capacity, not a measurement of it. A consumer deciding to step quality UP must treat a
    /// saturated sample as "at least this fast" or our own backpressure suppresses every step-up.
    public let saturated: Bool
}

/// Active-transfer throughput meter for the source IO read path.
///
/// # Why bytes / wall-clock is wrong here
///
/// `AVIOReader` deliberately parks the HTTP transfer once the forward window passes high water and
/// resumes it when the consumer drains to low water. On a 25.2 Mbps direct-play MKV the measured
/// duty cycle was `pumpSusp=1` in 40 of 41 memprobes — the connection is idle ~97% of wall clock by
/// design. Dividing delivered bytes by elapsed wall clock therefore reconstructs the MEDIA bitrate
/// (that is precisely what the backpressure loop regulates to) and says nothing about how fast the
/// link actually is. An adaptive-bitrate consumer fed that number can never step up, because the
/// number is pinned to the rate it is already playing at.
///
/// # What this measures instead
///
/// Only the time BETWEEN deliveries of an unsuspended transfer, which is the only interval during
/// which we were genuinely asking the origin for bytes and waiting on the link:
///
///   - a burst opens on the first delivery after any idle period,
///   - `warmupNs` after the burst opens is discarded (TCP restarts its congestion window after a
///     park, so the first deliveries dribble and would understate the link),
///   - each subsequent delivery adds `now - lastDelivery` to active time and its bytes to the
///     numerator,
///   - a gap longer than `maxGapNs` is not link latency, it is a park / origin stall / keep-warm
///     idle, so it closes the burst instead of being counted,
///   - a burst only becomes a sample once it covers `minActiveNs` AND `minBytes`, which throws away
///     keep-warm top-ups of a few hundred KB whose implied rate is meaningless.
///
/// Pure value logic with an injected clock so every rule above is unit-testable without a socket,
/// the same shape as `SourceThrottle`.
struct SourceThroughputMeter {

    struct Config: Equatable, Sendable {
        var enabled: Bool = true
        /// Discarded after a burst opens (post-park congestion-window restart).
        var warmupNs: UInt64 = 250_000_000
        /// An inter-delivery gap longer than this ends the burst rather than counting as transfer time.
        var maxGapNs: UInt64 = 500_000_000
        /// A burst must cover at least this much active time to become a sample.
        var minActiveNs: UInt64 = 300_000_000
        /// ...and at least this many bytes.
        var minBytes: Int64 = 512 * 1024

        static let disabled = Config(enabled: false)
    }

    var config: Config

    private var inBurst = false
    private var burstStartedAt: UInt64 = 0
    private var lastDeliveryAt: UInt64 = 0
    private var activeNs: UInt64 = 0
    private var activeBytes: Int64 = 0
    /// Bursts that ended without qualifying, awaiting collection by the owner. Published so a
    /// device trace can distinguish "the link is quiet" from "the filters reject everything" —
    /// from JS those look identical, because both produce no samples.
    private var rejectedPending = 0

    init(config: Config = Config()) {
        self.config = config
    }

    /// Drop all in-flight burst state. Used on generation change, seek discontinuity and close:
    /// bytes measured against a connection that no longer exists must never join a later burst.
    mutating func reset() {
        inBurst = false
        burstStartedAt = 0
        lastDeliveryAt = 0
        activeNs = 0
        activeBytes = 0
    }

    /// Record one delivery from an UNSUSPENDED transfer. Returns a sample when this delivery's
    /// leading gap proved the previous burst had already ended.
    mutating func noteDelivery(bytes: Int, nowNs: UInt64) -> AetherThroughputSample? {
        guard config.enabled, bytes > 0 else { return nil }
        guard inBurst else {
            openBurst(at: nowNs)
            return nil
        }
        let gap = nowNs &- lastDeliveryAt
        if gap > config.maxGapNs {
            let completed = closeBurst(saturated: false)
            openBurst(at: nowNs)
            return completed
        }
        // Count the interval only when BOTH of its endpoints are past warm-up, so a single gap
        // never straddles the boundary and re-imports the dribble we meant to discard.
        if lastDeliveryAt &- burstStartedAt >= config.warmupNs {
            activeNs &+= gap
            activeBytes &+= Int64(bytes)
        }
        lastDeliveryAt = nowNs
        return nil
    }

    /// End the current burst. `saturated` is true when the reader parked the transfer at high
    /// water (the sample is then a lower bound, see `AetherThroughputSample.saturated`).
    mutating func end(saturated: Bool) -> AetherThroughputSample? {
        guard config.enabled, inBurst else {
            reset()
            return nil
        }
        return closeBurst(saturated: saturated)
    }

    /// Take and clear the pending rejected-burst count.
    mutating func drainRejected() -> Int {
        let n = rejectedPending
        rejectedPending = 0
        return n
    }

    private mutating func openBurst(at nowNs: UInt64) {
        inBurst = true
        burstStartedAt = nowNs
        lastDeliveryAt = nowNs
        activeNs = 0
        activeBytes = 0
    }

    private mutating func closeBurst(saturated: Bool) -> AetherThroughputSample? {
        let ns = activeNs
        let bytes = activeBytes
        reset()
        guard ns >= config.minActiveNs, bytes >= config.minBytes, ns > 0 else {
            if bytes > 0 { rejectedPending += 1 }
            return nil
        }
        let bps = Double(bytes) * 8.0 * 1_000_000_000.0 / Double(ns)
        guard bps.isFinite, bps > 0 else { return nil }
        return AetherThroughputSample(
            bitsPerSecond: Int(bps.rounded()),
            bytes: bytes,
            activeMs: Int((Double(ns) / 1_000_000.0).rounded()),
            saturated: saturated)
    }
}
