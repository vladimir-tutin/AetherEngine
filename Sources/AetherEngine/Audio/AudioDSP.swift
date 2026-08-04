import Foundation
import CoreMedia
import CoreAudio

/// FlexUI live audio DSP, applied to decoded interleaved Float32 PCM immediately before it is handed
/// to `AudioOutput` (`AVSampleBufferAudioRenderer`).
///
/// WHY HERE: `AudioDecoder` already produces exactly what DSP needs — multichannel **interleaved
/// packed Float32** at source rate with a real `AudioChannelLayout` (`audioChannelLayoutTag(for:)`,
/// i.e. `kAudioChannelLayoutTag_MPEG_5_1_A` = L R C LFE Ls Rs for 6ch and `AAC_7_1` = L R C LFE Ls Rs
/// Lsr Rsr for 8ch). Front centre is therefore interleaved index 2 in both, which is what makes a
/// centre-channel dialogue lift well defined. Doing the work at the single point where the buffer is
/// built also means the software host's demux loop, its live path, and `drain()` all inherit it
/// without a per-call-site change.
///
/// WHY IT IS LIVE: the settings are read once per emitted buffer (~21 ms at 1024 samples), so a
/// change reaches the renderer within one buffer plus whatever the renderer has already queued. No
/// media URL, player item, session, or clock is touched, so gain and centre changes do not restart
/// anything. A channel-count change DOES change the format description, so the host flushes the
/// audio renderer for that one case (audio only — the video renderer and the master clock are
/// untouched).
/// Every tunable of the stereo -> 5.1 matrix upmixer.
///
/// WHY EVERY VALUE IS A SETTING: an upmix is a taste judgement, not a correct answer. Hard-coding
/// the coefficients would mean a second billed native build the first time a value sounds wrong on
/// Patrick's actual receiver. Each field below is persisted on the FlexUI side and pushed live over
/// the same per-buffer settings read as Dialogue/Volume Boost, so all of it is tunable AFTER the
/// build is installed.
public struct AudioDSPUpmixSettings: Sendable, Equatable {

    /// Master switch for genuine stereo widening. OFF keeps the pinned-revision behaviour exactly:
    /// a 2-channel source stays 2 channels even when 5.1 is requested (the truthful "Source Stereo"
    /// fallback), so this whole feature has an in-build escape hatch.
    public var enabled: Bool

    /// How much of the correlated mid component is REMOVED from L/R once it has been sent to the
    /// centre channel. 0 = leave L/R alone (centre is purely additive, widest but phasier);
    /// 1 = fully subtract (hardest centre lock, narrowest front image). Clamped 0...1.
    public var centerExtraction: Float
    /// Level trim for the derived centre channel, dB.
    public var centerLevelDb: Float

    /// Level trim for the derived surround channels, dB. The surrounds carry the DEcorrelated side
    /// component; -inf-ish values effectively make this a 3.1 upmix.
    public var surroundLevelDb: Float
    /// Decorrelation delay applied to the surround pair, milliseconds. A few ms of delay is what
    /// stops the surrounds from collapsing back into the front image (precedence effect).
    /// Clamped to `AudioDSPUpmixSettings.maxSurroundDelayMs`.
    public var surroundDelayMs: Float

    /// Whether to synthesise an LFE channel at all. Many receivers prefer to derive their own bass
    /// via bass management, so this defaults OFF and stays user-controllable.
    public var lfeEnabled: Bool
    /// Level trim for the synthesised LFE, dB.
    public var lfeLevelDb: Float
    /// Low-pass corner for the synthesised LFE, Hz.
    public var lfeCutoffHz: Float

    /// Upper bound on the surround delay line, which sizes the allocation. 30 ms is already far past
    /// anything musical; beyond it the surrounds read as a slap echo rather than as space.
    public static let maxSurroundDelayMs: Float = 30

    public init(
        enabled: Bool = false,
        centerExtraction: Float = 0.5,
        centerLevelDb: Float = 0,
        surroundLevelDb: Float = -3,
        surroundDelayMs: Float = 12,
        lfeEnabled: Bool = false,
        lfeLevelDb: Float = 0,
        lfeCutoffHz: Float = 120
    ) {
        self.enabled = enabled
        self.centerExtraction = centerExtraction
        self.centerLevelDb = centerLevelDb
        self.surroundLevelDb = surroundLevelDb
        self.surroundDelayMs = surroundDelayMs
        self.lfeEnabled = lfeEnabled
        self.lfeLevelDb = lfeLevelDb
        self.lfeCutoffHz = lfeCutoffHz
    }

