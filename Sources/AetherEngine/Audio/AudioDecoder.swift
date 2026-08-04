import Foundation
import CoreMedia
import CoreAudio
import AudioToolbox
import Libavformat
import Libavcodec
import Libavutil
import Libswresample

/// FFmpeg software audio decoder: compressed AVPackets -> multichannel interleaved Float32 PCM in CMSampleBuffers
/// for AVSampleBufferAudioRenderer. Uses libswresample to interleaved Float32 at source rate/channels (up to 7.1)
/// with proper AudioChannelLayout. Non-Atmos tracks only; EAC3+JOC Atmos passes through AVPlayer.
final class AudioDecoder: @unchecked Sendable {

    private var codecContext: UnsafeMutablePointer<AVCodecContext>?

    /// Serializes decode (demux thread) against flush/close (main actor). Without it a MainActor
    /// avcodec_flush_buffers could race an in-flight avcodec_send_packet on the same context (UB).
    /// Mirrors SoftwareVideoDecoder's lock discipline.
    private let stateLock = NSLock()
    private var swrContext: OpaquePointer?
    private var audioFormatDescription: CMAudioFormatDescription?

    /// Source stream time base for PTS conversion.
    private var timeBase: AVRational = AVRational(num: 1, den: 90000)

    /// TrueHD/MLP/lossless emit ~40-sample frames (0.83ms @48kHz); feeding 1200+ tiny CMSampleBuffers/sec makes
    /// AVSampleBufferAudioRenderer accept them then silently drop multichannel output. Coalesce to >= this many
    /// samples before building a buffer (~47 buffers/sec at ~21ms each, which the renderer handles).
    private static let minSamplesPerBuffer = 1024

    private var pendingBytes = Data()
    private var pendingStartPTS: CMTime = .invalid
    private var pendingSampleCount: Int = 0

    /// Gapless presentation clock (issue #89): stamps each buffer from a running sample count so
    /// consecutive buffers abut to the sample, instead of from each buffer's container-quantized PTS
    /// (which clicks at every frame for non-integer-ms frame durations like 1536-sample AC-3 @ 44.1 kHz).
    private var clock = AudioClockAnchor()

    // MARK: - FlexUI live DSP

    /// Live DSP settings. Guarded because the decode thread reads the whole struct while the main
    /// actor may be writing one; a torn read would apply half of two different settings to a buffer.
    private var _dspSettings = AudioDSPSettings.identity
    private let dspLock = NSLock()
    private let dspProcessor = AudioDSPProcessor()
    /// Format description for the PROCESSED output, cached per output channel count. Only built when
    /// the mixed width differs from the source, so a pure gain change reuses the source description.
    private var dspFormatDescription: CMAudioFormatDescription?
    private var dspFormatChannels: Int32 = 0
    /// Latched when an emitted buffer changed channel count. The host reads and clears it so it can
    /// flush the audio renderer exactly once per format change (audio only; the clock is untouched).
    private var _dspFormatDidChange = false
    private var lastEmittedChannels: Int32 = 0
    /// Last logged (source, requested, effective) layout triple, so the decision line appears on
    /// change rather than 47 times a second.
    private var lastLoggedLayoutDecision: AudioDSPLayoutDecision?
    /// Width is not proof of audible surround. Measure the post-DSP samples that are actually
    /// copied into CoreMedia: immediately on an upmix decision, then at most every two seconds.
    private var lastDSPLevelLogAt = Date.distantPast

    /// On-device PCM diagnostics (test tone / solo / mute). Deliberately NOT part of
    /// `AudioDSPSettings`: this is a temporary troubleshooting state that must never be persisted
    /// and must not survive a session, whereas DSP settings are both.
    private var _audioDSPDiagnostics = AudioDSPDiagnostics.off
    private let diagnosticsProcessor = AudioDSPDiagnosticsProcessor()

