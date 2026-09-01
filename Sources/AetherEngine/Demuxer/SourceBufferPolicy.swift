import Foundation

// MARK: - Ownership after the 6.25.4 upstream rebase
//
// Upstream rewrote the persistent source reader's flow control between 5.23.12 and 6.25.4
// (#220 bounded ranges, #310 end-at-high-water + refill-at-low-water, #347 audio/video
// decoupling). That work supersedes the reader-side half of this file, so the fork now PREFERS
// upstream's implementation and this file is reduced to the host tuning + telemetry channel.
//
// LIVE (still drive real behaviour on this build):
//   • enabled / lowWaterSeconds / highWaterSeconds / maxWindowBytes
//     -> AVIOReader's upstream end-at-high-water / frontier-refill mechanism. The mechanism stays
//        upstream; only its byte thresholds are resolved from media time after stream probing.
//   • latencyAdaptive* -> grows the requested time cushion from observed response-header latency.
//   • starvationHoldEnabled / starvationHoldLeadSeconds / starvationResumeLeadSeconds
//     -> SWStarvationHoldPolicy, the one source-starvation case upstream still cannot see
//        (its guard runs at the top of the demux loop, which is blocked inside the stalled read).
//   • throughput* -> SourceThroughputMeter, wired into AVIOReader.appendPersistentData. Upstream's
//     own throughput figure measures the LIVE feeder (LiveTelemetrySampler), not this VOD reader,
//     and FlexUI's Auto-quality ABR ladder has no other measured client rate on this lane.
//
// INERT (accepted and reported for bridge compatibility; upstream owns the behaviour now):
//   • hardCapMultiplier / keepWarmSeconds / blockSizeKB / useBlockRing / lookbackMB /
//     seekKeepForwardMB / breaker* (the upstream bounded-range reader does not park or hard-cap).
//   • replaceOnConnectionLoss / proactive* / capResumeAtLowWater
//     -> upstream 4c6fa01e + 464ffe6e refill backpressure-ended AND faulted connections early,
//        with their own failure accounting and backoff.
// `resolve()`, `decideProactiveReplace` and `shouldCapRefill` are retained with their tests as the
// documented record of the superseded decision, and so a future divergence can be re-armed without
// re-deriving it. They are not called by the reader on this build.

/// Time-aware forward-buffer policy for the persistent (playback) source reader.
///
/// # Why this exists
///
/// `AVIOReader`'s persistent path historically bounded its sliding window with two FIXED BYTE
/// watermarks: suspend the transfer above 16 MB, resume it below 8 MB (#174/#220). Bytes are the
/// wrong unit for a playback cushion. Measured on Apple TV against a 25.2 Mbps direct-play MKV:
///
///   - 8 MB low water  = 2.66 s of media. That is the ENTIRE margin available when the transfer
///     is resumed, i.e. the reader wakes a fully idle HTTP connection with 2.66 s left to live.
///   - 16 MB high water = 5.33 s, so the cycle repeats every ~2.66 s: ~22 suspend/resume rounds
///     per minute, ~1000 per 45-minute episode.
///   - Field capture (`logs/tvos-metro.log`, 2026-08-02): `pumpSusp=1` in 40 of 41 memprobes, so
///     the connection is parked ~97% of wall clock. Two reads then blocked 3.003 s and 3.810 s
///     with `reconnects=0 backoff=0ms connect=0ms lockWait=0ms unaccounted=0ms` — the connection
///     was never lost; the origin simply did not resume at rate, and 2.66 s of cushion ran out.
///
/// The same 8 MB is 0.84 s at 80 Mbps. A byte watermark silently gets MORE fragile exactly where
/// the media is most demanding, which is backwards.
///
/// # What the industry does
///
/// Every mainstream player sizes its forward buffer in TIME, with bytes only as a memory ceiling:
///
///   - Media3 / ExoPlayer `DefaultLoadControl` (verified in androidx/media `release`):
///     `DEFAULT_MIN_BUFFER_MS = 50_000`, `DEFAULT_MAX_BUFFER_MS = 50_000`,
///     `DEFAULT_BUFFER_FOR_PLAYBACK_MS = 1000`, `DEFAULT_TARGET_BUFFER_BYTES = LENGTH_UNSET`
///     (derived from the selected tracks rather than fixed), and a per-role allocation ceiling of
///     `DEFAULT_VIDEO_BUFFER_SIZE = 2000 * 64 KB = 128 MB`. Time first, bytes as the ceiling.
///     Note `DEFAULT_MIN_BUFFER_FOR_LOCAL_PLAYBACK_MS = 1000`: Media3 only drops to a 1 s cushion
///     for genuinely LOCAL files. An HTTP origin — which is what this reader always talks to,
///     even on a LAN — gets the 50 s policy.
///   - AVFoundation `AVPlayerItem.preferredForwardBufferDuration` is a DURATION, defaults to 0
///     ("let the system choose"), and Apple documents that small values increase stalling.
///     `AVPlayer.automaticallyWaitsToMinimizeStalling` exists for the same reason.
///
/// So the defaults below (15 s resume / 30 s target) are conservative relative to Media3's 50 s,
/// and are ~6x the cushion and ~1/6 the restart count of the stock byte policy.
///
/// # Deliberate design choices
///
///   - **Suspension is not eliminated.** `suspend()`/`resume()` on the data task is the only
///     contractual flow control URLSession offers; #174 proved that blocking the delegate instead
///     lets CFNetwork buffer without bound until jetsam. So this keeps the mechanism and fixes the
///     THRESHOLDS, which is what the field data indicts.
///   - **`keepWarmSeconds` bounds how long the socket may stay fully idle.** The observed failure
///     is a COLD restart: the origin here is Node `fs.createReadStream(...).pipe(res)` over an SMB
///     mount, and a multi-second park lets that pipeline (and TCP's congestion window, via
///     slow-start-after-idle) go cold. Resuming early tops the window back up to the high water in
///     small increments instead of one large cold refill, and has the side effect of keeping the
///     resident window near the high water rather than sawtoothing down to the low water.
///   - **`maxWindowBytes` is a hard memory ceiling.** 30 s at 80 Mbps is 300 MB, which this device
///     class cannot afford on top of a ~520 MB RSS. The resolver clamps, and `resolve()` reports
///     which bound won so the log states the APPLIED value, never the requested one.
public struct AetherSourceBufferPolicy: Sendable, Equatable {

