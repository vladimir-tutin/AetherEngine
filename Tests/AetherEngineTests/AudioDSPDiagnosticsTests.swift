import XCTest
@testable import AetherEngine

/// The on-device diagnostics exist to separate "the matrix generated rear samples" from "the rear
/// speaker made a sound". These tests guard the properties that make it trustworthy: it must be
/// able to target one channel, it must not leak into others, and it must always be able to stop.
final class AudioDSPDiagnosticsTests: XCTestCase {

    private func run(
        settings: AudioDSPDiagnostics,
        frames: Int = 256,
        channels: Int = 6,
        program: Float = 0.25,
        sampleRate: Int32 = 48_000,
        processor: AudioDSPDiagnosticsProcessor = AudioDSPDiagnosticsProcessor()
    ) -> [Float] {
        var buffer = [Float](repeating: program, count: frames * channels)
        buffer.withUnsafeMutableBufferPointer { raw in
            _ = processor.apply(
                buffer: raw.baseAddress!,
                frames: frames,
                channels: channels,
                settings: settings,
                sampleRate: sampleRate
            )
        }
        return buffer
    }

    /// Peak magnitude of one interleaved channel.
    private func peak(_ buffer: [Float], channel: Int, channels: Int = 6) -> Float {
        stride(from: channel, to: buffer.count, by: channels).reduce(Float(0)) {
            max($0, abs(buffer[$1]))
        }
    }

    // MARK: - Off by default

    func testDefaultsAreInertAndOff() {
        XCTAssertFalse(AudioDSPDiagnostics.off.toneEnabled)
        XCTAssertFalse(AudioDSPDiagnostics.off.isActive)
        let out = run(settings: .off)
        // Untouched program audio.
        for channel in 0..<6 {
            XCTAssertEqual(peak(out, channel: channel), 0.25, accuracy: 0.0001)
        }
    }

    // MARK: - Targeting

    func testToneReachesOnlyTheTargetedChannels() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskRears
        settings.toneReplacesProgram = true
        settings.toneLevelDb = -6
        let out = run(settings: settings)

