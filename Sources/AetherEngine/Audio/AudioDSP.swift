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
public struct AudioDSPSettings: Sendable, Equatable {

    /// Requested output channel configuration.
    public enum OutputMode: String, Sendable, Equatable, CaseIterable {
        /// Source channel count, untouched.
        case source
        /// Render 5.1: stereo/mono are matrix-upmixed, wider sources fold down, 5.1 passes through.
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

    public init(
        outputMode: OutputMode = .source,
        dialogueGainDb: Float = 0,
        masterGainDb: Float = 0,
        limiterCeiling: Float = 0.95
    ) {
        self.outputMode = outputMode
        self.dialogueGainDb = dialogueGainDb
        self.masterGainDb = masterGainDb
        self.limiterCeiling = limiterCeiling
    }

    /// Neutral settings — the decoder passes the source buffer through with zero copies.
    public static let identity = AudioDSPSettings()

    /// True when processing cannot change a single sample. The decoder MUST short-circuit on this so
    /// "processing off" is bit-identical to stock, not "processed with unity gain".
    public var isIdentity: Bool {
        outputMode == .source && dialogueGainDb == 0 && masterGainDb == 0
    }

    /// Output channel count for a given source channel count.
    public func outputChannels(forSource sourceChannels: Int32) -> Int32 {
        switch outputMode {
        case .source:
            return sourceChannels
        case .surround51:
            if sourceChannels <= 2 { return 6 }
            return sourceChannels > 6 ? 6 : sourceChannels
        case .stereo:
            return sourceChannels > 2 ? 2 : sourceChannels
        }
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

    /// Reset envelope state. Called on flush/seek so a limiter that was ducking a loud passage does
    /// not carry that reduction into the post-seek audio.
    func reset() {
        limiterGain = 1.0
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

        if outCh == inCh {
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
        } else if outCh == 6, inCh <= 2 {
            upmixTo51(
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
        let canOvershoot = masterGain > 1.0 || dialogueGain > 1.0 || outCh != inCh
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

    /// Deterministic stereo/mono -> 5.1 matrix. Front L/R retain the original mid/side image,
    /// dialogue is anchored in C, LFE remains silent (inventing bass is not safe), and the anti-phase
    /// side component feeds the surrounds. At unity dialogue gain the front pair is byte-equivalent
    /// to the input; the additional channels provide the requested spatial presentation.
    private func upmixTo51(
        input: UnsafePointer<Float>,
        output: UnsafeMutablePointer<Float>,
        frames: Int,
        sourceChannels inCh: Int,
        dialogueGain: Float
    ) {
        let centreCoefficient: Float = 0.7071068
        let surroundCoefficient: Float = 0.5
        for frame in 0..<frames {
            let inBase = frame * inCh
            let outBase = frame * 6
            let left = input[inBase]
            let right = inCh > 1 ? input[inBase + 1] : left
            let mid = (left + right) * 0.5
            let side = (left - right) * 0.5
            let boostedMid = mid * dialogueGain

            output[outBase] = boostedMid + side       // L
            output[outBase + 1] = boostedMid - side   // R
            output[outBase + 2] = boostedMid * centreCoefficient // C
            output[outBase + 3] = 0                   // LFE
            output[outBase + 4] = side * surroundCoefficient     // Ls
            output[outBase + 5] = -side * surroundCoefficient    // Rs
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
        }
    }
}