    /// Master switch. `false` reproduces the stock byte watermarks and the stock contiguous
    /// window EXACTLY, so the shipped default is the known-good path (AGENTS.md: new native
    /// playback behaviour ships off until explicitly enabled on device).
    public var enabled: Bool

    /// Resume the suspended transfer when the forward buffer falls below this many seconds.
    public var lowWaterSeconds: Double

    /// Suspend the transfer once the forward buffer exceeds this many seconds.
    public var highWaterSeconds: Double

    /// Absolute ceiling on the resident forward window, whatever the duration targets ask for.
    public var maxWindowBytes: Int

    /// Grow the low-water target when observed response-header latency plus the safety margin is
    /// larger than `lowWaterSeconds`. The configured low water remains the floor.
    public var latencyAdaptiveEnabled: Bool
    public var latencySafetySeconds: Double
    public var latencyHistoryLimit: Int
    public var latencyMaxSeconds: Double

    /// `hardCap = highWater * this`. The hard cap is #220's bound for a transport that ignores
    /// `suspend()`; past it the connection is ended and re-requested at the frontier.
    public var hardCapMultiplier: Double

    /// Longest the data task may stay suspended before it is resumed anyway, seconds.
    /// `0` disables keep-warm (pure hysteresis, the stock shape at the new thresholds).
    ///
    /// INDEPENDENT of `enabled`. The 2026-08-03 field capture lost a connection that was parked
    /// under the STOCK watermarks, so gating this behind the time-based sizing would leave the
    /// shipped default configuration unprotected. It costs no extra memory.
    public var keepWarmSeconds: Double

    /// Replace a persistent connection the moment its loss is reported, at the window frontier,
    /// instead of waiting for the forward buffer to drain to zero.
    ///
    /// MEASURED (Apple TV, 2026-08-03): a parked connection was reported dead at `17:34:22.458Z`
    /// and the reader did not open a replacement until `17:34:46.874Z` — 24.416 s later, once
    /// `pumpAheadMB` hit 0 — whereupon the replacement's first byte arrived in 28 ms. The read
    /// loop only consults `connEnded` after the window has drained at the cursor, so a loss that
    /// happens while comfortably buffered is known and deliberately ignored until starvation.
    ///
    /// ALSO INDEPENDENT of `enabled`, and DEFAULT ON: unlike the watermark sizing this is not a
    /// tuning experiment with a memory cost, it is a defect fix for a path that currently
    /// guarantees a multi-second freeze. It issues exactly the request the drain path would have
    /// issued (`bytes=<frontier>-`), only without first burning the buffer. Its own kill switch.
    public var replaceOnConnectionLoss: Bool

    /// Consecutive replacements that die before delivering a byte, after which proactive
    /// replacement stops for the session and recovery returns to the drain path — which owns
    /// backoff, Retry-After and the give-up budget. Real read progress re-arms it.
    public var proactiveDeadStreakLimit: Int

    /// Floor on the interval between proactive replacements, so a flapping source cannot become
    /// a reconnect storm.
    public var proactiveMinIntervalMs: Int

    /// Re-request a hard-cap-ended connection once the forward buffer drains to the LOW water,
    /// instead of waiting for it to drain to zero.
    ///
    /// MEASURED (Apple TV, 2026-08-14 16:41 capture): a #220 hard-cap end leaves no task for the
    /// low-water hysteresis to `resume()`, so recovery deferred to the drain path — which only
    /// fires when `available == 0` at the read cursor. Every drain therefore passes through a
    /// zero-cushion moment (`bufUnder=118` that session, one per ~90 s of playback), and the
    /// origin's header latency converts 1:1 into a freeze: gen=13 answered in 21 ms (invisible),
    /// gen=14 took 6412 ms (a 6.4 s on-screen freeze, then a fast catch-up).
    ///
    /// This restores the hysteresis for the taskless case: when the undrained remainder crosses
    /// `lowWaterBytes`, issue exactly the frontier continuation the drain path would have issued
    /// (`bytes=<frontier>-`, window preserved) — only with the low-water cushion still in hand.
    /// INDEPENDENT of `enabled` and DEFAULT ON, same rationale as `replaceOnConnectionLoss`:
    /// this is a defect fix with no memory cost (the window is already bounded by the hard cap),
    /// not a sizing experiment. Its own kill switch.
    public var capResumeAtLowWater: Bool

    /// Pause the VOD master clock while the source has genuinely starved the audio feed, and
    /// resume IN PLACE once refilled — instead of letting the free-running synchronizer outrun
    /// the stall and forcing a visible fast-forward catch-up.
    ///
    /// Same 2026-08-14 capture: during the 6.4 s read stall `clockS` ran 2033.73 → 2040.27 while
    /// `lastFedPts` sat at 2035.20 (`leadS=-5.07 decision=STARVED`); on refill the pipeline raced
    /// through ~8.4 s of media in 2 s to rejoin the runaway clock. Live sessions already pause
    /// the clock to rebuffer (`AudioLookaheadPolicy.clockAction`); this extends the same behavior
    /// to VOD, driven from the host's timer tick because the demux thread is blocked inside the
    /// stalled read. See `SWStarvationHoldPolicy`.
    public var starvationHoldEnabled: Bool
    /// Engage the hold when the fed-audio lead over the clock falls to this many seconds.
    public var starvationHoldLeadSeconds: Double
    /// Release the hold once the lead has rebuilt to this many seconds.
    public var starvationResumeLeadSeconds: Double