        // Rears carry the tone.
        XCTAssertGreaterThan(peak(out, channel: 4), 0.1)
        XCTAssertGreaterThan(peak(out, channel: 5), 0.1)
        // Everything else is untouched program audio — a tone that leaked would make the whole
        // test meaningless, because "I hear it" would stop identifying a speaker.
        for channel in [0, 1, 2, 3] {
            XCTAssertEqual(peak(out, channel: channel), 0.25, accuracy: 0.0001)
        }
    }

    func testSingleRearCanBeIsolatedToCatchASwappedPair() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskLs
        settings.toneReplacesProgram = true
        settings.toneLevelDb = -6
        let out = run(settings: settings)
        XCTAssertGreaterThan(peak(out, channel: 4), 0.1, "Ls must carry the tone")
        XCTAssertEqual(peak(out, channel: 5), 0.25, accuracy: 0.0001, "Rs must be untouched")
    }

    func testAdditiveToneKeepsProgramAudio() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskCentre
        settings.toneReplacesProgram = false
        settings.toneLevelDb = -20
        let out = run(settings: settings)
        // Program (0.25) plus a small tone: strictly greater than program, nowhere near replaced.
        XCTAssertGreaterThan(peak(out, channel: 2), 0.25)
    }

    // MARK: - Solo / mute

    func testSoloSilencesEverythingElse() {
        var settings = AudioDSPDiagnostics.off
        settings.soloChannelMask = AudioDSPDiagnostics.maskLs
        let out = run(settings: settings)
        XCTAssertEqual(peak(out, channel: 4), 0.25, accuracy: 0.0001)
        for channel in [0, 1, 2, 3, 5] {
            XCTAssertEqual(peak(out, channel: channel), 0, accuracy: 0.0001)
        }
    }

    func testMuteAppliesAfterSolo() {
        var settings = AudioDSPDiagnostics.off
        settings.soloChannelMask = AudioDSPDiagnostics.maskRears
        settings.muteChannelMask = AudioDSPDiagnostics.maskRs
        let out = run(settings: settings)
        XCTAssertEqual(peak(out, channel: 4), 0.25, accuracy: 0.0001, "Ls soloed")
        XCTAssertEqual(peak(out, channel: 5), 0, accuracy: 0.0001, "Rs soloed but then muted")
        XCTAssertEqual(peak(out, channel: 0), 0, accuracy: 0.0001)
    }

    func testSoloAppliesToTheToneToo() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskAll
        settings.toneReplacesProgram = true
        settings.toneLevelDb = -6
        settings.soloChannelMask = AudioDSPDiagnostics.maskLs
        let out = run(settings: settings)
        XCTAssertGreaterThan(peak(out, channel: 4), 0.1)
        for channel in [0, 1, 2, 3, 5] {
            XCTAssertEqual(peak(out, channel: channel), 0, accuracy: 0.0001)
        }
    }

    // MARK: - Safety

    func testToneLevelIsClampedWellBelowFullScale() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskAll
        settings.toneLevelDb = 40            // absurd request
        settings.toneReplacesProgram = true
        XCTAssertLessThanOrEqual(settings.sanitized.toneLevelDb, -6)
        let out = run(settings: settings)
        // -6 dBFS is ~0.5; nothing may approach full scale through someone's speakers.
        XCTAssertLessThan(peak(out, channel: 0), 0.55)
    }

    func testSanitizerClampsFrequencyAndTimeoutAndMasks() {
        var wild = AudioDSPDiagnostics.off
        wild.toneFrequencyHz = 500_000
        wild.toneTimeoutSeconds = 99_999
        wild.toneChannelMask = 0xFF
        wild.toneLevelDb = .nan
        let safe = wild.sanitized
        XCTAssertEqual(safe.toneFrequencyHz, 20_000)
        XCTAssertEqual(safe.toneTimeoutSeconds, 600)
        XCTAssertEqual(safe.toneChannelMask, AudioDSPDiagnostics.maskAll)
        XCTAssertEqual(safe.toneLevelDb, -18)
    }

    func testToneAutoStopsAfterItsTimeout() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskRears
        settings.toneReplacesProgram = true
        settings.toneLevelDb = -6
        settings.toneTimeoutSeconds = 0.001      // 48 frames at 48 kHz
        let processor = AudioDSPDiagnosticsProcessor()

        let first = run(settings: settings, frames: 48, processor: processor)
        XCTAssertGreaterThan(peak(first, channel: 4), 0.1, "tone should sound before the timeout")

        // Well past the timeout: the tone must have stopped on its own.
        let second = run(settings: settings, frames: 256, processor: processor)
        XCTAssertEqual(
            peak(second, channel: 4), 0.25, accuracy: 0.0001,
            "after the timeout the channel must return to program audio"
        )
    }

    func testRetuningRestartsTheTimeout() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskRears
        settings.toneReplacesProgram = true
        settings.toneLevelDb = -6
        settings.toneTimeoutSeconds = 0.001
        let processor = AudioDSPDiagnosticsProcessor()

        _ = run(settings: settings, frames: 512, processor: processor)   // expire it
        settings.toneFrequencyHz = 880                                    // retune = new activation
        let after = run(settings: settings, frames: 48, processor: processor)
        XCTAssertGreaterThan(peak(after, channel: 4), 0.1, "a retune must re-arm the tone")
    }

    func testResetStopsAToneImmediately() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskRears
        settings.toneReplacesProgram = true
        settings.toneLevelDb = -6
        let processor = AudioDSPDiagnosticsProcessor()
        _ = run(settings: settings, frames: 128, processor: processor)
        processor.reset()
        let out = run(settings: .off, frames: 128, processor: processor)
        for channel in 0..<6 {
            XCTAssertEqual(peak(out, channel: channel), 0.25, accuracy: 0.0001)
        }
    }

    func testMaskDescriptionIsReadable() {
        XCTAssertEqual(AudioDSPDiagnostics.describe(mask: AudioDSPDiagnostics.maskRears), "Ls+Rs")
        XCTAssertEqual(AudioDSPDiagnostics.describe(mask: 0), "none")
        XCTAssertEqual(AudioDSPDiagnostics.describe(mask: AudioDSPDiagnostics.maskCentre), "C")
    }

    /// A stereo session has no rear channels to target; the applier must simply not write past the
    /// end of the buffer.
    func testNarrowerBufferIsNotOverrun() {
        var settings = AudioDSPDiagnostics.off
        settings.toneEnabled = true
        settings.toneChannelMask = AudioDSPDiagnostics.maskRears
        settings.toneReplacesProgram = true
        let out = run(settings: settings, frames: 64, channels: 2)
        XCTAssertEqual(out.count, 128)
        for index in 0..<out.count {
            XCTAssertEqual(out[index], 0.25, accuracy: 0.0001, "stereo buffer must be untouched")
        }
    }
}
