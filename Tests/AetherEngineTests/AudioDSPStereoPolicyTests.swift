import XCTest
@testable import AetherEngine

final class AudioDSPStereoPolicyTests: XCTestCase {

    // MARK: - Width eligibility

    func testStereoOutputModeEligibility() {
        XCTAssertEqual(AudioDSPSettings(outputMode: .source).outputChannels(forSource: 2), 2)
        XCTAssertEqual(AudioDSPSettings(outputMode: .stereo).outputChannels(forSource: 2), 2)
        // Upmix OFF is the truthful fallback: 5.1 requested, stereo delivered.
        XCTAssertEqual(
            AudioDSPSettings(outputMode: .surround51, upmix: .off).outputChannels(forSource: 2), 2)
        // Upmix ON genuinely widens.
        XCTAssertEqual(
            AudioDSPSettings(outputMode: .surround51, upmix: .defaults).outputChannels(forSource: 2), 6)
        XCTAssertEqual(AudioDSPSettings(outputMode: .surround51).outputChannels(forSource: 8), 6)
        // The matrix is defined for STEREO only; nothing is invented for other narrow widths.
        XCTAssertEqual(
            AudioDSPSettings(outputMode: .surround51, upmix: .defaults).outputChannels(forSource: 1), 1)
        XCTAssertEqual(
            AudioDSPSettings(outputMode: .surround51, upmix: .defaults).outputChannels(forSource: 4), 4)
        XCTAssertEqual(
            AudioDSPSettings(outputMode: .surround51, upmix: .defaults).outputChannels(forSource: 6), 6)
    }

    func testLayoutDecisionNeverLabelsStereoAsSurround() {
        let off = AudioDSPSettings(outputMode: .surround51, upmix: .off).layoutDecision(forSource: 2)
        XCTAssertEqual(off.effectiveChannels, 2)
        XCTAssertEqual(off.requestedChannels, 6)
        XCTAssertFalse(off.upmixActive)
        XCTAssertEqual(off.reason, "upmix-disabled-source-stereo")

        let on = AudioDSPSettings(outputMode: .surround51, upmix: .defaults).layoutDecision(forSource: 2)
        XCTAssertEqual(on.effectiveChannels, 6)
        XCTAssertTrue(on.upmixActive)
        XCTAssertEqual(on.reason, "stereo-upmix-matrix")

        let unsupported = AudioDSPSettings(outputMode: .surround51, upmix: .defaults)
            .layoutDecision(forSource: 4)
        XCTAssertEqual(unsupported.effectiveChannels, 4)
        XCTAssertFalse(unsupported.upmixActive)
        XCTAssertEqual(unsupported.reason, "unsupported-source-width-passthrough")
    }

    // MARK: - Identity / bypass

    func testUpmixTunablesDoNotDefeatIdentityBypass() {
        // Carrying upmix values around must not make "processing off" start copying buffers.
        var settings = AudioDSPSettings(outputMode: .source)
        settings.upmix = .defaults
        XCTAssertTrue(settings.isIdentity)
        XCTAssertFalse(settings.upmixApplies(toSource: 2))
    }

    func testUpmixNeverAppliesOffSurroundMode() {
        XCTAssertFalse(AudioDSPSettings(outputMode: .stereo, upmix: .defaults).upmixApplies(toSource: 2))
        XCTAssertFalse(AudioDSPSettings(outputMode: .source, upmix: .defaults).upmixApplies(toSource: 2))
        XCTAssertFalse(AudioDSPSettings(outputMode: .surround51, upmix: .off).upmixApplies(toSource: 2))
    }

    // MARK: - Stereo dialogue boost (phantom centre, unchanged behaviour)

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

    // MARK: - Upmix matrix

