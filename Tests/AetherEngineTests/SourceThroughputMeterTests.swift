import Testing
import Foundation
@testable import AetherEngine

/// The reader parks the HTTP transfer by design (measured: idle ~97% of wall clock on a 25.2 Mbps
/// direct-play MKV), so bytes / wall-clock reconstructs the MEDIA bitrate and can never authorize
/// an adaptive step up. These tests pin the rules that make the meter measure the LINK instead.
struct SourceThroughputMeterTests {

    private static let ms: UInt64 = 1_000_000

    /// 10 Mbps = 1_250_000 byte/s = 125_000 bytes per 100 ms tick.
    private static let tickNs = 100 * ms
    private static let tickBytes = 125_000

    private func fastConfig(
        warmupMs: Int = 0, minBurstMs: Int = 100, minBurstKB: Int = 16, maxGapMs: Int = 500
    ) -> SourceThroughputMeter.Config {
        SourceThroughputMeter.Config(
            enabled: true,
            warmupNs: UInt64(warmupMs) * Self.ms,
            maxGapNs: UInt64(maxGapMs) * Self.ms,
            minActiveNs: UInt64(minBurstMs) * Self.ms,
            minBytes: Int64(minBurstKB) * 1024)
    }

    @Test("A steady burst measures the link rate, not the file's bitrate")
    func steadyBurstMeasuresLinkRate() {
        var meter = SourceThroughputMeter(config: fastConfig())
        var now: UInt64 = 0
        // Opening delivery only establishes the time base; it contributes no interval.
        _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        for _ in 0..<10 {
            now &+= Self.tickNs
            #expect(meter.noteDelivery(bytes: Self.tickBytes, nowNs: now) == nil)
        }
        let sample = meter.end(saturated: true)
        #expect(sample != nil)
        // 10 intervals x 125_000 B over 10 x 100 ms = 10 Mbps.
        #expect(sample?.bitsPerSecond == 10_000_000)
        #expect(sample?.activeMs == 1000)
        #expect(sample?.saturated == true)
    }

    @Test("A bounded range end publishes an unsaturated completed-transfer sample")
    func boundedRangeEndPublishesSample() {
        var meter = SourceThroughputMeter(config: fastConfig())
        var now: UInt64 = 0
        _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        for _ in 0..<5 {
            now &+= Self.tickNs
            _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        }
        // AVIOReader invokes this exact boundary when its finite byte range is delivered in full.
        let sample = meter.end(saturated: false)
        #expect(sample?.bitsPerSecond == 10_000_000)
        #expect(sample?.saturated == false)
    }

    /// The defect this whole meter exists for: a parked reader delivers a burst, sits idle for
    /// seconds, delivers another. Wall-clock division over that span reports the media rate.
    @Test("Park time between bursts is excluded, so the estimate is not the media bitrate")
    func parkedTimeIsExcluded() {
        var meter = SourceThroughputMeter(config: fastConfig())
        var now: UInt64 = 0
        var samples: [AetherThroughputSample] = []
        for cycle in 0..<3 {
            _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
            for _ in 0..<5 {
                now &+= Self.tickNs
                if let s = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now) { samples.append(s) }
            }
            if let s = meter.end(saturated: true) { samples.append(s) }
            // Park: 3 s idle before the consumer drains to low water and the transfer resumes.
            now &+= 3_000 * Self.ms
            _ = cycle
        }
        #expect(samples.count == 3)
        for s in samples { #expect(s.bitsPerSecond == 10_000_000) }
        // Wall-clock division over the same trace would have reported roughly the media rate:
        // 18 x 125_000 B over ~10.5 s is ~1.7 Mbps, a sixth of the truth.
        let totalBytes = Double(18 * Self.tickBytes)
        let wallClockBps = totalBytes * 8.0 / (Double(now) / 1_000_000_000.0)
        #expect(wallClockBps < 3_000_000)
    }

