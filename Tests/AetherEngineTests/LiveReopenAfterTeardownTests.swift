import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit HLS-2: a live reopen that slept through a zap must not open the old channel.
@Suite("Live reopen after teardown")
struct LiveReopenAfterTeardownTests {

    @Test("a reopen demuxer is only registered while the failed producer is still the session's")
    func registrationRequiresCurrentProducer() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = try #require(avcodec_parameters_alloc())
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/live.ts"),
                                    dvModeAvailable: false)
        let failed = try HLSSegmentProducer(
            demuxer: Demuxer(), videoStreamIndex: 0,
            video: .init(codecpar: UnsafePointer(codecpar!),
                         timeBase: AVRational(num: 1, den: 90_000), codecTagOverride: nil),
            cache: SegmentCache(forwardWindow: 4, backwardWindow: 4),
            videoFallbackDurationPts: 3_000, desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [0, 540_000])

        engine.producer = failed
        #expect(engine.registerReopenDemuxer(Demuxer(), failedProducer: failed))
        engine.stop()
        #expect(!engine.registerReopenDemuxer(Demuxer(), failedProducer: failed),
                "after stop() the reopen must not register (and so must not open)")
    }

    private final class CountingReader: IOReader, @unchecked Sendable {
        private let lock = NSLock()
        private var _reads = 0
        var reads: Int { lock.lock(); defer { lock.unlock() }; return _reads }
        func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
            lock.lock(); _reads += 1; lock.unlock()
            return 0
        }
        func seek(offset: Int64, whence: Int32) -> Int64 { -1 }
        func close() {}
        func cancel() {}
        func makeIndependentReader() -> IOReader? { nil }
        var discImageProbeEnabled: Bool { false }
    }

    @Test("a demuxer marked closed before its open never touches the source")
    func markClosedBeforeOpenAbortsTheOpen() {
        let demuxer = Demuxer()
        let reader = CountingReader()
        demuxer.markClosed()
        #expect(throws: DemuxerError.self) {
            try demuxer.open(reader: reader, formatHint: "mpegts", isLive: true)
        }
        #expect(reader.reads == 0)
    }
}