    /// Documented safe starting point. `reset` in the UI writes exactly this.
    public static let defaults = AudioDSPUpmixSettings(enabled: true)

    /// The pinned-revision behaviour: no widening at all.
    public static let off = AudioDSPUpmixSettings(enabled: false)

    /// Values actually used by the matrix, with every user-facing field clamped to a sane range.
    /// Clamping lives here (not at the UI) so a bad Metro push cannot produce NaNs or a delay line
    /// overrun in the render path.
    public var sanitized: AudioDSPUpmixSettings {
        var copy = self
        copy.centerExtraction = min(max(centerExtraction.isFinite ? centerExtraction : 0, 0), 1)
        copy.centerLevelDb = min(max(centerLevelDb.isFinite ? centerLevelDb : 0, -24), 12)
        copy.surroundLevelDb = min(max(surroundLevelDb.isFinite ? surroundLevelDb : 0, -24), 12)
        copy.surroundDelayMs = min(
            max(surroundDelayMs.isFinite ? surroundDelayMs : 0, 0), Self.maxSurroundDelayMs)
        copy.lfeLevelDb = min(max(lfeLevelDb.isFinite ? lfeLevelDb : 0, -24), 12)
        copy.lfeCutoffHz = min(max(lfeCutoffHz.isFinite ? lfeCutoffHz : 120, 40), 250)
        return copy
    }
}

/// What the engine will ACTUALLY do for a given source width and request. Pure, so both the
/// telemetry and the UI label can be derived from one rule instead of two that can disagree — this
/// is what keeps the panel from ever calling a stereo output "5.1".
public struct AudioDSPLayoutDecision: Sendable, Equatable {
    public var sourceChannels: Int32
    public var requestedChannels: Int32
    public var effectiveChannels: Int32
    /// Machine-readable reason, used verbatim in the log line and mapped to a UI label.
    public var reason: String
    /// True only when the stereo -> 5.1 matrix is genuinely running.
    public var upmixActive: Bool
}

public struct AudioDSPSettings: Sendable, Equatable {

    /// Requested output channel configuration.
    public enum OutputMode: String, Sendable, Equatable, CaseIterable {
        /// Source channel count, untouched.
        case source
        /// Fold anything wider than 5.1 down to 5.1. A 2-channel source is UPMIXED to 5.1 when
        /// `upmix.enabled`; otherwise it stays stereo (the truthful fallback).
        case surround51
        /// Downmix to two channels.
        case stereo
    }

    public var outputMode: OutputMode
    /// Front-centre emphasis in dB. Applied BEFORE any downmix so it survives a stereo fold.
    public var dialogueGainDb: Float
    /// Overall gain in dB, applied after mixing.
    public var masterGainDb: Float
    /// Peak ceiling for the limiter, linear. Only engaged when something can actually raise level.
    public var limiterCeiling: Float
    /// Stereo -> 5.1 matrix tunables. Inert unless `outputMode == .surround51` on a 2-channel source.
    public var upmix: AudioDSPUpmixSettings

    public init(
        outputMode: OutputMode = .source,
        dialogueGainDb: Float = 0,
        masterGainDb: Float = 0,
        limiterCeiling: Float = 0.95,
        upmix: AudioDSPUpmixSettings = .off
    ) {
        self.outputMode = outputMode
        self.dialogueGainDb = dialogueGainDb
        self.masterGainDb = masterGainDb
        self.limiterCeiling = limiterCeiling
        self.upmix = upmix
    }

    /// Neutral settings — the decoder passes the source buffer through with zero copies.
    public static let identity = AudioDSPSettings()

    /// True when processing cannot change a single sample. The decoder MUST short-circuit on this so
    /// "processing off" is bit-identical to stock, not "processed with unity gain".
    /// Upmix tunables are deliberately NOT part of this: `.source` mode never upmixes, so carrying
    /// upmix values around must not defeat the bypass.
    public var isIdentity: Bool {
        outputMode == .source && dialogueGainDb == 0 && masterGainDb == 0
    }