    /// Pace the combined software-decoder read loop by decoded-audio lead even before the
    /// synchronizer has completed its first clock arm. Without this, startup can fill the
    /// 256-packet parked-video FIFO while audio holds only a few seconds, turning the memory
    /// backstop into the pacing owner before playback has begun.
    public var preArmLeadPacingEnabled: Bool

    /// If the starvation hold is active while the parked-video FIFO is full and the source
    /// reader still has a healthy byte cushion, the starvation is self-inflicted backpressure:
    /// the held clock prevents video drain, which prevents reads, which prevents audio refill.
    /// This kill switch allows the host to resume/suppress the hold so the FIFO can drain.
    public var backpressureHoldRecoveryEnabled: Bool
    /// Minimum source bytes ahead required to classify a full-FIFO hold as self-inflicted.
    public var backpressureHoldMinAheadBytes: Int

    /// Pin the software-path master clock at the seek target with rate 0 before any decoder or
    /// renderer flush. The landing re-applies the requested rate only after reposition completes.
    public var seekClockPinningEnabled: Bool

    /// Allocation granularity of the block-ring window.
    public var blockSizeBytes: Int

    /// `false` keeps the stock contiguous `Data` window. The ring exists because the stock window
    /// trims with `subdata`, which reallocates and copies the whole remainder: at 95 MB that is a
    /// ~93 MB alloc+copy every 4 MB consumed, and #220 already recorded 153/129 MB paired blocks
    /// as a jetsam risk. Large windows are only affordable in fixed-size blocks.
    public var useBlockRing: Bool

    /// Bytes kept behind the read cursor for matroska's small backward re-reads.
    public var lookbackBytes: Int

    /// Forward seeks within this distance keep the live connection instead of reconnecting.
    /// `0` means "derive from the low water" (half of it), which is what a large window wants.
    public var seekKeepForwardBytes: Int

    /// Memory circuit breaker: this many hard-cap connection ends inside
    /// `breakerWindowSeconds` halves the applied watermarks (never below stock) for the rest of
    /// the session, without touching the persisted policy.
    public var breakerHardCapEvents: Int
    public var breakerWindowSeconds: Double

    // MARK: - Active-transfer throughput measurement
    //
    // Read-only instrumentation: it changes no fetch decision, it only publishes what the link
    // actually delivered while we were asking for bytes. The host's adaptive-bitrate loop needs a
    // real client<-origin rate, and the ONLY place that number exists is this reader — the
    // AVPlayer that ultimately consumes our repackaged output reads from 127.0.0.1, so its access
    // log measures loopback, and an HLS manifest's advertised bitrate is a declaration, not a
    // measurement. See `SourceThroughputMeter` for why wall-clock division is wrong here.

    /// Kill switch. `false` stops all measurement and publishes nothing.
    public var throughputEnabled: Bool
    /// Discarded after each burst opens (post-park congestion-window restart).
    public var throughputWarmupMs: Int
    /// A quiet interval longer than this ends a burst instead of counting as transfer time.
    public var throughputMaxGapMs: Int
    /// Minimum active time before a burst is allowed to become a sample.
    public var throughputMinBurstMs: Int
    /// Minimum counted bytes before a burst is allowed to become a sample.
    public var throughputMinBurstKB: Int
    /// How many recent samples the published median is taken over. 1 publishes the raw last sample.
    public var throughputSampleWindow: Int
    /// Host publication cadence. Carried here rather than in the host so there is ONE process-global
    /// channel for everything about this measurement, already lock-protected and already reported
    /// back by the policy readback.
    public var throughputEmitIntervalMs: Int
    /// A sample older than this must not be published. A parked or idle reader keeps its last value
    /// forever, and a stale rate presented as current is worse for a bitrate decision than no rate.
    public var throughputMaxAgeMs: Int
    /// Publish the median of the recent samples rather than the newest one.
    public var throughputUseMedian: Bool

