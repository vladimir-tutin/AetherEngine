import Testing
import Foundation
@testable import AetherEngine

/// Time-aware source buffer policy.
///
/// The defect: the persistent reader's forward buffer was bounded by FIXED BYTES (suspend above
/// 16 MB, resume below 8 MB). Apple TV field capture on a 25.2 Mbps direct-play MKV showed 8 MB =
/// 2.66 s of media, the transfer parked ~97% of wall clock, and two reads blocking 3.003 s and
/// 3.810 s with `reconnects=0 connect=0ms lockWait=0ms unaccounted=0ms` — a healthy connection
/// that simply did not resume at rate before the 2.66 s cushion ran out.
struct SourceBufferPolicyTests {

    private let rate25Mbps = 25.2 * 1_000_000 / 8   // 3.15 MB/s
    private let rate80Mbps = 80.0 * 1_000_000 / 8   // 10 MB/s

    @Test("disabled resolves to the stock byte watermarks, exactly")
    func disabledIsStock() {
        let resolved = AetherSourceBufferPolicy.stock.resolve(bytesPerSecond: rate25Mbps)
        #expect(resolved == .stock)
        #expect(resolved.lowWaterBytes == 8 * 1024 * 1024)
        #expect(resolved.highWaterBytes == 16 * 1024 * 1024)
        #expect(resolved.hardCapBytes == 48 * 1024 * 1024)
        #expect(resolved.reason == "stock")
    }

    @Test("an unknown media rate cannot enable the time policy")
    func unknownRateIsStock() {
        var policy = AetherSourceBufferPolicy.timeAware
        policy.enabled = true
        #expect(policy.resolve(bytesPerSecond: 0) == .stock)
        #expect(policy.resolve(bytesPerSecond: -1) == .stock)
    }