    /// Whether the stereo -> 5.1 matrix runs for this source width.
    public func upmixApplies(toSource sourceChannels: Int32) -> Bool {
        outputMode == .surround51 && sourceChannels == 2 && upmix.enabled
    }

    /// Output channel count for a given source channel count.
    public func outputChannels(forSource sourceChannels: Int32) -> Int32 {
        switch outputMode {
        case .source:
            return sourceChannels
        case .surround51:
            if upmixApplies(toSource: sourceChannels) { return 6 }
            return sourceChannels > 6 ? 6 : sourceChannels
        case .stereo:
            return sourceChannels > 2 ? 2 : sourceChannels
        }
    }

    /// One rule, used by both the log line and the UI label.
    public func layoutDecision(forSource sourceChannels: Int32) -> AudioDSPLayoutDecision {
        let effective = outputChannels(forSource: sourceChannels)
        let requested: Int32 = outputMode == .surround51 ? 6 : effective
        let reason: String
        var upmixActive = false
        switch outputMode {
        case .source:
            reason = "source-passthrough"
        case .stereo:
            reason = sourceChannels > 2 ? "downmix-to-stereo" : "already-stereo"
        case .surround51:
            if upmixApplies(toSource: sourceChannels) {
                reason = "stereo-upmix-matrix"
                upmixActive = true
            } else if sourceChannels == 2 {
                // The honest fallback: 5.1 asked for, stereo delivered, and we say so.
                reason = "upmix-disabled-source-stereo"
            } else if sourceChannels > 6 {
                reason = "fold-to-5.1"
            } else if sourceChannels == 6 {
                reason = "already-5.1"
            } else {
                // 1/3/4/5ch: no defined matrix, so nothing is invented.
                reason = "unsupported-source-width-passthrough"
            }
        }
        return AudioDSPLayoutDecision(
            sourceChannels: sourceChannels,
            requestedChannels: requested,
            effectiveChannels: effective,
            reason: reason,
            upmixActive: upmixActive
        )
    }
}

/// Stateful DSP processor. One instance per `AudioDecoder`; touched only from the decode thread,
/// which is already serialized by `AudioDecoder.stateLock`.
final class AudioDSPProcessor {

    /// Smoothed limiter gain, carried ACROSS buffers. A per-buffer peak normalisation would pump
    /// audibly at ~47 buffers/sec; a one-pole envelope with a fast attack and slow release does not.
    private var limiterGain: Float = 1.0

    /// Attack/release coefficients are derived per call from the real sample rate.
    private static let attackSeconds: Float = 0.005
    private static let releaseSeconds: Float = 0.120

    /// Surround decorrelation delay line (mono: it carries the side component only). Sized on first
    /// use from the real sample rate. Carried ACROSS buffers — a per-buffer delay would restart the
    /// decorrelation 47 times a second and click.
    private var surroundDelayLine: [Float] = []
    private var surroundDelayWrite: Int = 0
    private var surroundDelayRate: Int32 = 0

    /// One-pole low-pass state for the synthesised LFE, also carried across buffers.
    private var lfeLowpassState: Float = 0

    /// Reset envelope state. Called on flush/seek so a limiter that was ducking a loud passage does
    /// not carry that reduction into the post-seek audio. The upmix delay line and LFE filter are
    /// reset for the same reason: pre-seek audio must not bleed across the discontinuity.
    func reset() {
        limiterGain = 1.0
        for index in surroundDelayLine.indices { surroundDelayLine[index] = 0 }
        surroundDelayWrite = 0
        lfeLowpassState = 0
    }

