import XCTest
@testable import AetherEngine

final class AudioDSPStereoPolicyTests: XCTestCase {
    func testStereoOutputModeEligibility() {
        XCTAssertEqual(AudioDSPSettings(outputMode: .source).outputChannels(forSource: 2), 2)
        XCTAssertEqual(AudioDSPSettings(outputMode: .stereo).outputChannels(forSource: 2), 2)
        XCTAssertEqual(AudioDSPSettings(outputMode: .surround51).outputChannels(forSource: 2), 2)
        XCTAssertEqual(AudioDSPSettings(outputMode: .surround51).outputChannels(forSource: 8), 6)
    }

    func testStereoDialogueBoostRaisesPhantomCentreWithoutDestroyingSide() {
        let processor = AudioDSPProcessor()
        let input: [Float] = [0.1, 0.1, 0.1, -0.1]
        var output = Array(repeating: Float.zero, count: input.count)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                _ = processor.process(
                    input: source.baseAddress!,
                    output: destination.baseAddress!,
                    frames: 2,
                    sourceChannels: 2,
                    settings: AudioDSPSettings(outputMode: .source, dialogueGainDb: 6),
                    sampleRate: 48_000
                )
            }
        }
        XCTAssertGreaterThan(output[0], 0.1)
        XCTAssertGreaterThan(output[1], 0.1)
        XCTAssertEqual(output[2], 0.1, accuracy: 0.0001)
        XCTAssertEqual(output[3], -0.1, accuracy: 0.0001)
    }

}