    public init(
        enabled: Bool = false,
        lowWaterSeconds: Double = 30,
        highWaterSeconds: Double = 40,
        maxWindowBytes: Int = 256 * 1024 * 1024,
        latencyAdaptiveEnabled: Bool = true,
        latencySafetySeconds: Double = 5,
        latencyHistoryLimit: Int = 8,
        latencyMaxSeconds: Double = 30,
        hardCapMultiplier: Double = 1.5,
        keepWarmSeconds: Double = 4,
        replaceOnConnectionLoss: Bool = true,
        proactiveDeadStreakLimit: Int = 2,
        proactiveMinIntervalMs: Int = 250,
        capResumeAtLowWater: Bool = true,
        starvationHoldEnabled: Bool = true,
        starvationHoldLeadSeconds: Double = 0.15,
        starvationResumeLeadSeconds: Double = 2.0,
        preArmLeadPacingEnabled: Bool = true,
        backpressureHoldRecoveryEnabled: Bool = true,
        backpressureHoldMinAheadBytes: Int = 1024 * 1024,
        seekClockPinningEnabled: Bool = true,
        blockSizeBytes: Int = 1024 * 1024,
        useBlockRing: Bool = true,
        lookbackBytes: Int = 2 * 1024 * 1024,
        seekKeepForwardBytes: Int = 0,
        breakerHardCapEvents: Int = 3,
        breakerWindowSeconds: Double = 60,
        throughputEnabled: Bool = true,
        throughputWarmupMs: Int = 250,
        throughputMaxGapMs: Int = 500,
        throughputMinBurstMs: Int = 300,
        throughputMinBurstKB: Int = 512,
        throughputSampleWindow: Int = 8,
        throughputEmitIntervalMs: Int = 1000,
        throughputMaxAgeMs: Int = 5000,
        throughputUseMedian: Bool = true
    ) {
        self.enabled = enabled
        self.lowWaterSeconds = lowWaterSeconds
        self.highWaterSeconds = highWaterSeconds
        self.maxWindowBytes = maxWindowBytes
        self.latencyAdaptiveEnabled = latencyAdaptiveEnabled
        self.latencySafetySeconds = latencySafetySeconds
        self.latencyHistoryLimit = latencyHistoryLimit
        self.latencyMaxSeconds = latencyMaxSeconds
        self.hardCapMultiplier = hardCapMultiplier
        self.keepWarmSeconds = keepWarmSeconds
        self.replaceOnConnectionLoss = replaceOnConnectionLoss
        self.proactiveDeadStreakLimit = proactiveDeadStreakLimit
        self.proactiveMinIntervalMs = proactiveMinIntervalMs
        self.capResumeAtLowWater = capResumeAtLowWater
        self.starvationHoldEnabled = starvationHoldEnabled
        self.starvationHoldLeadSeconds = starvationHoldLeadSeconds
        self.starvationResumeLeadSeconds = starvationResumeLeadSeconds
        self.preArmLeadPacingEnabled = preArmLeadPacingEnabled
        self.backpressureHoldRecoveryEnabled = backpressureHoldRecoveryEnabled
        self.backpressureHoldMinAheadBytes = backpressureHoldMinAheadBytes
        self.seekClockPinningEnabled = seekClockPinningEnabled
        self.blockSizeBytes = blockSizeBytes
        self.useBlockRing = useBlockRing
        self.lookbackBytes = lookbackBytes
        self.seekKeepForwardBytes = seekKeepForwardBytes
        self.breakerHardCapEvents = breakerHardCapEvents
        self.breakerWindowSeconds = breakerWindowSeconds
        self.throughputEnabled = throughputEnabled
        self.throughputWarmupMs = throughputWarmupMs
        self.throughputMaxGapMs = throughputMaxGapMs
        self.throughputMinBurstMs = throughputMinBurstMs
        self.throughputMinBurstKB = throughputMinBurstKB
        self.throughputSampleWindow = throughputSampleWindow
        self.throughputEmitIntervalMs = throughputEmitIntervalMs
        self.throughputMaxAgeMs = throughputMaxAgeMs
        self.throughputUseMedian = throughputUseMedian
    }

    /// The meter configuration this policy implies. Clamped so a hostile or fat-fingered host
    /// value cannot make the meter emit nonsense (a 0 ms minimum burst would publish the rate of
    /// a single 4 KB delivery) or spin.
    var throughputMeterConfig: SourceThroughputMeter.Config {
        SourceThroughputMeter.Config(
            enabled: throughputEnabled,
            warmupNs: UInt64(max(0, min(10_000, throughputWarmupMs))) * 1_000_000,
            maxGapNs: UInt64(max(10, min(30_000, throughputMaxGapMs))) * 1_000_000,
            minActiveNs: UInt64(max(50, min(30_000, throughputMinBurstMs))) * 1_000_000,
            minBytes: Int64(max(16, min(64 * 1024, throughputMinBurstKB))) * 1024)
    }

    /// Shipped default: stock BYTE WATERMARKS and the stock contiguous window, but with the two
    /// defect fixes that carry no memory cost already active — keep-warm (so the transfer never
    /// sits parked long enough to be dropped) and proactive replacement (so a dropped transfer is
    /// replaced at once instead of after the buffer starves). `enabled` governs only the
    /// time-based SIZING, which does have a memory cost and stays opt-in.
    public static let stock = AetherSourceBufferPolicy(enabled: false)

    /// Literally the pre-change binary: byte watermarks AND no keep-warm AND no proactive
    /// replacement. This is the true off switch for everything in this file.
    public static let preChange = AetherSourceBufferPolicy(
        enabled: false,
        keepWarmSeconds: 0,
        replaceOnConnectionLoss: false,
        capResumeAtLowWater: false,
        starvationHoldEnabled: false,
        preArmLeadPacingEnabled: false,
        backpressureHoldRecoveryEnabled: false,
        seekClockPinningEnabled: false,
        useBlockRing: false,
        throughputEnabled: false
    )

    /// The recommended time-aware policy. Not the default; the host opts in.
    public static let timeAware = AetherSourceBufferPolicy(enabled: true)
}

/// Whether a just-ended persistent connection should be replaced immediately.
public enum AetherProactiveReplaceDecision: Equatable, Sendable {
    case replace
    /// Recovery is handed back to the read loop's drain path, which owns backoff, Retry-After,
    /// the unproductive-reconnect streak and the give-up budget. The string is logged verbatim.
    case skip(String)
}

/// Everything the decision depends on, so it can be exercised without a socket.
public struct AetherProactiveReplaceInputs: Sendable {
    public var isClosed: Bool
    public var alreadyInFlight: Bool
    /// WE ended it at the #220 hard cap; re-requesting now would refill straight back over it.
    public var endedByBackpressure: Bool
    public var connStatus: Int
    public var isLive: Bool
    /// <= 0 when unknown.
    public var fileSize: Int64
    public var frontier: Int64
    public var deadStreak: Int
    /// Milliseconds since the previous proactive replacement; nil if there has not been one.
    public var msSinceLastReplace: Double?

