import Testing
import AetherLibavcodec
@testable import AetherEngine

/// Audit SEG-1: a crafted Matroska cluster time or a garbage live tfdt must degrade a packet, not
/// trap the pump on Int64 overflow.
struct SourceTimestampBoundsTests {

    private func withPacket(pts: Int64, dts: Int64, duration: Int64 = 0,
                            _ body: (UnsafeMutablePointer<AVPacket>) -> Void) throws {
        let packet = try #require(av_packet_alloc())
        defer {
            var owned: UnsafeMutablePointer<AVPacket>? = packet
            av_packet_free(&owned)
        }
        packet.pointee.pts = pts
        packet.pointee.dts = dts
        packet.pointee.duration = duration
        body(packet)
    }

    @Test func extremeSourceTimestampsBecomeUnset() throws {
        try withPacket(pts: Int64(1) << 62, dts: -(Int64(1) << 62), duration: -5) { packet in
            #expect(SourceTimestampBounds.sanitize(packet))
            #expect(packet.pointee.pts == Int64.min)
            #expect(packet.pointee.dts == Int64.min)
            #expect(packet.pointee.duration == 0)
        }
    }

    @Test func plausibleTimestampsPassUntouched() throws {
        // An epoch-anchored live tfdt at a 10 MHz timescale sits near 1.8e16.
        let epochTfdt: Int64 = 1_790_000_000 * 10_000_000
        try withPacket(pts: epochTfdt + 400_000, dts: epochTfdt, duration: 400_000) { packet in
            #expect(!SourceTimestampBounds.sanitize(packet))
            #expect(packet.pointee.pts == epochTfdt + 400_000)
            #expect(packet.pointee.dts == epochTfdt)
            #expect(packet.pointee.duration == 400_000)
        }
        try withPacket(pts: Int64.min, dts: -1800) { packet in
            #expect(!SourceTimestampBounds.sanitize(packet))
            #expect(packet.pointee.pts == Int64.min)
        }
    }

    @Test func tickArithmeticSaturatesInsteadOfTrapping() {
        let big = Int64(1) << 62
        #expect(SourceTimestampBounds.difference(big, -big) == Int64.max)
        #expect(SourceTimestampBounds.difference(-big, big) == Int64.min + 1)
        #expect(SourceTimestampBounds.sum(Int64.max, 1) == Int64.max)
        #expect(SourceTimestampBounds.sum(Int64.min + 1, -2) == Int64.min + 1)
        #expect(SourceTimestampBounds.difference(90_000, 1800) == 88_200)
    }

    @Test func rebaseMathSurvivesOppositeSignExtremes() {
        let big = Int64(1) << 62
        let shifted = HLSSegmentProducer.rebasedVideoShift(
            srcDts: -big, lastSrcDts: big, oldShift: -big, fallbackDurationPts: 1800)
        #expect(shifted.continuationDts == Int64.max)
        #expect(HLSSegmentProducer.seamDerivedAudioShift(audioBoundarySrcDts: big, seamOutAudioTb: -big) == Int64.max)
        #expect(HLSSegmentProducer.resolveVideoSampleDuration(
            existingDuration: 0, dts: big, nextDts: -big, fallback: 1800, capTicks: 90_000) == 1800)
    }
}