    /// Process one interleaved Float32 buffer.
    ///
    /// - Parameters:
    ///   - input: interleaved source samples, `frames * sourceChannels` values.
    ///   - output: interleaved destination, `frames * outputChannels` values. May alias `input` only
    ///             when `sourceChannels == outputChannels`.
    ///   - frames: sample frames (not values).
    /// - Returns: the number of output channels actually written.
    @discardableResult
    func process(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frames: Int,
        sourceChannels: Int32,
        settings: AudioDSPSettings,
        sampleRate: Int32
    ) -> Int32 {
        let inCh = Int(sourceChannels)
        let outCh = Int(settings.outputChannels(forSource: sourceChannels))
        guard frames > 0, inCh > 0, outCh > 0 else { return Int32(outCh) }

        // Explicit Float throughout: a bare `1.0` in a ternary infers Double and then every
        // Float-times-gain multiply below fails to type-check.
        let dialogueGain: Float = settings.dialogueGainDb == 0
            ? 1.0
            : powf(10.0, settings.dialogueGainDb / 20.0)
        let masterGain: Float = settings.masterGainDb == 0
            ? 1.0
            : powf(10.0, settings.masterGainDb / 20.0)

        // ── 1/2. Centre emphasis + channel mixing, in one pass ──────────────────────────────
        // Centre is interleaved index 2 for the 5.1/7.1 layouts this decoder declares. Stereo has
        // a PHANTOM centre: boost its mid component while preserving the side component, so Dialogue
        // Boost remains a real control for ordinary AAC stereo instead of being silently inert.
        let centreIndex = inCh >= 6 ? 2 : -1

        if settings.upmixApplies(toSource: sourceChannels), outCh == 6, inCh == 2 {
            upmixStereoTo51(
                input: input,
                output: output,
                frames: frames,
                dialogueGain: dialogueGain,
                settings: settings.upmix.sanitized,
                sampleRate: sampleRate
            )
        } else if outCh == inCh {
            if inCh == 2, dialogueGain != 1.0 {
                for frame in 0..<frames {
                    let base = frame * 2
                    let mid = (input[base] + input[base + 1]) * 0.5 * dialogueGain
                    let side = (input[base] - input[base + 1]) * 0.5
                    output[base] = mid + side
                    output[base + 1] = mid - side
                }
            } else {
                // Same width: in-place scale. Only a discrete centre needs separate treatment.
                for frame in 0..<frames {
                    let base = frame * inCh
                    for channel in 0..<inCh {
                        let value = input[base + channel]
                        output[base + channel] = (channel == centreIndex) ? value * dialogueGain : value
                    }
                }
            }
        } else if outCh == 2 {
            downmixToStereo(
                input: input,
                output: output,
                frames: frames,
                sourceChannels: inCh,
                dialogueGain: dialogueGain
            )
        } else {
            // Wider-than-5.1 fold to 5.1: sum the rear pair into the surround pair.
            foldTo51(
                input: input,
                output: output,
                frames: frames,
                sourceChannels: inCh,
                dialogueGain: dialogueGain
            )
        }

        // ── 3. Master gain ──────────────────────────────────────────────────────────────────
        let total = frames * outCh
        if masterGain != 1.0 {
            for index in 0..<total {
                output[index] *= masterGain
            }
        }

        // ── 4. Limiter ──────────────────────────────────────────────────────────────────────
        // Engaged whenever something could push past the ceiling. With no positive gain there is
        // nothing to catch, so the envelope is left alone and the samples are untouched.
        // The upmix redistributes energy and applies its own level trims, so it is always a
        // candidate for overshoot even though it never narrows the width.
        let canOvershoot = masterGain > 1.0 || dialogueGain > 1.0 || outCh < inCh
            || settings.upmixApplies(toSource: sourceChannels)
        if canOvershoot {
            applyLimiter(
                output: output,
                frames: frames,
                channels: outCh,
                ceiling: max(0.05, min(1.0, settings.limiterCeiling)),
                sampleRate: sampleRate
            )
        }

        return Int32(outCh)
    }

    // MARK: - Mixing