    public init(isClosed: Bool = false, alreadyInFlight: Bool = false,
                endedByBackpressure: Bool = false, connStatus: Int = 206,
                isLive: Bool = false, fileSize: Int64 = 0, frontier: Int64 = 0,
                deadStreak: Int = 0, msSinceLastReplace: Double? = nil) {
        self.isClosed = isClosed
        self.alreadyInFlight = alreadyInFlight
        self.endedByBackpressure = endedByBackpressure
        self.connStatus = connStatus
        self.isLive = isLive
        self.fileSize = fileSize
        self.frontier = frontier
        self.deadStreak = deadStreak
        self.msSinceLastReplace = msSinceLastReplace
    }
}

public extension AetherSourceBufferPolicy {
    /// Pure: policy + connection state -> replace now, or defer to the drain path.
    ///
    /// The proactive path deliberately implements no backoff or give-up logic of its own. It
    /// exists only for the healthy-source case where the right answer is "ask again, now"; every
    /// other case is skipped so the existing, well-tested drain path stays in charge.
    func decideProactiveReplace(_ i: AetherProactiveReplaceInputs) -> AetherProactiveReplaceDecision {
        guard replaceOnConnectionLoss else { return .skip("disabled") }
        guard !i.isClosed else { return .skip("closing") }
        guard !i.alreadyInFlight else { return .skip("already-in-flight") }
        guard !i.endedByBackpressure else { return .skip("backpressure-cap") }
        guard i.connStatus != 429, i.connStatus != 503 else {
            return .skip("rate-limited-\(i.connStatus)")
        }
        if !i.isLive, i.fileSize > 0, i.frontier >= i.fileSize { return .skip("eof") }
        guard i.deadStreak < proactiveDeadStreakLimit else {
            return .skip("dead-streak-\(i.deadStreak)")
        }
        if let since = i.msSinceLastReplace, since < Double(proactiveMinIntervalMs) {
            return .skip("min-interval-\(Int(since))ms")
        }
        return .replace
    }

    /// Pure: should a hard-cap-ended (taskless) connection be re-requested NOW, with cushion
    /// still in hand, instead of at the zero-cushion drain point?
    ///
    /// `remainingBytes` is the undrained forward extent at the read cursor; the caller has
    /// already established that the connection was ended by backpressure and that no task is
    /// active or in flight. The EOF guard mirrors the proactive path's: re-requesting at or past
    /// a known file size would only earn a 416.
    func shouldCapRefill(remainingBytes: Int, lowWaterBytes: Int,
                         frontier: Int64, fileSize: Int64, isLive: Bool) -> Bool {
        guard capResumeAtLowWater else { return false }
        guard remainingBytes <= lowWaterBytes else { return false }
        if !isLive, fileSize > 0, frontier >= fileSize { return false }
        return true
    }
}

/// The stock byte watermarks, kept in one place so `enabled == false` is provably identical to
/// the pre-change build and so the resolver has a floor it can never go below.
public enum AetherSourceBufferStock {
    public static let lowWaterBytes = 8 * 1024 * 1024
    public static let highWaterBytes = 16 * 1024 * 1024
    public static let hardCapBytes = 48 * 1024 * 1024
    public static let lookbackBytes = 2 * 1024 * 1024
    public static let seekKeepForwardBytes = 8 * 1024 * 1024
}

/// Resolve the playback byte rate from the probed container and the actual file. The larger valid
/// estimate wins: container `bit_rate` can omit overhead or tracks, while file/duration can be
/// unavailable on forward-only sources. File SIZE alone never changes the cushion; an 88 GB movie
/// only needs more RAM when that size also means more bytes per playback second.
public enum AetherMediaRateResolver {
    public static func bytesPerSecond(
        declaredBitsPerSecond: Int64,
        fileSize: Int64?,
        durationSeconds: Double
    ) -> (value: Double, source: String)? {
        let declared = declaredBitsPerSecond > 0 ? Double(declaredBitsPerSecond) / 8 : 0
        let resolvedSize = fileSize ?? 0
        let average = resolvedSize > 0 && durationSeconds > 0
            ? Double(resolvedSize) / durationSeconds
            : 0
        let value = max(declared, average)
        guard value > 0, value.isFinite else { return nil }
        if average >= declared, average > 0 { return (average, "file-size/duration") }
        return (declared, "container-bit-rate")
    }
}

/// The watermarks a reader actually installed, plus why. `reason` is what the diagnostics print,
/// so the log always reports the APPLIED value rather than the requested one.
public struct AetherResolvedWatermarks: Sendable, Equatable {
    public let lowWaterBytes: Int
    public let highWaterBytes: Int
    public let hardCapBytes: Int
    public let lookbackBytes: Int
    public let seekKeepForwardBytes: Int
    /// Media rate the durations were resolved against, bytes/sec. 0 when unknown (stock applied).
    public let bytesPerSecond: Double
    public let observedHeaderLatencySeconds: Double
    public let latencyTargetSeconds: Double
    /// `stock` | `time` | `time-clamped-memory` | `time-clamped-floor` | `breaker`
    public let reason: String

    public var lowWaterSeconds: Double { bytesPerSecond > 0 ? Double(lowWaterBytes) / bytesPerSecond : 0 }
    public var highWaterSeconds: Double { bytesPerSecond > 0 ? Double(highWaterBytes) / bytesPerSecond : 0 }

    public static let stock = AetherResolvedWatermarks(
        lowWaterBytes: AetherSourceBufferStock.lowWaterBytes,
        highWaterBytes: AetherSourceBufferStock.highWaterBytes,
        hardCapBytes: AetherSourceBufferStock.hardCapBytes,
        lookbackBytes: AetherSourceBufferStock.lookbackBytes,
        seekKeepForwardBytes: AetherSourceBufferStock.seekKeepForwardBytes,
        bytesPerSecond: 0,
        observedHeaderLatencySeconds: 0,
        latencyTargetSeconds: 0,
        reason: "stock"
    )
}

