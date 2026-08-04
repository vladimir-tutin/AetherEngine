import XCTest
@testable import AetherEngine

/// Guards the fix for the ~0.5 s on / ~0.5 s off AAC dropout during Direct Play with live DSP.
///
/// The defect was structural: one demux thread served both streams, and its video branch parked on
/// the video renderer's readiness. A full video renderer is the NORMAL steady state, so on every
/// cycle the loop stopped reading entirely and the audio renderer drained to silence.
///
/// These tests assert the invariant that makes that impossible: while the audio renderer still
/// wants data, the loop must never stop reading because of video.
final class SWVideoBackpressurePolicyTests: XCTestCase {

    private func decide(
        video: Bool,
        audio: Bool,
        hasAudio: Bool = true,
        stashed: Int = 0,
        bytes: Int = 0
    ) -> SWVideoBackpressurePolicy.Decision {
        SWVideoBackpressurePolicy.decide(
            videoRendererReady: video,
            audioRendererReady: audio,
            hasAudioStream: hasAudio,
            stashedPackets: stashed,
            stashedBytes: bytes
        )
    }

    // MARK: - The defect itself

    func testFullVideoRendererNeverStopsReadingWhileAudioIsHungry() {
        // This exact combination is what produced the dropout.
        XCTAssertEqual(
            decide(video: false, audio: true),
            .stashAndKeepReading(reason: "audio-renderer-hungry")
        )
    }

    func testParkingIsOnlyAllowedWhenAudioIsAlsoSatisfied() {
        XCTAssertEqual(
            decide(video: false, audio: false),
            .park(reason: "both-renderers-satisfied")
        )
    }

    func testRendererWithRoomDecodesImmediately() {
        XCTAssertEqual(decide(video: true, audio: true), .decodeNow)
        XCTAssertEqual(decide(video: true, audio: false), .decodeNow)
    }

    // MARK: - Ordering

    func testHeldPacketsAreDrainedBeforeNewOnesAreAdmitted() {
        // Renderer has room but packets are still held: the caller must drain first, so this must
        // NOT report decodeNow (which would decode the new packet ahead of older held ones).
        XCTAssertNotEqual(decide(video: true, audio: true, stashed: 3), .decodeNow)
    }

    // MARK: - Memory backstops

    func testStashIsCappedByPacketCount() {
        XCTAssertEqual(
            decide(video: false, audio: true,
                   stashed: SWVideoBackpressurePolicy.maxStashedPackets),
            .park(reason: "stash-packet-cap")
        )
    }

    func testStashIsCappedByBytes() {
        XCTAssertEqual(
            decide(video: false, audio: true, stashed: 1,
                   bytes: SWVideoBackpressurePolicy.maxStashedBytes),
            .park(reason: "stash-byte-cap")
        )
    }

    // MARK: - Unrelated paths must be untouched

    func testVideoOnlySessionParksExactlyAsBefore() {
        // No audio to protect: stashing would only add latency and memory.
        XCTAssertEqual(
            decide(video: false, audio: false, hasAudio: false),
            .park(reason: "no-audio-stream")
        )
        XCTAssertEqual(decide(video: true, audio: false, hasAudio: false), .decodeNow)
    }

    // MARK: - Stream-shape simulations

    /// Drive the policy over a synthetic packet sequence and report how long audio ever goes
    /// without being reachable. Returns the longest run of consecutive video packets during which
    /// the loop was parked (i.e. could not read the audio packets that follow).
    private func longestBlockedRun(
        packets: [Bool],                 // true = video, false = audio
        videoReadyEvery: Int,            // renderer opens up once every N decisions
        audioStaysHungryFor: Int         // audio renderer accepts data for the first N audio packets
    ) -> Int {
        var stashed = 0
        var audioFed = 0
        var blockedRun = 0
        var worstBlockedRun = 0
        var tick = 0

        for isVideo in packets {
            tick += 1
            let videoReady = (tick % videoReadyEvery == 0)
            if !isVideo {
                // An audio packet can only be reached if the loop is not parked.
                if blockedRun == 0 {
                    audioFed += 1
                    blockedRun = 0
                }
                continue
            }
            let audioReady = audioFed < audioStaysHungryFor
            switch SWVideoBackpressurePolicy.decide(
                videoRendererReady: videoReady,
                audioRendererReady: audioReady,
                hasAudioStream: true,
                stashedPackets: stashed,
                stashedBytes: stashed * 30_000
            ) {
            case .decodeNow:
                blockedRun = 0
            case .stashAndKeepReading:
                stashed += 1
                blockedRun = 0          // reading continues, so audio remains reachable
            case .park:
                blockedRun += 1
                worstBlockedRun = max(worstBlockedRun, blockedRun)
            }
        }
        return worstBlockedRun
    }

    func testEvenlyInterleavedStreamNeverBlocksWhileAudioIsHungry() {
        // Ordinary MP4 interleave: V A V A V A …
        let packets = (0..<400).map { $0 % 2 == 0 }
        let worst = longestBlockedRun(
            packets: packets, videoReadyEvery: 25, audioStaysHungryFor: 10_000)
        XCTAssertEqual(worst, 0, "audio must stay reachable through normal video back-pressure")
    }

    func testClusteredStreamNeverBlocksWhileAudioIsHungry() {
        // Hostile interleave: long runs of video before any audio arrives. This is the shape that
        // makes a park catastrophic, because the audio packet is far past the parked read cursor.
        var packets: [Bool] = []
        for _ in 0..<20 {
            packets.append(contentsOf: Array(repeating: true, count: 30))   // 30 video
            packets.append(contentsOf: Array(repeating: false, count: 5))   // then 5 audio
        }
        let worst = longestBlockedRun(
            packets: packets, videoReadyEvery: 25, audioStaysHungryFor: 10_000)
        XCTAssertEqual(worst, 0, "clustered video must not strand the audio packets behind it")
    }

    func testLoopStillParksOnceAudioIsFullSoItDoesNotSpin() {
        // The complement: with audio satisfied the policy must park rather than read the whole file
        // into memory.
        let packets = (0..<400).map { $0 % 2 == 0 }
        let worst = longestBlockedRun(
            packets: packets, videoReadyEvery: 1_000_000, audioStaysHungryFor: 0)
        XCTAssertGreaterThan(worst, 0, "a satisfied pipeline must be allowed to park")
    }
}