    /// Stereo -> 5.1 matrix upmix, writing `L R C LFE Ls Rs` to match `kAudioChannelLayoutTag_MPEG_5_1_A`
    /// (the tag `audioChannelLayoutTag(for: 6)` declares, so the interleaved order here is not a guess).
    ///
    /// The matrix is the classic mid/side decomposition:
    ///   mid  = (L+R)/2   — everything panned centre, which is where dialogue lives
    ///   side = (L-R)/2   — everything that differs between the channels, i.e. the ambience
    ///
    /// Centre takes the mid (so Dialogue Boost lands on a REAL discrete centre once upmixed), the
    /// fronts optionally give that mid back up, and the surrounds take the side out of phase and
    /// delayed so they read as space rather than as a second copy of the front image.
    ///
    /// Every coefficient is a live setting; nothing here is a fixed house sound.
    private func upmixStereoTo51(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frames: Int,
        dialogueGain: Float,
        settings: AudioDSPUpmixSettings,
        sampleRate: Int32
    ) {
        let centreGain = powf(10.0, settings.centerLevelDb / 20.0)
        let surroundGain = powf(10.0, settings.surroundLevelDb / 20.0)
        let lfeGain = settings.lfeEnabled ? powf(10.0, settings.lfeLevelDb / 20.0) : 0
        let extraction = settings.centerExtraction

        let rate = max(sampleRate, 8000)
        // (Re)size the delay line when the rate changes; capacity covers the maximum delay so a live
        // delay change is just a read-offset move, never a reallocation on the render thread.
        let capacity = max(1, Int((AudioDSPUpmixSettings.maxSurroundDelayMs / 1000.0) * Float(rate)) + 1)
        if surroundDelayRate != rate || surroundDelayLine.count != capacity {
            surroundDelayLine = [Float](repeating: 0, count: capacity)
            surroundDelayWrite = 0
            surroundDelayRate = rate
        }
        let delayFrames = min(
            capacity - 1,
            max(0, Int((settings.surroundDelayMs / 1000.0) * Float(rate)))
        )

        // One-pole low-pass coefficient for the synthesised LFE.
        let lfeCoefficient: Float = settings.lfeEnabled
            ? 1.0 - expf(-2.0 * Float.pi * settings.lfeCutoffHz / Float(rate))
            : 0

        for frame in 0..<frames {
            let inBase = frame * 2
            let outBase = frame * 6

            let left = input[inBase]
            let right = input[inBase + 1]
            let mid = (left + right) * 0.5
            let side = (left - right) * 0.5

            // Front pair: optionally surrender the correlated component to the discrete centre.
            output[outBase] = left - mid * extraction
            output[outBase + 1] = right - mid * extraction
            // Centre carries the mid; Dialogue Boost multiplies it here so the control keeps working
            // identically whether the output is stereo (phantom centre) or upmixed (real centre).
            output[outBase + 2] = mid * centreGain * dialogueGain

            // LFE from the mid, low-passed. Zero (not silence-by-accident) when disabled.
            if settings.lfeEnabled {
                lfeLowpassState += (mid - lfeLowpassState) * lfeCoefficient
                output[outBase + 3] = lfeLowpassState * lfeGain
            } else {
                output[outBase + 3] = 0
            }

            // Surrounds: delayed side component, opposite polarity across the pair for width.
            // WRITE BEFORE READ: reading first made `surroundDelayMs = 0` still delay by one frame,
            // which silenced the surrounds entirely for a single-frame buffer. Writing first means
            // delayFrames == 0 reads back the sample just stored, i.e. genuinely no delay.
            surroundDelayLine[surroundDelayWrite] = side
            let readIndex = (surroundDelayWrite + capacity - delayFrames) % capacity
            let delayedSide = surroundDelayLine[readIndex]
            surroundDelayWrite = (surroundDelayWrite + 1) % capacity

            output[outBase + 4] = delayedSide * surroundGain
            output[outBase + 5] = -delayedSide * surroundGain
        }
    }