public extension AetherSourceBufferPolicy {

    /// Pure resolver: policy + measured media rate -> the byte watermarks to install.
    /// Unit-tested without any network or engine state.
    ///
    /// Invariants it guarantees, because violating any of them deadlocks or thrashes the reader:
    ///   - `low < high` with a real gap (a low equal to high resumes and re-suspends per delivery).
    ///   - `low >= stock low` and `high >= stock high`: this feature only ever GROWS the cushion.
    ///   - `high <= maxWindowBytes`, and `hardCap > high` so the cap cannot fire during normal fill.
    ///
    /// `shrinkFactor` is the memory circuit breaker (1 = untripped, 0.5 = halved, ...).
    func resolve(
        bytesPerSecond: Double,
        shrinkFactor: Double = 1,
        observedHeaderLatencySeconds: Double = 0
    ) -> AetherResolvedWatermarks {
        guard enabled, bytesPerSecond > 0,
              lowWaterSeconds > 0, highWaterSeconds > lowWaterSeconds else {
            return .stock
        }

        let shrink = max(0.25, min(1, shrinkFactor))
        let ceiling = max(AetherSourceBufferStock.highWaterBytes, maxWindowBytes)

        let observedLatency = max(0, observedHeaderLatencySeconds)
        let latencyTarget = latencyAdaptiveEnabled
            ? min(max(0, latencyMaxSeconds), observedLatency + max(0, latencySafetySeconds))
            : 0
        let configuredGap = max(1, highWaterSeconds - lowWaterSeconds)
        let targetLowSeconds = max(lowWaterSeconds, latencyTarget)
        let targetHighSeconds = max(highWaterSeconds, targetLowSeconds + configuredGap)
        var reason = shrink < 1 ? "breaker" : (targetLowSeconds > lowWaterSeconds ? "time-latency" : "time")

        // Duration targets -> bytes.
        var high = Int((bytesPerSecond * targetHighSeconds * shrink).rounded())
        var low = Int((bytesPerSecond * targetLowSeconds * shrink).rounded())

        // Memory ceiling wins over the duration target. Preserve the low:high ratio so the
        // clamped policy still resumes with a proportionate cushion instead of collapsing onto
        // the high water (which would resume-and-immediately-re-suspend on every delivery).
        if high > ceiling {
            let ratio = Double(low) / Double(high)
            high = ceiling
            low = Int((Double(high) * ratio).rounded())
            reason = "time-clamped-memory"
        }

        // Never regress below stock; this change exists to enlarge the cushion, never shrink it.
        if high < AetherSourceBufferStock.highWaterBytes || low < AetherSourceBufferStock.lowWaterBytes {
            high = max(high, AetherSourceBufferStock.highWaterBytes)
            low = max(low, AetherSourceBufferStock.lowWaterBytes)
            reason = shrink < 1 ? "breaker" : "time-clamped-floor"
        }

        // Keep a real hysteresis gap. Without it the transfer resumes and re-suspends on every
        // single delivery, which is the pathological opposite of what this policy is for.
        let minGap = max(2 * 1024 * 1024, high / 8)
        if high - low < minGap {
            low = max(AetherSourceBufferStock.lowWaterBytes, high - minGap)
        }
        // Degenerate ceiling (a host setting maxWindowBytes at/below the floor): give the gap
        // priority over the ceiling rather than returning low >= high.
        if low >= high {
            high = low + minGap
        }

        // The hard cap is the "transport ignored suspend()" bound, so it must sit clear of the
        // high water or a healthy fill would trip it.
        let hardCap = max(
            AetherSourceBufferStock.hardCapBytes,
            Int((Double(high) * max(1.25, hardCapMultiplier)).rounded())
        )

        let lookback = max(64 * 1024, lookbackBytes)
        let seekKeep = seekKeepForwardBytes > 0
            ? seekKeepForwardBytes
            : max(AetherSourceBufferStock.seekKeepForwardBytes, low / 2)

        return AetherResolvedWatermarks(
            lowWaterBytes: low,
            highWaterBytes: high,
            hardCapBytes: hardCap,
            lookbackBytes: lookback,
            seekKeepForwardBytes: seekKeep,
            bytesPerSecond: bytesPerSecond,
            observedHeaderLatencySeconds: observedLatency,
            latencyTargetSeconds: latencyTarget,
            reason: reason
        )
    }
}

/// Process-global, host-settable tuning channel for the source buffer policy.
///
/// A global rather than constructor plumbing on purpose: readers are created deep inside
/// `Demuxer.openHTTP` from an `OpenProfile`, and the host (the FlexUI native module) needs to
/// change these AT RUNTIME on an already-playing session without another native build
/// (AGENTS.md: "Before requesting or triggering a native build ... verify that each item can be
/// changed after installation"). Readers re-read the policy on every connection start and on every
/// watermark recomputation, so a mid-playback change takes effect at the next fill cycle.
public enum AetherSourceBuffer {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _policy = AetherSourceBufferPolicy.stock
    nonisolated(unsafe) private static var _lastApplied = AetherResolvedWatermarks.stock

    /// Host-settable policy. Thread-safe; readable from the demux thread and any delegate queue.
    public static var policy: AetherSourceBufferPolicy {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set {
            lock.lock()
            let changed = _policy != newValue
            _policy = newValue
            lock.unlock()
            if changed {
                EngineLog.emit(
                    "[SourceBuffer] policy set enabled=\(newValue.enabled) "
                    + "low=\(newValue.lowWaterSeconds)s high=\(newValue.highWaterSeconds)s "
                    + "latencyAdaptive=\(newValue.latencyAdaptiveEnabled) "
                    + "latencySafety=\(newValue.latencySafetySeconds)s "
                    + "keepWarm=\(newValue.keepWarmSeconds)s "
                    + "maxWindowMB=\(newValue.maxWindowBytes / 1024 / 1024) "
                    + "ring=\(newValue.useBlockRing) blockKB=\(newValue.blockSizeBytes / 1024)",
                    category: .demux)
            }
        }
    }