    var audioDSPDiagnostics: AudioDSPDiagnostics {
        get {
            dspLock.lock()
            defer { dspLock.unlock() }
            return _audioDSPDiagnostics
        }
        set {
            dspLock.lock()
            let previous = _audioDSPDiagnostics
            _audioDSPDiagnostics = newValue
            dspLock.unlock()
            guard previous != newValue else { return }
            EngineLog.emit(
                "[AudioDSPDiag] action=apply tone=\(newValue.toneEnabled ? 1 : 0) "
                + "toneCh=\(AudioDSPDiagnostics.describe(mask: newValue.sanitized.toneChannelMask)) "
                + "toneHz=\(String(format: "%.0f", newValue.sanitized.toneFrequencyHz)) "
                + "toneDb=\(String(format: "%.1f", newValue.sanitized.toneLevelDb)) "
                + "replace=\(newValue.toneReplacesProgram ? 1 : 0) "
                + "timeoutS=\(String(format: "%.0f", newValue.sanitized.toneTimeoutSeconds)) "
                + "solo=\(AudioDSPDiagnostics.describe(mask: newValue.sanitized.soloChannelMask)) "
                + "mute=\(AudioDSPDiagnostics.describe(mask: newValue.sanitized.muteChannelMask)) "
                + "active=\(newValue.isActive ? 1 : 0)",
                category: .swPlayback
            )
        }
    }

    /// Clear every diagnostic and its generator state. Called on flush/seek and on session load so a
    /// tone can never outlive the thing it was diagnosing.
    func resetAudioDSPDiagnostics(reason: String) {
        dspLock.lock()
        let wasActive = _audioDSPDiagnostics.isActive
        _audioDSPDiagnostics = .off
        dspLock.unlock()
        diagnosticsProcessor.reset()
        if wasActive {
            EngineLog.emit(
                "[AudioDSPDiag] action=reset reason=\(reason) decision=diagnostics-never-outlive-session",
                category: .swPlayback
            )
        }
    }

    var dspSettings: AudioDSPSettings {
        get {
            dspLock.lock()
            defer { dspLock.unlock() }
            return _dspSettings
        }
        set {
            dspLock.lock()
            _dspSettings = newValue
            dspLock.unlock()
        }
    }

    /// True once per channel-count change since the previous read.
    func consumeDSPFormatDidChange() -> Bool {
        dspLock.lock()
        defer { dspLock.unlock() }
        let changed = _dspFormatDidChange
        _dspFormatDidChange = false
        return changed
    }

    #if DEBUG
    private var _loggedZeroConvert = false
    #endif

    private(set) var sampleRate: Int32 = 0
    private(set) var channels: Int32 = 0

    func open(stream: UnsafeMutablePointer<AVStream>) throws {
        guard let codecpar = stream.pointee.codecpar else {
            throw AudioDecoderError.noCodecParameters
        }

        timeBase = stream.pointee.time_base
        sampleRate = codecpar.pointee.sample_rate
        channels = codecpar.pointee.ch_layout.nb_channels
        if channels <= 0 || channels > 8 { channels = 2 }

        guard let codec = avcodec_find_decoder(codecpar.pointee.codec_id) else {
            throw AudioDecoderError.unsupportedCodec
        }

        guard let ctx = avcodec_alloc_context3(codec) else {
            throw AudioDecoderError.contextAllocationFailed
        }
        codecContext = ctx

        guard avcodec_parameters_to_context(ctx, codecpar) >= 0 else {
            throw AudioDecoderError.parameterCopyFailed
        }

        guard avcodec_open2(ctx, codec, nil) >= 0 else {
            throw AudioDecoderError.openFailed
        }

        // Resampler built lazily from the first frame, not here: TrueHD (and codecs advertising
        // AV_CHANNEL_ORDER_UNSPEC or sample_fmt=NONE in codecpar pre-frame) would fail swr_alloc_set_opts2 here,
        // bubbling up as open-failed -> audioAvailable=false -> no sound. The first frame carries resolved layout/rate/format.

        #if DEBUG
        EngineLog.emit("[AudioDecoder] Opened: \(sampleRate)Hz, \(channels)ch, codec=\(String(cString: codec.pointee.name))", category: .swPlayback)
        #endif
    }

