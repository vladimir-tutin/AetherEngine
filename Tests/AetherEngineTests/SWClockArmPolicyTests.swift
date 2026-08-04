import XCTest
@testable import AetherEngine

final class SWClockArmPolicyTests: XCTestCase {
    func testHealthyAudioPathIsUntouchedBeforeGrace() {
        XCTAssertEqual(
            SWClockArmPolicy.decide(
                clockArmed: false,
                hasAudioDecoder: true,
                audioBuffersProduced: false,
                backpressureSeconds: SWClockArmPolicy.graceSeconds - 0.001
            ),
            .keepWaiting
        )
    }

    func testParkedUnarmedLoopRecoversFromVideo() {
        XCTAssertEqual(
            SWClockArmPolicy.decide(
                clockArmed: false,
                hasAudioDecoder: true,
                audioBuffersProduced: false,
                backpressureSeconds: SWClockArmPolicy.graceSeconds
            ),
            .armFromVideo(reason: "backpressure-starved-audio")
        )
    }

    func testExistingAudioOrClockOwnershipIsNeverStolen() {
        XCTAssertEqual(
            SWClockArmPolicy.decide(
                clockArmed: true,
                hasAudioDecoder: true,
                audioBuffersProduced: false,
                backpressureSeconds: 30
            ),
            .keepWaiting
        )
        XCTAssertEqual(
            SWClockArmPolicy.decide(
                clockArmed: false,
                hasAudioDecoder: true,
                audioBuffersProduced: true,
                backpressureSeconds: 30
            ),
            .keepWaiting
        )
    }

    func testVideoOnlySessionCanArmImmediately() {
        XCTAssertEqual(
            SWClockArmPolicy.decide(
                clockArmed: false,
                hasAudioDecoder: false,
                audioBuffersProduced: false,
                backpressureSeconds: 0
            ),
            .armFromVideo(reason: "no-audio-decoder")
        )
    }
}
