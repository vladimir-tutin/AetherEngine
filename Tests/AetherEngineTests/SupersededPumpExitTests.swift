import Testing
import Foundation
import AetherLibavcodec
import AetherLibavutil
@testable import AetherEngine

/// Audit HLS-1: a producer the session already replaced (the #79 wedge abort, or `stop()`)
/// reports its aborted read as a read error. That exit must not reach the session's recovery
/// arms: no revive-gate spend, no seek-state or failure signal to the host.
@Suite("Superseded pump exit")
struct SupersededPumpExitTests {

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _failures = 0
        private var _seekSignals = 0
        var failures: Int { lock.lock(); defer { lock.unlock() }; return _failures }
        var seekSignals: Int { lock.lock(); defer { lock.unlock() }; return _seekSignals }
        func fail() { lock.lock(); _failures += 1; lock.unlock() }
        func seek() { lock.lock(); _seekSignals += 1; lock.unlock() }
    }

    private func makeProducer(codecpar: UnsafeMutablePointer<AVCodecParameters>) throws -> HLSSegmentProducer {
        try HLSSegmentProducer(
            demuxer: Demuxer(),
            videoStreamIndex: 0,
            video: .init(codecpar: UnsafePointer(codecpar),
                         timeBase: AVRational(num: 1, den: 90_000),
                         codecTagOverride: nil),
            cache: SegmentCache(forwardWindow: 4, backwardWindow: 4),
            videoFallbackDurationPts: 3_000,
            desiredFirstVideoTfdtPts: 0,
            segmentBoundaries: [0, 540_000]
        )
    }

    private func makeEngine(_ recorder: Recorder) -> HLSVideoEngine {
        let engine = HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/superseded.mkv"),
                                    dvModeAvailable: false)
        engine.onVODSourceFailed = { _, _, _ in recorder.fail() }
        engine.onSeekStateChanged = { _, _ in recorder.seek() }
        return engine
    }

    @Test("a read error from a replaced producer spends nothing and signals nothing")
    func supersededReadErrorIsIgnored() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = try #require(avcodec_parameters_alloc())
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO

        let recorder = Recorder()
        let engine = makeEngine(recorder)
        let stale = try makeProducer(codecpar: codecpar!)
        let current = try makeProducer(codecpar: codecpar!)
        engine.producer = current

        engine.handlePumpFinished(stale, reason: .readError(code: -1))
        engine.producer = nil
        engine.handlePumpFinished(stale, reason: .readError(code: -1))

        #expect(engine.readErrorReviveGate.attempts == 0)
        #expect(!engine.mainDemuxerSuspectDead)
        #expect(recorder.failures == 0)
        #expect(recorder.seekSignals == 0)
    }

    @Test("the same read error from the session's own producer still reaches the recovery arms")
    func currentReadErrorIsHandled() throws {
        var codecpar: UnsafeMutablePointer<AVCodecParameters>? = try #require(avcodec_parameters_alloc())
        defer { avcodec_parameters_free(&codecpar) }
        codecpar!.pointee.codec_id = AV_CODEC_ID_H264
        codecpar!.pointee.codec_type = AVMEDIA_TYPE_VIDEO

        let recorder = Recorder()
        let engine = makeEngine(recorder)
        let current = try makeProducer(codecpar: codecpar!)
        engine.producer = current

        engine.handlePumpFinished(current, reason: .readError(code: -1))

        #expect(recorder.failures == 1)
    }
}