    func decode(packet: UnsafeMutablePointer<AVPacket>) -> [CMSampleBuffer] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        var results: [CMSampleBuffer] = []

        let sendRet = avcodec_send_packet(ctx, packet)
        guard sendRet >= 0 else { return [] }

        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        guard let f = frame else { return [] }

        while avcodec_receive_frame(ctx, f) >= 0 {
            // Lazy resampler init off a real frame with resolved layout/format. On failure drops one frame at
            // most and recovers immediately.
            if swrContext == nil {
                if !initResamplerFromFrame(f) { continue }
            }
            appendFrameToPending(f)
            if pendingSampleCount >= Self.minSamplesPerBuffer {
                if let sampleBuffer = emitPending() {
                    results.append(sampleBuffer)
                }
            }
        }

        return results
    }

    private func initResamplerFromFrame(_ frame: UnsafeMutablePointer<AVFrame>) -> Bool {
        // Refresh rate/channels from the frame (codecpar was a hint, the frame is truth). Once per track.
        if frame.pointee.sample_rate > 0 { sampleRate = frame.pointee.sample_rate }
        let frameChannels = frame.pointee.ch_layout.nb_channels
        if frameChannels > 0 && frameChannels <= 8 { channels = frameChannels }

        var outLayout = AVChannelLayout()
        av_channel_layout_default(&outLayout, channels)

        // Input layout: frame's if valid, else a synthesised default. Key for TrueHD 7.1 (the frame has it right
        // after decoding even when codecpar didn't).
        var inLayout = AVChannelLayout()
        if frame.pointee.ch_layout.nb_channels > 0 {
            av_channel_layout_copy(&inLayout, &frame.pointee.ch_layout)
        } else {
            av_channel_layout_default(&inLayout, channels)
        }
        // copy() allocates a channel map for custom-order layouts; uninit the stack structs or that map leaks per init.
        defer {
            av_channel_layout_uninit(&inLayout)
            av_channel_layout_uninit(&outLayout)
        }

        let inFmt = AVSampleFormat(rawValue: frame.pointee.format)
        let inRate = frame.pointee.sample_rate > 0 ? frame.pointee.sample_rate : sampleRate

        let ret = swr_alloc_set_opts2(
            &swrContext,
            &outLayout,
            AV_SAMPLE_FMT_FLT,
            sampleRate,
            &inLayout,
            inFmt,
            inRate,
            0,
            nil
        )
        guard ret >= 0, swrContext != nil else { return false }
        guard swr_init(swrContext) >= 0 else {
            swr_free(&swrContext)
            return false
        }

        do {
            try createFormatDescription()
        } catch {
            swr_free(&swrContext)
            return false
        }

        #if DEBUG
        EngineLog.emit("[AudioDecoder] Resampler ready: \(sampleRate)Hz, \(channels)ch, inFmt=\(inFmt.rawValue)", category: .swPlayback)
        #endif
        return true
    }

    /// Flush the decoder (call at EOF or seek).
    func flush() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return }
        avcodec_flush_buffers(ctx)
        // Drop the coalesced samples; after a seek they'd be at the wrong PTS anyway.
        resetPending()
        // Re-anchor the gapless clock to the post-seek PTS on the next emitted buffer.
        clock.reset()
        // Drop the limiter envelope too: a reduction earned by a loud passage before the seek must
        // not duck the first buffers after it.
        dspProcessor.reset()
        #if DEBUG
        _loggedZeroConvert = false
        #endif
    }

    /// Drain at source EOF: send a NULL packet to flush the decoder's internal delay frames into the
    /// accumulator, then force-emit the residual (< minSamplesPerBuffer) tail that the gated decode()
    /// path never emits. Without this the final ~21ms+ of every audio-only title was dropped (flush()
    /// discards pending). Mirrors AudioBridge.flush(). Call once at demuxer EOF, before flush()/close().
    func drain() -> [CMSampleBuffer] {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let ctx = codecContext else { return [] }
        var results: [CMSampleBuffer] = []

        avcodec_send_packet(ctx, nil)
        var frame: UnsafeMutablePointer<AVFrame>? = av_frame_alloc()
        defer { av_frame_free(&frame) }
        if let f = frame {
            while avcodec_receive_frame(ctx, f) >= 0 {
                if swrContext == nil {
                    if !initResamplerFromFrame(f) { continue }
                }
                appendFrameToPending(f)
                if pendingSampleCount >= Self.minSamplesPerBuffer {
                    if let sampleBuffer = emitPending() { results.append(sampleBuffer) }
                }
            }
        }
        // Force-emit whatever is left below the coalescing threshold (emitPending only needs > 0 samples).
        if let sampleBuffer = emitPending() { results.append(sampleBuffer) }
        return results
    }

    func close() {
        stateLock.lock()
        defer { stateLock.unlock() }
        if codecContext != nil {
            avcodec_free_context(&codecContext)
        }
        if swrContext != nil {
            swr_free(&swrContext)
        }
        codecContext = nil
        swrContext = nil
        audioFormatDescription = nil
    }

    deinit {
        close()
    }

    // MARK: - Format Description

    private func createFormatDescription() throws {
        guard let desc = Self.makeFormatDescription(sampleRate: sampleRate, channels: channels) else {
            throw AudioDecoderError.formatDescriptionFailed
        }
        audioFormatDescription = desc
    }

    /// Build an interleaved packed Float32 CMAudioFormatDescription for a channel count. Factored out
    /// of `createFormatDescription()` so the DSP path can describe a MIXED width (e.g. a 5.1 source
    /// folded to stereo) with the identical ASBD/layout rules the source description uses.
    static func makeFormatDescription(
        sampleRate: Int32,
        channels: Int32
    ) -> CMAudioFormatDescription? {
        guard sampleRate > 0, channels > 0 else { return nil }
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels) * 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels) * 4,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let layoutTag = audioChannelLayoutTag(for: channels)
        var layout = AudioChannelLayout(
            mChannelLayoutTag: layoutTag,
            mChannelBitmap: [],
            mNumberChannelDescriptions: 0,
            mChannelDescriptions: (AudioChannelDescription())
        )
        let layoutSize = MemoryLayout<AudioChannelLayout>.size

        var formatDesc: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: layoutSize,
            layout: &layout,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDesc
        )
        guard status == noErr, let desc = formatDesc else { return nil }
        return desc
    }

    // MARK: - Frame → pending buffer → CMSampleBuffer

    /// Resample one frame and append float-interleaved bytes to the pending accumulator. Captures the frame's PTS
    /// on the first append so emitPending() stamps the coalesced buffer correctly.
    private func appendFrameToPending(_ frame: UnsafeMutablePointer<AVFrame>) {
        guard let swr = swrContext else { return }

        let numSamples = Int(frame.pointee.nb_samples)
        guard numSamples > 0 else { return }

        let maxOutputSamples = Int(swr_get_out_samples(swr, frame.pointee.nb_samples))
        guard maxOutputSamples > 0 else { return }

        let bytesPerSample = Int(channels) * 4
        let bufferSize = maxOutputSamples * bytesPerSample
        let tempBuffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { tempBuffer.deallocate() }

        var outPtr: UnsafeMutablePointer<UInt8>? = tempBuffer
        let convertedSamples = withUnsafeMutablePointer(to: &outPtr) { outBuf in
            let srcData = UnsafePointer<UnsafePointer<UInt8>?>(
                OpaquePointer(frame.pointee.extended_data)
            )
            return swr_convert(
                swr,
                outBuf,
                Int32(maxOutputSamples),
                srcData,
                frame.pointee.nb_samples
            )
        }
        #if DEBUG
        if convertedSamples <= 0 && !_loggedZeroConvert {
            _loggedZeroConvert = true
            EngineLog.emit("[AudioDecoder] swr_convert returned \(convertedSamples), pipeline silent from here", category: .swPlayback)
        }
        #endif
        guard convertedSamples > 0 else { return }

        // First frame in a new accumulator captures the PTS; subsequent frames only extend the buffer.
        if pendingSampleCount == 0 {
            let pts = frame.pointee.pts
            pendingStartPTS = (pts != Int64.min)
                ? CMTimeMake(value: pts * Int64(timeBase.num), timescale: Int32(timeBase.den))
                : .invalid
        }

        pendingBytes.append(tempBuffer, count: Int(convertedSamples) * bytesPerSample)
        pendingSampleCount += Int(convertedSamples)
    }

    /// Build a CMSampleBuffer from the pending accumulator and reset it. Nil if nothing pending.
    private func emitPending() -> CMSampleBuffer? {
        guard pendingSampleCount > 0,
              let sourceFormatDesc = audioFormatDescription,
              !pendingBytes.isEmpty
        else { return nil }

        let totalSamples = pendingSampleCount
        let startPTS = pendingStartPTS

        // ── FlexUI live DSP ─────────────────────────────────────────────────────────────────
        // Read one settings snapshot per buffer. Identity short-circuits entirely: "processing off"
        // must be the untouched source bytes, not a unity-gain pass, so it stays bit-identical to
        // stock playback and cannot regress Atmos/passthrough-adjacent material.
        let settings = dspSettings
        var emitBytes = pendingBytes
        var emitFormat = sourceFormatDesc
        var emitChannels = channels
        // Hoisted so the diagnostics/level logging below runs even when DSP is in its identity
        // short-circuit, because a test tone must work with processing off.
        var upmixActiveForLevels = false

        if !settings.isIdentity, channels > 0, totalSamples > 0 {
            let sourceChannels = Int(channels)
            let outChannelCount = settings.outputChannels(forSource: channels)
            let outCh = Int(outChannelCount)
            var processed = Data(count: totalSamples * outCh * 4)
            let didProcess: Bool = processed.withUnsafeMutableBytes { destRaw -> Bool in
                guard let dest = destRaw.baseAddress?.assumingMemoryBound(to: Float.self) else {
                    return false
                }
                return pendingBytes.withUnsafeBytes { srcRaw -> Bool in
                    guard let src = srcRaw.baseAddress?.assumingMemoryBound(to: Float.self) else {
                        return false
                    }
                    guard srcRaw.count >= totalSamples * sourceChannels * 4 else { return false }
                    dspProcessor.process(
                        input: src,
                        output: dest,
                        frames: totalSamples,
                        sourceChannels: channels,
                        settings: settings,
                        sampleRate: sampleRate
                    )
                    return true
                }
            }

            if didProcess {
                emitBytes = processed
                emitChannels = outChannelCount
                if outChannelCount == channels {
                    emitFormat = sourceFormatDesc
                } else if let cached = dspFormatDescription, dspFormatChannels == outChannelCount {
                    emitFormat = cached
                } else if let built = Self.makeFormatDescription(
                    sampleRate: sampleRate,
                    channels: outChannelCount
                ) {
                    dspFormatDescription = built
                    dspFormatChannels = outChannelCount
                    emitFormat = built
                } else {
                    // Could not describe the mixed width — emit the source instead of silence.
                    emitBytes = pendingBytes
                    emitChannels = channels
                    emitFormat = sourceFormatDesc
                }
            }
        }

        // Layout decision telemetry: one line whenever the (source, requested, effective) triple
        // changes. Derived from `layoutDecision`, the same pure rule the UI label uses, so the log
        // and the panel can never disagree about whether a stereo source really became 5.1.
        var layoutChanged = false
        if channels > 0 {
            let decision = settings.layoutDecision(forSource: channels)
            upmixActiveForLevels = decision.upmixActive
            if decision != lastLoggedLayoutDecision {
                layoutChanged = true
                lastLoggedLayoutDecision = decision
                let upmix = settings.upmix.sanitized
                EngineLog.emit(
                    "[AudioDSP] layout sourceCh=\(decision.sourceChannels) "
                    + "requestedCh=\(decision.requestedChannels) "
                    + "effectiveCh=\(decision.effectiveChannels) "
                    + "mode=\(settings.outputMode.rawValue) "
                    + "upmixActive=\(decision.upmixActive ? 1 : 0) "
                    + "upmixEnabled=\(settings.upmix.enabled ? 1 : 0) "
                    + "matrix=\(decision.upmixActive ? "crossmix-rear-fill-5.1" : "none") "
                    + "centerExtraction=\(String(format: "%.2f", upmix.centerExtraction)) "
                    + "centerDb=\(String(format: "%.1f", upmix.centerLevelDb)) "
                    + "surroundDb=\(String(format: "%.1f", upmix.surroundLevelDb)) "
                    + "surroundDelayMs=\(String(format: "%.1f", upmix.surroundDelayMs)) "
                    + "rearFill=\(String(format: "%.2f", upmix.rearFill)) "
                    + "rearLowPassHz=\(String(format: "%.0f", upmix.rearLowPassHz)) "
                    + "lfe=\(upmix.lfeEnabled ? 1 : 0) "
                    + "lfeDb=\(String(format: "%.1f", upmix.lfeLevelDb)) "
                    + "lfeCutoffHz=\(String(format: "%.0f", upmix.lfeCutoffHz)) "
                    + "decision=\(decision.reason)",
                    category: .swPlayback
                )
            }

        }

        // ── Diagnostics: test tone / solo / mute ────────────────────────────────────────────
        // Applied AFTER the DSP and the limiter, at exactly the point program audio reaches
        // CoreMedia, so "tone audible" and "program audible" exercise an identical path. Anything
        // that swallows one swallows the other, which is what makes this decisive about routing.
        // Runs outside the `isIdentity` short-circuit above: a tone must work even with DSP off.
        let diagnostics = audioDSPDiagnostics
        var diagnosticsSummary: String?
        if diagnostics.isActive, totalSamples > 0, emitChannels > 0 {
            var mutable = emitBytes
            mutable.withUnsafeMutableBytes { raw in
                guard let samples = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
                diagnosticsSummary = diagnosticsProcessor.apply(
                    buffer: samples,
                    frames: totalSamples,
                    channels: Int(emitChannels),
                    settings: diagnostics,
                    sampleRate: sampleRate
                )
            }
            emitBytes = mutable
        }

        // Level telemetry measures what ACTUALLY leaves, including any injected tone. Logged
        // whenever the upmix is running OR diagnostics are active, so a tone can be verified even
        // with DSP otherwise off.
        if emitChannels == 6, upmixActiveForLevels || diagnostics.isActive {
            let now = Date()
            if layoutChanged || now.timeIntervalSince(lastDSPLevelLogAt) >= 2.0 {
                lastDSPLevelLogAt = now
                emitDSPLevels(bytes: emitBytes, frames: totalSamples, channels: 6, settings: settings)
                if let diagnosticsSummary {
                    EngineLog.emit(
                        "[AudioDSPDiag] point=post-dsp-pre-render channels=\(emitChannels) "
                        + diagnosticsSummary,
                        category: .swPlayback
                    )
                }
            }
        }

        if lastEmittedChannels != 0, lastEmittedChannels != emitChannels {
            dspLock.lock()
            _dspFormatDidChange = true
            dspLock.unlock()
            EngineLog.emit(
                "[AudioDSP] emitted format change \(lastEmittedChannels)ch -> \(emitChannels)ch "
                + "mode=\(settings.outputMode.rawValue)",
                category: .swPlayback
            )
        }
        lastEmittedChannels = emitChannels

        let totalBytes = emitBytes.count
        let formatDesc = emitFormat

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: totalBytes,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: totalBytes,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let block = blockBuffer else {
            resetPending()
            return nil
        }

        status = emitBytes.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(
                with: base,
                blockBuffer: block,
                offsetIntoDestination: 0,
                dataLength: totalBytes
            )
        }
        guard status == kCMBlockBufferNoErr else {
            resetPending()
            return nil
        }

        // Gapless PTS (issue #89): derive this buffer's start from the running sample count so
        // consecutive buffers abut exactly, instead of from the container-quantized PTS (which leaves
        // +/-0.5 ms gaps and per-frame clicks for non-integer-ms frame durations). Committed only on
        // success below, so a dropped buffer never advances the clock.
        let (outPTS, reanchor) = clock.resolve(startPTS: startPTS, sampleRate: sampleRate)

        // Single timing entry: CoreMedia treats `duration` as per-SAMPLE, so LPCM must be 1/sampleRate. Stamping
        // the buffer total made GetDuration report totalSamples^2/sampleRate (~22s for 1024 samples), wedging
        // AudioPlaybackHost's buffer-ahead gate after one packet.
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: outPTS,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: CMItemCount(totalSamples),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        )
        resetPending()
        guard status == noErr, let sample = sampleBuffer else { return nil }
        clock.commit(pts: outPTS, reanchor: reanchor, sampleCount: totalSamples)
        return sample
    }

    /// Measure the post-limiter, post-upmix PCM immediately before the renderer receives it.
    /// MPEG_5_1_A interleaved order is L R C LFE Ls Rs.
    private func emitDSPLevels(
        bytes: Data,
        frames: Int,
        channels: Int,
        settings: AudioDSPSettings
    ) {
        guard frames > 0, channels == 6, bytes.count >= frames * channels * 4 else { return }
        var sums = [Double](repeating: 0, count: channels)
        var peaks = [Float](repeating: 0, count: channels)
        bytes.withUnsafeBytes { raw in
            guard let samples = raw.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            for frame in 0..<frames {
                let base = frame * channels
                for channel in 0..<channels {
                    let value = samples[base + channel]
                    sums[channel] += Double(value * value)
                    peaks[channel] = max(peaks[channel], abs(value))
                }
            }
        }
        let rms = sums.map { sqrt($0 / Double(frames)) }
        let rearNonZero = peaks[4] > 0.000_001 || peaks[5] > 0.000_001
        let upmix = settings.upmix.sanitized
        EngineLog.emit(
            "[AudioDSPLevels] schema=2 point=post-dsp-pre-render frames=\(frames) "
            + "rmsL=\(String(format: "%.6f", rms[0])) rmsR=\(String(format: "%.6f", rms[1])) "
            + "rmsC=\(String(format: "%.6f", rms[2])) rmsLFE=\(String(format: "%.6f", rms[3])) "
            + "rmsLs=\(String(format: "%.6f", rms[4])) rmsRs=\(String(format: "%.6f", rms[5])) "
            + "peakLs=\(String(format: "%.6f", peaks[4])) peakRs=\(String(format: "%.6f", peaks[5])) "
            + "rearNonZero=\(rearNonZero ? 1 : 0) rearFill=\(String(format: "%.2f", upmix.rearFill)) "
            + "rearLowPassHz=\(String(format: "%.0f", upmix.rearLowPassHz))",
            category: .swPlayback
        )
    }

    private func resetPending() {
        pendingBytes.removeAll(keepingCapacity: true)
        pendingSampleCount = 0
        pendingStartPTS = .invalid
    }
}

enum AudioDecoderError: Error, CustomStringConvertible, LocalizedError {
    case noCodecParameters
    case unsupportedCodec
    case contextAllocationFailed
    case parameterCopyFailed
    case openFailed
    case formatDescriptionFailed

    var description: String {
        switch self {
        case .noCodecParameters: "AudioDecoder: audio stream has no codec parameters"
        case .unsupportedCodec: "AudioDecoder: no decoder for the audio codec"
        case .contextAllocationFailed: "AudioDecoder: avcodec_alloc_context3 failed"
        case .parameterCopyFailed: "AudioDecoder: avcodec_parameters_to_context failed"
        case .openFailed: "AudioDecoder: decoder open failed"
        case .formatDescriptionFailed: "AudioDecoder: could not build the output format description"
        }
    }

    var errorDescription: String? { description }
}