    /// What the PLAYBACK reader most recently installed. This is the JS-visible "what did the
    /// installed binary actually apply" answer; it is never the requested value.
    public static var lastApplied: AetherResolvedWatermarks {
        get { lock.lock(); defer { lock.unlock() }; return _lastApplied }
    }

    static func recordApplied(_ resolved: AetherResolvedWatermarks) {
        lock.lock()
        _lastApplied = resolved
        lock.unlock()
    }

    // MARK: - Session telemetry
    //
    // Process-global rather than plumbed through Demuxer -> SoftwarePlaybackHost -> memprobe,
    // for the same reason `policy` is: the reader that owns these numbers sits three layers below
    // the diagnostics emitter, and only the PRIMARY playback reader writes them.

    nonisolated(unsafe) private static var _suspends = 0
    nonisolated(unsafe) private static var _keepWarmResumes = 0
    nonisolated(unsafe) private static var _underruns = 0
    nonisolated(unsafe) private static var _proactiveReplaces = 0
    nonisolated(unsafe) private static var _proactiveRecovered = 0
    nonisolated(unsafe) private static var _proactiveFailures = 0
    nonisolated(unsafe) private static var _proactiveSuppressions = 0
    nonisolated(unsafe) private static var _proactiveLastRecoveryMs = 0
    nonisolated(unsafe) private static var _proactivePreservedBytes: Int64 = 0
    nonisolated(unsafe) private static var _capRefills = 0
    nonisolated(unsafe) private static var _capRefillLastMs = 0
    nonisolated(unsafe) private static var _starvationHolds = 0

    /// Zero the counters for a new playback source. Called when the primary reader opens.
    public static func beginSession() {
        lock.lock()
        _suspends = 0
        _keepWarmResumes = 0
        _underruns = 0
        _proactiveReplaces = 0
        _proactiveRecovered = 0
        _proactiveFailures = 0
        _proactiveSuppressions = 0
        _proactiveLastRecoveryMs = 0
        _proactivePreservedBytes = 0
        _capRefills = 0
        _capRefillLastMs = 0
        _starvationHolds = 0
        // A new source is a new link measurement. Carrying the previous title's samples across
        // would let a fast direct-play file's estimate authorize a step UP on the next one.
        _throughputRing.removeAll()
        _throughputSamples = 0
        _throughputRejected = 0
        _throughputSaturated = false
        _throughputLastAt = nil
        _throughputLastBps = 0
        lock.unlock()
    }

    static func noteSuspend() { lock.lock(); _suspends += 1; lock.unlock() }
    static func noteKeepWarmResume() { lock.lock(); _keepWarmResumes += 1; lock.unlock() }
    static func noteUnderrun() { lock.lock(); _underruns += 1; lock.unlock() }
    static func noteProactiveReplace() { lock.lock(); _proactiveReplaces += 1; lock.unlock() }
    static func noteProactiveFailure() { lock.lock(); _proactiveFailures += 1; lock.unlock() }
    static func noteProactiveSuppressed() { lock.lock(); _proactiveSuppressions += 1; lock.unlock() }
    /// A hard-cap-ended connection was re-requested at the low water; `ms` is time to first byte.
    static func noteCapRefill(ms: Double) {
        lock.lock(); _capRefills += 1; _capRefillLastMs = Int(ms.rounded()); lock.unlock()
    }
    /// The VOD host paused the master clock because the source starved the audio feed.
    public static func noteStarvationHold() { lock.lock(); _starvationHolds += 1; lock.unlock() }

    // MARK: Throughput

    nonisolated(unsafe) private static var _throughputRing: [Int] = []
    nonisolated(unsafe) private static var _throughputSamples = 0
    nonisolated(unsafe) private static var _throughputRejected = 0
    nonisolated(unsafe) private static var _throughputSaturated = false
    nonisolated(unsafe) private static var _throughputLastAt: DispatchTime?
    nonisolated(unsafe) private static var _throughputLastBps = 0

    /// Publish one completed active-transfer measurement. Only the PRIMARY playback reader calls
    /// this: subtitle side readers, size probes, chunk fetches and scrub-thumbnail reads run on
    /// their own connections and would otherwise mix short unrelated transfers into the estimate.
    static func noteThroughput(_ sample: AetherThroughputSample, window: Int) {
        lock.lock()
        _throughputSamples += 1
        _throughputLastBps = sample.bitsPerSecond
        _throughputSaturated = sample.saturated
        _throughputLastAt = DispatchTime.now()
        _throughputRing.append(sample.bitsPerSecond)
        let cap = max(1, min(64, window))
        if _throughputRing.count > cap { _throughputRing.removeFirst(_throughputRing.count - cap) }
        lock.unlock()
    }

    /// A burst that never qualified (too short, too few bytes). Counted so a device trace can tell
    /// "the link is quiet" apart from "the filters are rejecting everything", which look identical
    /// from JS: both publish no samples.
    static func noteThroughputRejected() {
        lock.lock(); _throughputRejected += 1; lock.unlock()
    }

