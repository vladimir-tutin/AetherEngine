import Foundation

/// On-device PCM diagnostics for the decoded-PCM lane: per-channel test tones, solo and mute.
///
/// WHY THIS EXISTS: `[AudioDSPLevels]` can prove the matrix GENERATED nonzero `Ls/Rs` samples, and
/// `[AudioOutputFormat]` can prove CoreMedia received a six-channel buffer with a 5.1 layout tag.
/// Neither can prove the samples reached the correct SPEAKER. If PCM levels are nonzero and the
/// receiver is still silent, the remaining suspects are channel mapping, the audio route, or the
/// receiver itself — and telling those apart needs a signal you can point at one speaker at a time.
///
/// A tone injected here sits at exactly the same point as the program audio (post-DSP, post-limiter,
/// immediately before the CMSampleBuffer is built), so "tone audible" and "program audible" exercise
/// an identical path. Anything that swallows one swallows the other.
///
/// SAFETY: this is a diagnostic, not a feature. It defaults OFF, is never persisted, auto-stops on a
/// timeout so a forgotten tone cannot ruin playback, and is cleared whenever a session loads.
public struct AudioDSPDiagnostics: Sendable, Equatable {

    /// Interleaved channel order for `kAudioChannelLayoutTag_MPEG_5_1_A`, which is what
    /// `audioChannelLayoutTag(for: 6)` declares. Bit N of every mask below is this channel.
    public static let channelNames = ["L", "R", "C", "LFE", "Ls", "Rs"]

    public static let maskNone: UInt8 = 0
    public static let maskAll: UInt8 = 0b111111
    public static let maskFronts: UInt8 = 0b000011
    public static let maskCentre: UInt8 = 0b000100
    public static let maskLFE: UInt8 = 0b001000
    /// Ls + Rs — the pair this whole investigation is about.
    public static let maskRears: UInt8 = 0b110000
    public static let maskLs: UInt8 = 0b010000
    public static let maskRs: UInt8 = 0b100000

    /// Master switch for the tone generator.
    public var toneEnabled: Bool
    /// Which channels receive the tone. `maskRears` answers "is anything reaching the surrounds".
    public var toneChannelMask: UInt8
    public var toneFrequencyHz: Float
    public var toneLevelDb: Float
    /// True replaces the program audio on the toned channels; false adds the tone on top.
    /// Replacing is the decisive test — silence anywhere else cannot be mistaken for the tone.
    public var toneReplacesProgram: Bool
    /// Auto-stop after this many seconds of tone. A live tone always has a timeout; allowing zero
    /// would let a forgotten diagnostic survive indefinitely and defeat the build's safety gate.
    public var toneTimeoutSeconds: Double

    /// When non-zero, ONLY these channels pass; everything else is silenced. Applied to program
    /// audio and tone alike, so "solo Ls" is a complete answer about one speaker.
    public var soloChannelMask: UInt8
    /// Channels forced to silence. Applied after solo.
    public var muteChannelMask: UInt8

    public init(
        toneEnabled: Bool = false,
        toneChannelMask: UInt8 = AudioDSPDiagnostics.maskRears,
        toneFrequencyHz: Float = 440,
        toneLevelDb: Float = -18,
        toneReplacesProgram: Bool = true,
        toneTimeoutSeconds: Double = 30,
        soloChannelMask: UInt8 = 0,
        muteChannelMask: UInt8 = 0
    ) {
        self.toneEnabled = toneEnabled
        self.toneChannelMask = toneChannelMask
        self.toneFrequencyHz = toneFrequencyHz
        self.toneLevelDb = toneLevelDb
        self.toneReplacesProgram = toneReplacesProgram
        self.toneTimeoutSeconds = toneTimeoutSeconds
        self.soloChannelMask = soloChannelMask
        self.muteChannelMask = muteChannelMask
    }

    /// Everything off — the shipped default and the state a session load restores.
    public static let off = AudioDSPDiagnostics()

    /// Whether this touches a single sample. Used to keep the decoder's fast path untouched.
    public var isActive: Bool {
        (toneEnabled && toneChannelMask != 0) || soloChannelMask != 0 || muteChannelMask != 0
    }

    /// Clamped values for the render path, so a bad live push cannot produce NaNs or full-scale
    /// blasts. -6 dBFS is a deliberate ceiling: this plays through someone's living room.
    public var sanitized: AudioDSPDiagnostics {
        var copy = self
        copy.toneChannelMask = toneChannelMask & Self.maskAll
        copy.soloChannelMask = soloChannelMask & Self.maskAll
        copy.muteChannelMask = muteChannelMask & Self.maskAll
        copy.toneFrequencyHz = min(max(toneFrequencyHz.isFinite ? toneFrequencyHz : 440, 20), 20_000)
        copy.toneLevelDb = min(max(toneLevelDb.isFinite ? toneLevelDb : -18, -60), -6)
        copy.toneTimeoutSeconds = toneTimeoutSeconds.isFinite
            ? min(max(toneTimeoutSeconds, 1), 600)
            : 30
        return copy
    }