    @Test("30s/40s at 25.2 Mbps buys a real playback-time cushion")
    func timeTargetsAt25Mbps() {
        let resolved = AetherSourceBufferPolicy.timeAware.resolve(bytesPerSecond: rate25Mbps)
        #expect(resolved.reason == "time")
        // The number that mattered in the field: seconds of media at the RESUME threshold.
        #expect(abs(resolved.lowWaterSeconds - 30) < 0.1)
        #expect(abs(resolved.highWaterSeconds - 40) < 0.1)
        #expect(resolved.lowWaterBytes > 88 * 1024 * 1024)
        #expect(resolved.highWaterBytes > 118 * 1024 * 1024)
        // The stock low water is 8 MiB = 8,388,608 B, which at 3.15 MB/s is 2.66 s — the entire
        // cushion the reader had when it resumed a fully idle connection.
        #expect(Double(AetherSourceBufferStock.lowWaterBytes) / rate25Mbps < 2.7)
        #expect(Double(AetherSourceBufferStock.lowWaterBytes) / rate25Mbps > 2.6)
        // The new low water is >5x that.
        #expect(resolved.lowWaterSeconds
                / (Double(AetherSourceBufferStock.lowWaterBytes) / rate25Mbps) > 10)
    }

    @Test("the memory ceiling wins over the duration target and says so")
    func memoryCeilingClamps() {
        // 40 s at 80 Mbps is 400 MB, so the explicit ceiling wins.
        let resolved = AetherSourceBufferPolicy.timeAware.resolve(bytesPerSecond: rate80Mbps)
        #expect(resolved.reason == "time-clamped-memory")
        #expect(resolved.highWaterBytes == 256 * 1024 * 1024)
        // The low:high ratio survives the clamp, so the resume threshold does not collapse onto
        // the high water (which would resume-and-re-suspend on every delivery).
        #expect(resolved.lowWaterBytes < resolved.highWaterBytes)
        #expect(abs(Double(resolved.lowWaterBytes) / Double(resolved.highWaterBytes) - 0.75) < 0.02)
        // Even clamped, it is still far better than stock: >20 s instead of 0.84 s.
        #expect(resolved.lowWaterSeconds > 20)
        #expect(Double(AetherSourceBufferStock.lowWaterBytes) / rate80Mbps < 0.9)
    }

    @Test("the policy can only grow the cushion, never shrink it below stock")
    func neverRegressesBelowStock() {
        var policy = AetherSourceBufferPolicy.timeAware
        policy.lowWaterSeconds = 0.1
        policy.highWaterSeconds = 0.2
        // A very low-bitrate source whose duration targets land under the stock bytes.
        let resolved = policy.resolve(bytesPerSecond: 100_000)
        #expect(resolved.lowWaterBytes >= AetherSourceBufferStock.lowWaterBytes)
        #expect(resolved.highWaterBytes >= AetherSourceBufferStock.highWaterBytes)
        #expect(resolved.reason == "time-clamped-floor")
    }

    @Test("hysteresis gap and ordering invariants hold for every input")
    func invariantsHold() {
        let rates: [Double] = [50_000, 500_000, rate25Mbps, rate80Mbps, 40 * 1024 * 1024]
        let lows: [Double] = [1, 5, 15, 40]
        let highs: [Double] = [2, 10, 30, 60]
        let ceilings = [8 * 1024 * 1024, 32 * 1024 * 1024, 128 * 1024 * 1024, 512 * 1024 * 1024]
        for rate in rates {
            for low in lows {
                for high in highs where high > low {
                    for ceiling in ceilings {
                        var policy = AetherSourceBufferPolicy.timeAware
                        policy.lowWaterSeconds = low
                        policy.highWaterSeconds = high
                        policy.maxWindowBytes = ceiling
                        let r = policy.resolve(bytesPerSecond: rate)
                        // A low >= high deadlocks the reader: it would resume and immediately
                        // re-suspend on every single delivery.
                        #expect(r.lowWaterBytes < r.highWaterBytes,
                                "low must stay below high (rate=\(rate) low=\(low) high=\(high) ceiling=\(ceiling))")
                        // The hard cap must sit clear of the high water or a healthy fill trips
                        // the #220 "transport ignored suspend()" path on every cycle.
                        #expect(r.hardCapBytes > r.highWaterBytes,
                                "hard cap must exceed high water (rate=\(rate) ceiling=\(ceiling))")
                        #expect(r.lowWaterBytes >= AetherSourceBufferStock.lowWaterBytes)
                        #expect(r.lookbackBytes > 0)
                        #expect(r.seekKeepForwardBytes >= AetherSourceBufferStock.seekKeepForwardBytes)
                    }
                }
            }
        }
    }

    @Test("the memory breaker shrinks the applied watermarks but never below stock")
    func breakerShrinks() {
        let policy = AetherSourceBufferPolicy.timeAware
        let full = policy.resolve(bytesPerSecond: rate25Mbps, shrinkFactor: 1)
        let half = policy.resolve(bytesPerSecond: rate25Mbps, shrinkFactor: 0.5)
        let quarter = policy.resolve(bytesPerSecond: rate25Mbps, shrinkFactor: 0.25)
        #expect(half.highWaterBytes < full.highWaterBytes)
        #expect(quarter.highWaterBytes < half.highWaterBytes)
        #expect(half.reason == "breaker")
        #expect(quarter.lowWaterBytes >= AetherSourceBufferStock.lowWaterBytes)
        #expect(quarter.highWaterBytes >= AetherSourceBufferStock.highWaterBytes)
        #expect(quarter.lowWaterBytes < quarter.highWaterBytes)
    }

    @Test("a degenerate ceiling below the stock floor still yields a usable band")
    func degenerateCeiling() {
        var policy = AetherSourceBufferPolicy.timeAware
        policy.maxWindowBytes = 1024        // absurd host value
        let r = policy.resolve(bytesPerSecond: rate25Mbps)
        #expect(r.lowWaterBytes < r.highWaterBytes)
        #expect(r.hardCapBytes > r.highWaterBytes)
        #expect(r.lowWaterBytes >= AetherSourceBufferStock.lowWaterBytes)
    }

    @Test("the applied description reports applied values, not requested ones")
    func appliedDescriptionIsApplied() {
        let resolved = AetherSourceBufferPolicy.timeAware.resolve(bytesPerSecond: rate80Mbps)
        AetherSourceBuffer.recordApplied(resolved)
        let previous = AetherSourceBuffer.policy
        AetherSourceBuffer.policy = .timeAware
        defer { AetherSourceBuffer.policy = previous }
        let text = AetherSourceBuffer.appliedDescription()
        // 30 s was REQUESTED; 128 MB is what the ceiling allowed. The log must show the latter.
        #expect(text.contains("highMB=256"))
        #expect(text.contains("reason=time-clamped-memory"))
    }

    @Test("an 88 GiB two-hour movie retains more than a 14 second low-water cushion")
    func hugeHighBitrateMovie() {
        let bytes = Double(88 * 1024 * 1024 * 1024)
        let rate = bytes / (2 * 60 * 60)
        let resolved = AetherSourceBufferPolicy.timeAware.resolve(bytesPerSecond: rate)
        #expect(resolved.highWaterBytes == 256 * 1024 * 1024)
        #expect(resolved.lowWaterSeconds > 14)
        #expect(resolved.reason == "time-clamped-memory")
    }

    @Test("observed 14 second header latency grows a smaller configured cushion with safety")
    func latencyAdaptation() {
        var policy = AetherSourceBufferPolicy.timeAware
        policy.lowWaterSeconds = 5
        policy.highWaterSeconds = 10
        policy.maxWindowBytes = 512 * 1024 * 1024
        policy.latencySafetySeconds = 5
        let resolved = policy.resolve(
            bytesPerSecond: rate25Mbps,
            observedHeaderLatencySeconds: 14)
        #expect(resolved.reason == "time-latency")
        #expect(abs(resolved.lowWaterSeconds - 19) < 0.1)
        #expect(abs(resolved.highWaterSeconds - 24) < 0.1)
        #expect(abs(resolved.observedHeaderLatencySeconds - 14) < 0.01)
    }

    @Test("file size only affects buffering through bytes per playback second")
    func mediaRateResolution() {
        let huge = AetherMediaRateResolver.bytesPerSecond(
            declaredBitsPerSecond: 0,
            fileSize: 88 * 1024 * 1024 * 1024,
            durationSeconds: 7200)
        let sameRateSmaller = AetherMediaRateResolver.bytesPerSecond(
            declaredBitsPerSecond: 0,
            fileSize: 44 * 1024 * 1024 * 1024,
            durationSeconds: 3600)
        #expect(huge?.source == "file-size/duration")
        #expect(abs((huge?.value ?? 0) - (sameRateSmaller?.value ?? 1)) < 1)
    }
}
/// Low-water refill of a hard-cap-ended connection (2026-08-14 field capture).
///
/// The defect: a #220 hard-cap end leaves no task for the low-water hysteresis to `resume()`,
/// so recovery deferred to the drain path — which fires only at `available == 0`. Every capped
/// window therefore drained through a zero-cushion re-request, and the origin's header latency
/// converted 1:1 into a freeze (6412 ms observed; the usual 21 ms made the same moment invisible).
struct CapRefillDecisionTests {

