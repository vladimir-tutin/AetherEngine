import Foundation
import CoreMedia
import Libavcodec

/// Independent VOD audio reader used for seamless embedded-track changes.
///
/// The video demux/decoder/render layer stays untouched. A fresh demuxer seeks the requested audio
/// stream to the running synchronizer clock, decodes PCM, then atomically transfers enqueue
/// ownership after the first on-time buffer is ready.
final class AudioTrackSwitchReader: @unchecked Sendable {
    struct Request: @unchecked Sendable {
        let url: URL
        let headers: [String: String]
        let streamIndex: Int32
        let startSeconds: Double
        let dspSettings: AudioDSPSettingsBox
        let output: AudioOutput
        let gate: AudioOwnershipGate
    }

    private let queue = DispatchQueue(label: "engine.sw.audio-switch", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func start(
        _ request: Request,
        completion: @escaping @Sendable (Bool, String) -> Void
    ) {
        lock.lock()
        generation &+= 1
        let myGeneration = generation
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let demuxer = Demuxer()
            defer { demuxer.close() }
            var activated = false

            do {
                try demuxer.open(url: request.url, extraHeaders: request.headers, profile: .playback)
                guard let stream = demuxer.stream(at: request.streamIndex),
                      stream.pointee.codecpar?.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
                    completion(false, "requested stream is not audio")
                    return
                }

                let decoder = AudioDecoder()
                try decoder.open(stream: stream)
                decoder.dspSettings = request.dspSettings.value
                demuxer.seek(to: request.startSeconds)

                var firstAcceptedPTS = Double.nan

                while self.isCurrent(myGeneration) {
                    guard let packet = try demuxer.readPacket() else {
                        if !activated {
                            completion(false, "EOF before activation")
                        }
                        return
                    }
                    defer {
                        av_packet_unref(packet)
                        av_packet_free_safe(packet)
                    }
                    guard packet.pointee.stream_index == request.streamIndex else { continue }

                    decoder.dspSettings = request.dspSettings.value
                    let buffers = decoder.decode(packet: packet)
                    for buffer in buffers {
                        guard self.isCurrent(myGeneration) else { return }
                        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        // Opening/probing the side demuxer takes real wall time while video keeps
                        // advancing. Chase the LIVE synchronizer clock, not the stale clock captured
                        // when the user pressed the track, so the first buffer handed over is never
                        // already in the renderer's past.
                        let liveTarget = max(request.startSeconds, request.output.currentTimeSeconds)
                        guard pts.isFinite, pts >= liveTarget - 0.050 else { continue }

                        if !activated {
                            firstAcceptedPTS = pts
                            request.gate.activateSide(
                                generation: myGeneration,
                                output: request.output,
                                firstBuffer: buffer
                            )
                            activated = true
                            completion(
                                true,
                                "activated at \(String(format: "%.3f", pts))s"
                            )
                            EngineLog.emit(
                                "[AudioTrackSwitch] owner=side stream=\(request.streamIndex) "
                                + "target=\(String(format: "%.3f", request.startSeconds))s "
                                + "firstPTS=\(String(format: "%.3f", pts))s videoPreserved=1 clockPreserved=1",
                                category: .swPlayback
                            )
                        } else {
                            while self.isCurrent(myGeneration),
                                  pts - request.output.currentTimeSeconds > 2.0 {
                                Thread.sleep(forTimeInterval: 0.005)
                            }
                            guard self.isCurrent(myGeneration) else { return }
                            request.gate.enqueueSide(
                                generation: myGeneration,
                                output: request.output,
                                buffer: buffer
                            )
                        }
                    }
                }

                if activated {
                    EngineLog.emit(
                        "[AudioTrackSwitch] reader superseded stream=\(request.streamIndex) "
                        + "firstPTS=\(String(format: "%.3f", firstAcceptedPTS))s",
                        category: .swPlayback
                    )
                }
            } catch {
                if !activated {
                    completion(false, "reader failed: \(error.localizedDescription)")
                } else {
                    EngineLog.emit(
                        "[AudioTrackSwitch] active reader failed stream=\(request.streamIndex) "
                        + "error=\(error.localizedDescription)",
                        category: .swPlayback
                    )
                }
            }
        }
    }

    private func isCurrent(_ value: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == value
    }
}

final class AudioDSPSettingsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = AudioDSPSettings.identity

    var value: AudioDSPSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/// Serializes the old main-demux audio enqueue with the side-reader handoff, so no old-track buffer
/// can race in after the new renderer queue has been flushed.
final class AudioOwnershipGate: @unchecked Sendable {
    private let lock = NSLock()
    private var sideGeneration: UInt64?