    /// Human-readable mask, for logs that a person has to read while holding a remote.
    public static func describe(mask: UInt8) -> String {
        guard mask != 0 else { return "none" }
        var parts: [String] = []
        for index in 0..<channelNames.count where mask & (1 << UInt8(index)) != 0 {
            parts.append(channelNames[index])
        }
        return parts.joined(separator: "+")
    }
}

/// Stateful applier. Owned by `AudioDecoder`, touched only from the decode thread.
final class AudioDSPDiagnosticsProcessor {

    /// Sine phase carried ACROSS buffers; restarting it every buffer would click at ~47 Hz.
    private var phase: Double = 0
    /// Frames of tone emitted since this activation, for the sample-accurate timeout. Wall-clock
    /// would be wrong here: this runs on the decode thread, which is not real time during a seek.
    private var toneFrames: Int = 0
    /// Identity of the current activation, so changing frequency/target restarts the timeout.
    private var activationKey: String = ""
    private var timedOut = false

    func reset() {
        phase = 0
        toneFrames = 0
        activationKey = ""
        timedOut = false
    }

    /// True while a tone is being emitted (i.e. enabled and not timed out).
    private(set) var toneIsSounding = false

    /// Apply tone/solo/mute in place. Returns a short decision string for telemetry, or nil when
    /// nothing was touched.
    @discardableResult
    func apply(
        buffer: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int,
        settings raw: AudioDSPDiagnostics,
        sampleRate: Int32
    ) -> String? {
        let settings = raw.sanitized
        guard frames > 0, channels > 0, settings.isActive else {
            if toneIsSounding { toneIsSounding = false }
            return nil
        }

        // A change of target/frequency/level is a NEW activation: restart the timeout so a retune
        // does not inherit an already-expired one.
        let key = "\(settings.toneEnabled)|\(settings.toneChannelMask)|"
            + "\(settings.toneFrequencyHz)|\(settings.toneLevelDb)|\(settings.toneTimeoutSeconds)"
        if key != activationKey {
            activationKey = key
            toneFrames = 0
            timedOut = false
            phase = 0
        }

        let rate = Double(max(sampleRate, 8000))
        var emittedTone = false

        // ── Tone ────────────────────────────────────────────────────────────────────────────
        if settings.toneEnabled, settings.toneChannelMask != 0, !timedOut {
            let amplitude = powf(10.0, settings.toneLevelDb / 20.0)
            let increment = 2.0 * Double.pi * Double(settings.toneFrequencyHz) / rate
            let timeoutFrames = settings.toneTimeoutSeconds > 0
                ? Int(settings.toneTimeoutSeconds * rate)
                : Int.max

            for frame in 0..<frames {
                if toneFrames >= timeoutFrames { timedOut = true; break }
                let value = Float(sin(phase)) * amplitude
                phase += increment
                if phase > 2.0 * Double.pi { phase -= 2.0 * Double.pi }
                let base = frame * channels
                for channel in 0..<min(channels, 6)
                where settings.toneChannelMask & (1 << UInt8(channel)) != 0 {
                    if settings.toneReplacesProgram {
                        buffer[base + channel] = value
                    } else {
                        buffer[base + channel] += value
                    }
                }
                toneFrames += 1
                emittedTone = true
            }
            if timedOut {
                // Silence the toned channels for the remainder so expiry is unambiguous rather
                // than a tone that simply stops mid-cycle.
                EngineLog.emit(
                    "[AudioDSPDiag] action=tone-timeout "
                    + "afterSeconds=\(String(format: "%.1f", Double(toneFrames) / rate)) "
                    + "channels=\(AudioDSPDiagnostics.describe(mask: settings.toneChannelMask)) "
                    + "decision=auto-stopped-to-protect-playback",
                    category: .swPlayback
                )
            }
        }
        toneIsSounding = emittedTone && !timedOut

        // ── Solo / mute ─────────────────────────────────────────────────────────────────────
        // Solo first, then mute, so mute can subtract from a solo set.
        if settings.soloChannelMask != 0 || settings.muteChannelMask != 0 {
            for frame in 0..<frames {
                let base = frame * channels
                for channel in 0..<channels {
                    let bit: UInt8 = channel < 6 ? (1 << UInt8(channel)) : 0
                    let soloed = settings.soloChannelMask == 0 || (settings.soloChannelMask & bit) != 0
                    let muted = (settings.muteChannelMask & bit) != 0
                    if !soloed || muted {
                        buffer[base + channel] = 0
                    }
                }
            }
        }

        return "tone=\(toneIsSounding ? 1 : 0) "
            + "toneCh=\(AudioDSPDiagnostics.describe(mask: settings.toneChannelMask)) "
            + "toneHz=\(String(format: "%.0f", settings.toneFrequencyHz)) "
            + "toneDb=\(String(format: "%.1f", settings.toneLevelDb)) "
            + "replace=\(settings.toneReplacesProgram ? 1 : 0) "
            + "timedOut=\(timedOut ? 1 : 0) "
            + "solo=\(AudioDSPDiagnostics.describe(mask: settings.soloChannelMask)) "
            + "mute=\(AudioDSPDiagnostics.describe(mask: settings.muteChannelMask))"
    }
}