    private let stock = AetherSourceBufferPolicy.stock
    private let lowWater = AetherSourceBufferStock.lowWaterBytes

    @Test("at or below the low water, a capped connection is re-requested with cushion in hand")
    func refillsAtLowWater() {
        #expect(stock.shouldCapRefill(remainingBytes: lowWater, lowWaterBytes: lowWater,
                                      frontier: 500_000_000, fileSize: 1_000_000_000,
                                      isLive: false))
        #expect(stock.shouldCapRefill(remainingBytes: 0, lowWaterBytes: lowWater,
                                      frontier: 500_000_000, fileSize: 1_000_000_000,
                                      isLive: false))
    }

    @Test("above the low water the window keeps draining; no early re-request")
    func waitsAboveLowWater() {
        #expect(!stock.shouldCapRefill(remainingBytes: lowWater + 1, lowWaterBytes: lowWater,
                                       frontier: 500_000_000, fileSize: 1_000_000_000,
                                       isLive: false))
    }

    @Test("a frontier at or past a known file size is never re-requested (would 416)")
    func eofNeverRefills() {
        #expect(!stock.shouldCapRefill(remainingBytes: 0, lowWaterBytes: lowWater,
                                       frontier: 1_000_000_000, fileSize: 1_000_000_000,
                                       isLive: false))
        // Unknown size and live sources have no EOF to respect.
        #expect(stock.shouldCapRefill(remainingBytes: 0, lowWaterBytes: lowWater,
                                      frontier: 1_000_000_000, fileSize: 0, isLive: false))
        #expect(stock.shouldCapRefill(remainingBytes: 0, lowWaterBytes: lowWater,
                                      frontier: 1_000_000_000, fileSize: 1_000_000_000,
                                      isLive: true))
    }

    @Test("the kill switch and the pre-change policy restore the drain-path-only behavior")
    func killSwitchDefers() {
        var off = AetherSourceBufferPolicy.stock
        off.capResumeAtLowWater = false
        #expect(!off.shouldCapRefill(remainingBytes: 0, lowWaterBytes: lowWater,
                                     frontier: 500_000_000, fileSize: 1_000_000_000,
                                     isLive: false))
        #expect(!AetherSourceBufferPolicy.preChange
            .shouldCapRefill(remainingBytes: 0, lowWaterBytes: lowWater,
                             frontier: 500_000_000, fileSize: 1_000_000_000, isLive: false))
        // Defect fixes default ON, like replaceOnConnectionLoss.
        #expect(AetherSourceBufferPolicy.stock.capResumeAtLowWater)
        #expect(AetherSourceBufferPolicy.stock.starvationHoldEnabled)
        #expect(!AetherSourceBufferPolicy.preChange.starvationHoldEnabled)
    }
}