    /// ATSC A/52 style fold, coefficient-normalised so a full-scale source cannot exceed full scale
    /// on its own. This mirrors what libswresample/`aresample` does with `normalize=true`, which is
    /// what FlexUI's server-side downmix already used — so switching between the server path and
    /// this one does not change perceived level.
    ///
    /// LFE is deliberately dropped: folding it into a stereo pair muddies dialogue and is what most
    /// receivers do anyway.
    private func downmixToStereo(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frames: Int,
        sourceChannels inCh: Int,
        dialogueGain: Float
    ) {
        let centreCoefficient: Float = 0.7071068
        let surroundCoefficient: Float = 0.7071068

        // Normalise by the worst-case sum so unity-gain material stays inside full scale.
        let hasCentre = inCh >= 6
        let hasSurround = inCh >= 6
        var worstCase: Float = 1.0
        if hasCentre { worstCase += centreCoefficient * max(Float(1.0), dialogueGain) }
        if hasSurround { worstCase += surroundCoefficient }
        let normalise: Float = worstCase > 1.0 ? 1.0 / worstCase : 1.0

        for frame in 0..<frames {
            let inBase = frame * inCh
            let outBase = frame * 2

            if inCh >= 6 {
                // L R C LFE Ls Rs [Lsr Rsr]
                let left = input[inBase]
                let right = input[inBase + 1]
                let centre = input[inBase + 2] * dialogueGain * centreCoefficient
                var leftSurround = input[inBase + 4] * surroundCoefficient
                var rightSurround = input[inBase + 5] * surroundCoefficient
                if inCh >= 8 {
                    leftSurround += input[inBase + 6] * surroundCoefficient
                    rightSurround += input[inBase + 7] * surroundCoefficient
                }
                output[outBase] = (left + centre + leftSurround) * normalise
                output[outBase + 1] = (right + centre + rightSurround) * normalise
            } else if inCh >= 2 {
                output[outBase] = input[inBase]
                output[outBase + 1] = input[inBase + 1]
            } else {
                let mono = input[inBase]
                output[outBase] = mono
                output[outBase + 1] = mono
            }
        }
    }

    /// 6.1/7.1 → 5.1: sum the rear pair into the side/surround pair at -3 dB.
    private func foldTo51(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frames: Int,
        sourceChannels inCh: Int,
        dialogueGain: Float
    ) {
        let rearCoefficient: Float = 0.7071068
        for frame in 0..<frames {
            let inBase = frame * inCh
            let outBase = frame * 6

            output[outBase] = input[inBase]
            output[outBase + 1] = input[inBase + 1]
            output[outBase + 2] = input[inBase + 2] * dialogueGain
            output[outBase + 3] = inCh > 3 ? input[inBase + 3] : 0
            var leftSurround = inCh > 4 ? input[inBase + 4] : 0
            var rightSurround = inCh > 5 ? input[inBase + 5] : 0
            if inCh >= 8 {
                leftSurround += input[inBase + 6] * rearCoefficient
                rightSurround += input[inBase + 7] * rearCoefficient
            } else if inCh == 7 {
                // 6.1: single rear centre feeds both surrounds.
                let rearCentre = input[inBase + 6] * rearCoefficient
                leftSurround += rearCentre
                rightSurround += rearCentre
            }
            output[outBase + 4] = leftSurround
            output[outBase + 5] = rightSurround
        }
    }

    // MARK: - Limiter

    /// Feed-forward peak limiter with a smoothed gain envelope carried across buffers.
    private func applyLimiter(
        output: UnsafeMutablePointer<Float>,
        frames: Int,
        channels: Int,
        ceiling: Float,
        sampleRate: Int32
    ) {
        let rate = Float(max(sampleRate, 8000))
        let attackCoefficient: Float = 1.0 - expf(-1.0 / (Self.attackSeconds * rate))
        let releaseCoefficient: Float = 1.0 - expf(-1.0 / (Self.releaseSeconds * rate))

        for frame in 0..<frames {
            let base = frame * channels

            // Frame peak across channels — limiting per channel would shift the image.
            var peak: Float = 0
            for channel in 0..<channels {
                let magnitude = abs(output[base + channel])
                if magnitude > peak { peak = magnitude }
            }

            let targetGain: Float = peak > ceiling ? ceiling / peak : 1.0
            // Fast attack when we must duck, slow release when we may recover.
            let coefficient = targetGain < limiterGain ? attackCoefficient : releaseCoefficient
            limiterGain += (targetGain - limiterGain) * coefficient

            if limiterGain < 1.0 {
                for channel in 0..<channels {
                    output[base + channel] *= limiterGain
                }
            }

            // Brickwall safety net. The envelope above is deliberately SMOOTHED, so a peak that
            // rises faster than the release can track will briefly outrun it — the synthesised LFE
            // is exactly that case, because its one-pole ramps up over thousands of samples and can
            // become the new peak long after the envelope settled. Measured overshoot without this
            // clamp was 1.0025, i.e. real digital clipping at the DAC. The clamp only ever touches
            // those rare samples; the limiter still does all the musical work.
            for channel in 0..<channels {
                let value = output[base + channel]
                if value > 1.0 { output[base + channel] = 1.0 }
                else if value < -1.0 { output[base + channel] = -1.0 }
            }
        }
    }
}