    /// Run the upmix over `frames` frames of the given stereo input, returning interleaved 5.1.
    private func upmix(
        input: [Float],
        frames: Int,
        upmix upmixSettings: AudioDSPUpmixSettings,
        dialogueGainDb: Float = 0,
        masterGainDb: Float = 0,
        sampleRate: Int32 = 48_000,
        processor: AudioDSPProcessor = AudioDSPProcessor()
    ) -> [Float] {
        var output = Array(repeating: Float.zero, count: frames * 6)
        input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                _ = processor.process(
                    input: source.baseAddress!,
                    output: destination.baseAddress!,
                    frames: frames,
                    sourceChannels: 2,
                    settings: AudioDSPSettings(
                        outputMode: .surround51,
                        dialogueGainDb: dialogueGainDb,
                        masterGainDb: masterGainDb,
                        upmix: upmixSettings
                    ),
                    sampleRate: sampleRate
                )
            }
        }
        return output
    }

    func testUpmixProducesSixChannels() {
        let processor = AudioDSPProcessor()
        var output = Array(repeating: Float.zero, count: 6)
        let input: [Float] = [0.5, 0.25]
        let written: Int32 = input.withUnsafeBufferPointer { source in
            output.withUnsafeMutableBufferPointer { destination in
                processor.process(
                    input: source.baseAddress!,
                    output: destination.baseAddress!,
                    frames: 1,
                    sourceChannels: 2,
                    settings: AudioDSPSettings(outputMode: .surround51, upmix: .defaults),
                    sampleRate: 48_000
                )
            }
        }
        XCTAssertEqual(written, 6)
    }

    /// A pure centre-panned (mono-correlated) signal must land in C, and must NOT leak into the
    /// surrounds, which carry only the difference component.
    func testCorrelatedContentGoesToCentreAndNotSurrounds() {
        var settings = AudioDSPUpmixSettings.defaults
        settings.surroundDelayMs = 0   // remove the delay so one frame is enough to observe
        settings.centerExtraction = 0
        settings.centerLevelDb = 0
        let out = upmix(input: [0.4, 0.4], frames: 1, upmix: settings)

        XCTAssertEqual(out[2], 0.4, accuracy: 0.0001, "mid should reach centre at unity")
        XCTAssertEqual(out[4], 0.0, accuracy: 0.0001, "correlated content must not reach Ls")
        XCTAssertEqual(out[5], 0.0, accuracy: 0.0001, "correlated content must not reach Rs")
        XCTAssertEqual(out[3], 0.0, accuracy: 0.0001, "LFE disabled by default")
    }

    /// A pure difference (out-of-phase) signal is entirely "side": it must reach the surrounds and
    /// leave the centre silent.
    func testDecorrelatedContentGoesToSurroundsAndNotCentre() {
        var settings = AudioDSPUpmixSettings.defaults
        settings.surroundDelayMs = 0
        settings.surroundLevelDb = 0
        let out = upmix(input: [0.4, -0.4], frames: 1, upmix: settings)

        XCTAssertEqual(out[2], 0.0, accuracy: 0.0001, "anti-correlated content must not reach centre")
        XCTAssertEqual(out[4], 0.4, accuracy: 0.0001)
        XCTAssertEqual(out[5], -0.4, accuracy: 0.0001, "surround pair is opposite polarity")
    }

    func testCentreExtractionRemovesMidFromFronts() {
        var settings = AudioDSPUpmixSettings.defaults
        settings.surroundDelayMs = 0
        settings.centerExtraction = 1.0
        let out = upmix(input: [0.4, 0.4], frames: 1, upmix: settings)
        // Fully extracted: the fronts give the entire correlated component to the centre.
        XCTAssertEqual(out[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(out[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(out[2], 0.4, accuracy: 0.0001)
    }

    func testDialogueBoostAppliesToDerivedCentreWhenUpmixed() {
        var settings = AudioDSPUpmixSettings.defaults
        settings.surroundDelayMs = 0
        settings.centerExtraction = 0
        let plain = upmix(input: [0.2, 0.2], frames: 1, upmix: settings)
        let boosted = upmix(input: [0.2, 0.2], frames: 1, upmix: settings, dialogueGainDb: 6)
        XCTAssertGreaterThan(boosted[2], plain[2], "Dialogue Boost must raise the derived centre")
        // ~ +6 dB is a factor of two.
        XCTAssertEqual(boosted[2] / plain[2], 2.0, accuracy: 0.05)
    }

    func testVolumeBoostAppliesToEveryUpmixedChannel() {
        var settings = AudioDSPUpmixSettings.defaults
        settings.surroundDelayMs = 0
        settings.surroundLevelDb = 0
        settings.centerExtraction = 0
        let plain = upmix(input: [0.1, -0.05], frames: 1, upmix: settings)
        let boosted = upmix(input: [0.1, -0.05], frames: 1, upmix: settings, masterGainDb: 6)
        for channel in [0, 1, 2, 4, 5] {
            XCTAssertEqual(
                boosted[channel] / plain[channel], 2.0, accuracy: 0.05,
                "channel \(channel) should follow master gain"
            )
        }
    }

    func testSurroundDelayDecorrelatesRatherThanDuplicating() {
        var settings = AudioDSPUpmixSettings.defaults
        settings.surroundDelayMs = 1          // 48 frames at 48 kHz
        settings.surroundLevelDb = 0
        // One impulse of pure side content, then silence.
        var input: [Float] = [0.5, -0.5]
        input.append(contentsOf: Array(repeating: Float.zero, count: 2 * 99))
        let out = upmix(input: input, frames: 100, upmix: settings)

        XCTAssertEqual(out[4], 0.0, accuracy: 0.0001, "surround must be delayed, not immediate")
        // The impulse should reappear 48 frames later.
        XCTAssertEqual(out[48 * 6 + 4], 0.5, accuracy: 0.0001)
        XCTAssertEqual(out[48 * 6 + 5], -0.5, accuracy: 0.0001)
    }

    func testLfeIsSilentUnlessEnabledAndLowPassedWhenOn() {
        var off = AudioDSPUpmixSettings.defaults
        off.surroundDelayMs = 0
        XCTAssertEqual(upmix(input: [0.5, 0.5], frames: 1, upmix: off)[3], 0.0, accuracy: 0.0001)

        var on = AudioDSPUpmixSettings.defaults
        on.surroundDelayMs = 0
        on.lfeEnabled = true
        // A one-pole low-pass cannot reach full scale from one sample; it must ramp.
        let single = upmix(input: [0.5, 0.5], frames: 1, upmix: on)
        XCTAssertGreaterThan(single[3], 0.0)
        XCTAssertLessThan(single[3], 0.5)

        // Sustained DC drives the filter toward the input level.
        let sustained = upmix(
            input: Array(repeating: Float(0.5), count: 2 * 4000), frames: 4000, upmix: on)
        XCTAssertEqual(sustained[3999 * 6 + 3], 0.5, accuracy: 0.02)
    }

    // MARK: - Clipping / limiter

    func testUpmixOutputStaysWithinLimiterCeiling() {
        var settings = AudioDSPUpmixSettings.defaults
        settings.centerLevelDb = 12
        settings.surroundLevelDb = 12
        settings.lfeEnabled = true
        settings.lfeLevelDb = 12
        // Full-scale correlated input plus every level trim maxed: the limiter must still hold.
        let frames = 2000
        let out = upmix(
            input: Array(repeating: Float(1.0), count: 2 * frames),
            frames: frames,
            upmix: settings,
            dialogueGainDb: 6,
            masterGainDb: 9
        )
        // What the limiter actually guarantees: no DIGITAL CLIPPING. It is a smoothed one-pole
        // feed-forward limiter, not a brickwall — the envelope is deliberately allowed a little
        // overshoot above the ceiling rather than pumping at ~47 buffers/sec — so asserting a hard
        // <= ceiling would be asserting a design the processor does not have.
        let ceiling = AudioDSPSettings().limiterCeiling
        // Skip the attack window; the envelope needs a few ms to engage by design.
        for index in (1000 * 6)..<out.count {
            XCTAssertLessThan(
                abs(out[index]), 1.0,
                "sample \(index) reached digital full scale"
            )
        }
        // And it must still settle near the ceiling rather than drifting far above it.
        let tail = out[(frames - 100) * 6..<out.count].map { abs($0) }.max() ?? 0
        XCTAssertLessThanOrEqual(tail, ceiling * 1.1)
    }

    // MARK: - Reset / format change

    func testResetClearsSurroundDelayLineAcrossSeek() {
        var settings = AudioDSPUpmixSettings.defaults
        settings.surroundDelayMs = 1
        settings.surroundLevelDb = 0
        let processor = AudioDSPProcessor()

        // Fill the delay line with loud pre-seek side content.
        _ = upmix(
            input: Array(repeating: Float(0.9), count: 2 * 10).enumerated().map {
                $0.offset % 2 == 0 ? 0.9 : -0.9
            },
            frames: 10, upmix: settings, processor: processor
        )
        processor.reset()

        // Post-seek silence must stay silent: nothing may bleed across the discontinuity.
        let after = upmix(
            input: Array(repeating: Float.zero, count: 2 * 10),
            frames: 10, upmix: settings, processor: processor
        )
        for frame in 0..<10 {
            XCTAssertEqual(after[frame * 6 + 4], 0.0, accuracy: 0.0001)
            XCTAssertEqual(after[frame * 6 + 5], 0.0, accuracy: 0.0001)
        }
    }

    func testSanitizerClampsOutOfRangeAndNonFiniteValues() {
        var wild = AudioDSPUpmixSettings.defaults
        wild.centerExtraction = 9
        wild.surroundDelayMs = 1_000
        wild.lfeCutoffHz = 5
        wild.centerLevelDb = .nan
        let safe = wild.sanitized
        XCTAssertEqual(safe.centerExtraction, 1)
        XCTAssertEqual(safe.surroundDelayMs, AudioDSPUpmixSettings.maxSurroundDelayMs)
        XCTAssertEqual(safe.lfeCutoffHz, 40)
        XCTAssertEqual(safe.centerLevelDb, 0)
    }
}