    /// Median of the recent samples, plus how stale the newest one is.
    ///
    /// `ageMs` is what makes this safe for an ABR consumer: a parked or idle reader keeps the last
    /// value forever, and a stale rate presented as current is worse than no rate at all. The host
    /// must not forward a sample older than its own freshness bound.
    ///
    /// `saturated` reports the newest sample only — see `AetherThroughputSample.saturated`.
    public static var throughput: (
        bps: Int, medianBps: Int, samples: Int, rejected: Int, saturated: Bool, ageMs: Int
    ) {
        lock.lock(); defer { lock.unlock() }
        let ring = _throughputRing.sorted()
        let median: Int
        if ring.isEmpty {
            median = 0
        } else if ring.count % 2 == 1 {
            median = ring[ring.count / 2]
        } else {
            median = (ring[ring.count / 2 - 1] + ring[ring.count / 2]) / 2
        }
        let ageMs: Int
        if let last = _throughputLastAt {
            ageMs = Int((DispatchTime.now().uptimeNanoseconds &- last.uptimeNanoseconds) / 1_000_000)
        } else {
            ageMs = -1
        }
        return (_throughputLastBps, median, _throughputSamples, _throughputRejected,
                _throughputSaturated, ageMs)
    }

    static func noteProactiveRecovered(ms: Double, preservedBytes: Int64) {
        lock.lock()
        _proactiveRecovered += 1
        _proactiveLastRecoveryMs = Int(ms.rounded())
        _proactivePreservedBytes = preservedBytes
        lock.unlock()
    }

    /// `suspends` = transfer parks (each one is a restart opportunity), `keepWarmResumes` = early
    /// wakes that avoided a long cold park, `underruns` = times the forward buffer hit empty at
    /// the read cursor, i.e. the events that become visible freezes.
    ///
    /// The proactive fields answer the 2026-08-03 defect directly: `proactiveReplaces` counts
    /// connection losses replaced immediately, `proactiveRecovered`/`lastRecoveryMs` how fast the
    /// replacement produced its first byte (28 ms and 22 ms in that capture, against a 24.416 s
    /// deferred recovery), `preservedBytes` proves the buffer survived the swap, and
    /// `proactiveFailures`/`proactiveSuppressions` expose a genuinely failing source rather than
    /// hiding it behind a retry loop.
    public static var telemetry: (
        suspends: Int, keepWarmResumes: Int, underruns: Int,
        proactiveReplaces: Int, proactiveRecovered: Int, proactiveFailures: Int,
        proactiveSuppressions: Int, lastRecoveryMs: Int, preservedBytes: Int64,
        capRefills: Int, capRefillLastMs: Int, starvationHolds: Int
    ) {
        lock.lock(); defer { lock.unlock() }
        return (_suspends, _keepWarmResumes, _underruns,
                _proactiveReplaces, _proactiveRecovered, _proactiveFailures,
                _proactiveSuppressions, _proactiveLastRecoveryMs, _proactivePreservedBytes,
                _capRefills, _capRefillLastMs, _starvationHolds)
    }

    /// Compact memprobe fragment.
    ///
    /// The sizing block is emitted only when the time-based watermarks are on, so a stock-sizing
    /// log keeps its old shape. The recovery block is emitted whenever keep-warm or proactive
    /// replacement is armed, because those run in the DEFAULT configuration and their counters are
    /// the on-device proof that the freeze defect is closed.
    public static func probeFragment() -> String {
        let p = policy
        let a = lastApplied
        let t = telemetry
        var out = ""
        if p.enabled {
            out += "bufLowMB=\(a.lowWaterBytes / 1024 / 1024) "
                + "bufHighMB=\(a.highWaterBytes / 1024 / 1024) "
                + String(format: "bufLowS=%.1f bufHighS=%.1f ", a.lowWaterSeconds, a.highWaterSeconds)
                + String(format: "bufHeaderS=%.1f bufLatencyTargetS=%.1f ",
                         a.observedHeaderLatencySeconds, a.latencyTargetSeconds)
                + "bufReason=\(a.reason) "
        }
        if p.enabled || p.keepWarmSeconds > 0 || p.replaceOnConnectionLoss {
            out += "bufSusp=\(t.suspends) bufWarm=\(t.keepWarmResumes) bufUnder=\(t.underruns) "
                + "bufRepl=\(t.proactiveReplaces) bufReplOK=\(t.proactiveRecovered) "
                + "bufReplFail=\(t.proactiveFailures) bufReplOff=\(t.proactiveSuppressions) "
                + "bufReplMs=\(t.lastRecoveryMs) bufReplKeptKB=\(t.preservedBytes / 1024) "
                + "bufCapRefill=\(t.capRefills) bufCapRefillMs=\(t.capRefillLastMs) "
                + "bufHold=\(t.starvationHolds) "
        }
        if p.throughputEnabled {
            let bw = throughput
            out += "bwKbps=\(bw.bps / 1000) bwMedKbps=\(bw.medianBps / 1000) "
                + "bwN=\(bw.samples) bwRej=\(bw.rejected) "
                + "bwSat=\(bw.saturated ? 1 : 0) bwAgeMs=\(bw.ageMs) "
        }
        return out
    }

    /// One-line applied-state summary for the host bridge / memprobe.
    public static func appliedDescription() -> String {
        let p = policy
        let a = lastApplied
        let kbps = a.bytesPerSecond > 0 ? Int((a.bytesPerSecond * 8 / 1000).rounded()) : 0
        return "enabled=\(p.enabled) replaceOnLoss=\(p.replaceOnConnectionLoss) reason=\(a.reason) "
            + "lowMB=\(a.lowWaterBytes / 1024 / 1024) highMB=\(a.highWaterBytes / 1024 / 1024) "
            + "hardCapMB=\(a.hardCapBytes / 1024 / 1024) "
            + String(format: "lowS=%.1f highS=%.1f ", a.lowWaterSeconds, a.highWaterSeconds)
            + String(format: "headerS=%.1f latencyTargetS=%.1f ",
                     a.observedHeaderLatencySeconds, a.latencyTargetSeconds)
            + "srcKbps=\(kbps) keepWarmS=\(p.keepWarmSeconds) ring=\(p.useBlockRing)"
    }
}
