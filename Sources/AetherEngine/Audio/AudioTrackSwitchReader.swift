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
                        var owned: UnsafeMutablePointer<AVPacket>? = packet
                        av_packet_free_safe(&owned)
                    }
                    guard packet.pointee.stream_index == request.streamIndex else { continue }

                    decoder.dspSettings = request.dspSettings.value
                    let buffers = decoder.decode(packet: packet)
                    for buffer in buffers {
                        guard self.isCurrent(myGeneration) else { return }
                        let pts = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                        guard pts.isFinite, pts >= request.startSeconds - 0.050 else { continue }

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
        for buffer in buffers {
            tap?(buffer)
            output.enqueue(sampleBuffer: buffer)
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
    }

    func resetToMain() {
        lock.lock()
        sideGeneration = nil
        lock.unlock()
    }
}