    @Test("An idle gap longer than maxGap closes the burst instead of counting as transfer time")
    func longGapClosesBurst() {
        var meter = SourceThroughputMeter(config: fastConfig(maxGapMs: 200))
        var now: UInt64 = 0
        _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        for _ in 0..<3 {
            now &+= Self.tickNs
            _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        }
        // 5 s of silence: a park or an origin stall, not link latency.
        now &+= 5_000 * Self.ms
        let closed = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        #expect(closed != nil)
        #expect(closed?.bitsPerSecond == 10_000_000)   // the 5 s did NOT dilute it
        #expect(closed?.saturated == false)            // closed by gap, not by our park
    }

    @Test("Warm-up deliveries after a park are discarded, so a cold restart cannot understate the link")
    func warmupIsDiscarded() {
        var meter = SourceThroughputMeter(config: fastConfig(warmupMs: 250))
        var now: UInt64 = 0
        _ = meter.noteDelivery(bytes: 1, nowNs: now)
        // 300 ms of congestion-window dribble: 1 KB per 100 ms tick (~80 kbps).
        for _ in 0..<3 {
            now &+= Self.tickNs
            _ = meter.noteDelivery(bytes: 1024, nowNs: now)
        }
        // Then the real rate.
        for _ in 0..<10 {
            now &+= Self.tickNs
            _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        }
        let sample = meter.end(saturated: true)
        #expect(sample != nil)
        // Only intervals whose START is past warm-up count, so every dribble tick is discarded and
        // the measurement is the real rate — nowhere near the ~80 kbps the dribble alone implies.
        #expect((sample?.bitsPerSecond ?? 0) > 9_000_000)
        #expect((sample?.bitsPerSecond ?? 0) <= 10_000_000)
    }

    @Test("A keep-warm top-up too small or too short to be meaningful is rejected, not published")
    func tinyBurstIsRejected() {
        var meter = SourceThroughputMeter(config: fastConfig(minBurstMs: 300, minBurstKB: 512))
        var now: UInt64 = 0
        _ = meter.noteDelivery(bytes: 64 * 1024, nowNs: now)
        now &+= 50 * Self.ms
        _ = meter.noteDelivery(bytes: 64 * 1024, nowNs: now)
        #expect(meter.end(saturated: true) == nil)
        #expect(meter.drainRejected() == 1)
        #expect(meter.drainRejected() == 0)   // draining clears it
    }

    @Test("reset() drops an in-flight burst so it cannot span two connections")
    func resetDropsBurst() {
        var meter = SourceThroughputMeter(config: fastConfig())
        var now: UInt64 = 0
        _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        for _ in 0..<10 {
            now &+= Self.tickNs
            _ = meter.noteDelivery(bytes: Self.tickBytes, nowNs: now)
        }
        meter.reset()
        #expect(meter.end(saturated: true) == nil)
    }

    @Test("The kill switch publishes nothing at all")
    func disabledPublishesNothing() {
        var meter = SourceThroughputMeter(config: .disabled)
        var now: UInt64 = 0
        for _ in 0..<20 {
            now &+= Self.tickNs
            #expect(meter.noteDelivery(bytes: Self.tickBytes, nowNs: now) == nil)
        }
        #expect(meter.end(saturated: true) == nil)
        #expect(meter.drainRejected() == 0)
    }

    @Test("Host policy values are clamped into a sane meter config")
    func policyClampsHostValues() {
        var policy = AetherSourceBufferPolicy.stock
        policy.throughputMinBurstMs = 0
        policy.throughputMinBurstKB = 0
        policy.throughputMaxGapMs = 0
        let config = policy.throughputMeterConfig
        #expect(config.minActiveNs >= 50 * Self.ms)
        #expect(config.minBytes >= 16 * 1024)
        #expect(config.maxGapNs >= 10 * Self.ms)
    }

    @Test("Throughput measurement is on by default in the shipped policy")
    func enabledByDefault() {
        #expect(AetherSourceBufferPolicy.stock.throughputEnabled)
        #expect(AetherSourceBufferPolicy.stock.throughputMeterConfig.enabled)
    }
}