    /// Audible-audio frontier: PTS of the last buffer enqueued to the renderer by WHICHEVER
    /// feeder currently owns audio. Once a side reader owns the renderer, the demux loop's own
    /// last-enqueued counter freezes at the switch point (main packets are dropped above), and
    /// every clock governor reading it — rebuffer pause, starvation hold, read-gate pacing —
    /// then acts on a frozen lead. Field capture 2026-09-01 15:35: clock 144.2 s, frozen
    /// counter 126.2 s, clock paused/released ~25x a second, video at 0.45x, audio silent.
    private var frontierPtsSeconds = Double.nan

    /// One lock so an ownership flip and its frontier publish atomically.
    var audioFrontier: (pts: Double, sideOwned: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (frontierPtsSeconds, sideGeneration != nil)
    }

    /// Seek/load boundary: a pre-seek PTS must not leak into the post-seek lead.
    func resetFrontier() {
        lock.lock()
        frontierPtsSeconds = .nan
        lock.unlock()
    }

    /// Packets fed since the session began, and whether any of them ever produced a buffer. Used
    /// only for the first-buffer / starvation telemetry below; the decode path itself is unchanged.
    private var mainPacketsDecoded = 0
    private var mainBuffersProduced = 0
    private var loggedFirstBuffer = false
    private var loggedStarvation = false

    /// Reset the per-session audio-production counters. Called on load/seek so the telemetry
    /// describes THIS title rather than the process lifetime.
    func beginSession() {
        lock.lock()
        mainPacketsDecoded = 0
        mainBuffersProduced = 0
        loggedFirstBuffer = false
        loggedStarvation = false
        frontierPtsSeconds = .nan
        lock.unlock()
    }

    func decodeAndEnqueueMain(
        decoder: AudioDecoder,
        packet: UnsafeMutablePointer<AVPacket>,
        output: AudioOutput,
        tap: (@Sendable (CMSampleBuffer) -> Void)?
    ) -> [CMSampleBuffer] {
        lock.lock()
        defer { lock.unlock() }
        guard sideGeneration == nil else { return [] }
        let buffers = decoder.decode(packet: packet)
        mainPacketsDecoded += 1
        mainBuffersProduced += buffers.count

        // FLUSH OWNERSHIP: the decoder is the only component that knows whether an EMITTED buffer
        // actually changed channel count, and it latches exactly that (`consumeDSPFormatDidChange`).
        // The flush must happen BETWEEN decode and enqueue: flushing after the enqueue would discard
        // the very first buffer of the new format. Previously this latch was never read by anyone and
        // the host flushed speculatively on an OutputMode enum compare instead, which fires even when
        // the resulting width is identical (e.g. a stereo source where every mode yields 2ch).
        if decoder.consumeDSPFormatDidChange() {
            output.flush()
            EngineLog.emit(
                "[AudioDSP] action=flush owner=decoder-emitted-format-change "
                + "trigger=channel-count-changed decision=drop-stale-format-queue "
                + "buffersThisPacket=\(buffers.count)",
                category: .swPlayback
            )
        }

        if !buffers.isEmpty, !loggedFirstBuffer {
            loggedFirstBuffer = true
            EngineLog.emit(
                "[AudioProduction] action=first-buffer packetsToFirstBuffer=\(mainPacketsDecoded) "
                + "buffers=\(buffers.count) decision=clock-can-arm",
                category: .swPlayback
            )
        }
        // Starvation tell: the decoder is being fed but has never produced a buffer. This is the
        // exact state that used to wedge the demux loop silently, so it is release-visible once.
        if buffers.isEmpty, mainBuffersProduced == 0, mainPacketsDecoded >= 10, !loggedStarvation {
            loggedStarvation = true
            EngineLog.emit(
                "[AudioProduction] action=no-buffers-yet packetsDecoded=\(mainPacketsDecoded) "
                + "decision=clock-cannot-arm-from-audio "
                + "note=video-backpressure-guard-will-arm-from-video",
                category: .swPlayback
            )
        }

        for buffer in buffers {
            tap?(buffer)
            output.enqueue(sampleBuffer: buffer)
        }
        if let last = buffers.last {
            let pts = CMSampleBufferGetPresentationTimeStamp(last)
            if pts.isValid { frontierPtsSeconds = pts.seconds }
        }
        return buffers
    }

    func activateSide(
        generation: UInt64,
        output: AudioOutput,
        firstBuffer: CMSampleBuffer
    ) {
        lock.lock()
        defer { lock.unlock() }
        sideGeneration = generation
        output.flush()
        output.enqueue(sampleBuffer: firstBuffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(firstBuffer)
        if pts.isValid { frontierPtsSeconds = pts.seconds }
    }

    func enqueueSide(
        generation: UInt64,
        output: AudioOutput,
        buffer: CMSampleBuffer
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard sideGeneration == generation else { return }
        output.enqueue(sampleBuffer: buffer)
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        if pts.isValid { frontierPtsSeconds = pts.seconds }
    }

    func resetToMain() {
        lock.lock()
        sideGeneration = nil
        lock.unlock()
    }
}
