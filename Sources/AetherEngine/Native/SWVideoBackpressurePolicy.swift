import Foundation

/// Decides what the VOD demux loop does with a video packet when the video renderer is full.
///
/// MEASURED DEFECT (Apple TV, Jericho S01E01, Direct Play H.264 + AAC stereo, live DSP on):
/// audio played for roughly half a second, went silent for roughly half a second, and repeated.
///
/// `runDemuxLoop` is a SINGLE thread serving both streams. Its video branch parked on
/// `renderer.isReadyForMoreMediaData` in a 5 ms sleep loop. While parked it read no further packets
/// at all, so no AAC packet could reach the audio decoder:
///
///   video renderer fills (normal pacing, not a decode deficit)
///     -> demux thread parks on the video gate
///       -> no packets read -> no audio decoded -> the audio renderer drains to empty -> SILENCE
///         -> a frame is finally presented, the gate opens
///           -> the loop reads again, ~0.5 s of audio is decoded and enqueued -> SOUND
///             -> the next video packet hits the full gate again -> repeat
///
/// The video renderer's pacing gate was therefore also gating audio, which is the bug: a full video
/// queue is the NORMAL steady state, so audio was being starved on every cycle.
///
/// The fix is to stop treating the video gate as a reason to stop reading. When the video renderer
/// is full but the AUDIO renderer can still accept data, the loop stashes the video packet and keeps
/// reading, so audio continues to be decoded and enqueued. It only truly parks once audio is also
/// satisfied — at which point both sinks are full and parking costs nothing.
///
/// That gives a natural equilibrium instead of an unbounded read-ahead: audio runs as far ahead as
/// the audio renderer is willing to hold, and no further. The explicit caps below are a memory
/// backstop for a pathological stream (e.g. a long run of video packets with no audio interleaved).
enum SWVideoBackpressurePolicy {

    /// Maximum video packets held while the video renderer is full. At 1080p25 (~30 KB/frame) this
    /// is roughly 7 MB and about ten seconds of video, comfortably more than the audio renderer will
    /// ever buffer, so in practice the audio-readiness check ends the stashing first.
    static let maxStashedPackets = 240

    /// Byte backstop for the same stash, for streams whose packets are far larger than assumed.
    static let maxStashedBytes = 24 * 1024 * 1024

    enum Decision: Equatable {
        /// Renderer has room — decode this packet now.
        case decodeNow
        /// Video renderer is full but audio still needs data: hold the packet and keep reading.
        case stashAndKeepReading(reason: String)
        /// Both sinks are satisfied (or the stash is at its cap): parking is now safe.
        case park(reason: String)
    }

    enum BacklogReadDecision: Equatable {
        /// Audio still needs packets, so reading may continue while older video remains queued.
        case keepReadingForAudio
        /// Do not read a newer packet until at least one older held video packet is drained.
        case drainBacklogFirst(reason: String)
    }

    /// Decide whether the demuxer may read another packet while older video packets remain held.
    /// This decision MUST happen before `readPacket()`: parking after a newer video packet has
    /// already been read lets that newer packet bypass the FIFO when the renderer reopens.
    static func backlogReadDecision(
        videoRendererReady: Bool,
        audioRendererReady: Bool,
        stashedPackets: Int,
        stashedBytes: Int
    ) -> BacklogReadDecision {
        guard stashedPackets > 0 else { return .keepReadingForAudio }
        if videoRendererReady {
            return .drainBacklogFirst(reason: "video-renderer-ready")
        }
        if stashedPackets >= maxStashedPackets {
            return .drainBacklogFirst(reason: "stash-packet-cap")
        }
        if stashedBytes >= maxStashedBytes {
            return .drainBacklogFirst(reason: "stash-byte-cap")
        }
        return audioRendererReady
            ? .keepReadingForAudio
            : .drainBacklogFirst(reason: "both-renderers-satisfied")
    }

    /// - Parameters:
    ///   - videoRendererReady: `SampleBufferRenderer.isReadyForMoreMediaData`.
    ///   - audioRendererReady: `AudioOutput.isReadyForMoreMediaData`. Pass `false` when there is no
    ///                         audio output at all, so a video-only session parks exactly as before.
    ///   - hasAudioStream: whether this session has an audio stream to protect.
    ///   - stashedPackets: video packets currently held.
    ///   - stashedBytes: total bytes currently held.
    static func decide(
        videoRendererReady: Bool,
        audioRendererReady: Bool,
        hasAudioStream: Bool,
        stashedPackets: Int,
        stashedBytes: Int
    ) -> Decision {
        // Drain the stash before admitting anything new, so packet order is never disturbed.
        if videoRendererReady && stashedPackets == 0 { return .decodeNow }

        // No audio to protect: the old parking behaviour is exactly right, and stashing would only
        // add latency and memory for nothing.
        guard hasAudioStream else {
            return videoRendererReady ? .decodeNow : .park(reason: "no-audio-stream")
        }

        if stashedPackets >= maxStashedPackets {
            return .park(reason: "stash-packet-cap")
        }
        if stashedBytes >= maxStashedBytes {
            return .park(reason: "stash-byte-cap")
        }

        // The heart of the fix: audio still wants data, so reading must continue even though the
        // video renderer is full.
        if audioRendererReady {
            return .stashAndKeepReading(reason: "audio-renderer-hungry")
        }

        // Both sinks are full. Parking here cannot starve anything.
        return .park(reason: "both-renderers-satisfied")
    }
}
