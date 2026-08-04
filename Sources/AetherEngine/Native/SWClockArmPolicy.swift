import Foundation

/// Decides whether the software host's demux loop may arm the master clock from a VIDEO packet
/// while it is blocked on video renderer back-pressure.
///
/// WHY THIS EXISTS (the Jericho S01E01 wedge): `runDemuxLoop` is a single thread. It arms the
/// `AVSampleBufferRenderSynchronizer` on the first DECODED AUDIO buffer, and it parks on
/// `renderer.isReadyForMoreMediaData` before decoding each video packet. The renderer only drains
/// once the clock runs. So if the first audio buffer has not arrived by the time the video renderer
/// fills (observed: 10 frames), the loop parks forever:
///
///   renderer full -> loop parks -> no more packets read -> no audio packet reaches the decoder
///   -> no audio buffer -> clock never armed -> renderer never drains -> renderer stays full
///
/// The pre-existing escape hatch (`audioPacketsSeen >= 50 && !audioBuffersProduced`) counts packets
/// that only the SAME parked loop could read, so it is unreachable by construction once the park
/// begins. At 25 fps a 10-frame renderer queue is ~0.4 s of media, while 50 AAC packets at 1024
/// samples / 48 kHz is ~1.07 s — the park always wins the race, so the fallback never fires.
///
/// The fix is to treat the park itself as the signal. Sustained back-pressure with an unarmed clock
/// is *proof* that no audio-driven arming can still be coming, because the only thread that could
/// deliver it is the one that is parked. After `graceSeconds` of continuous back-pressure we arm
/// from the video packet, which is exactly what the old fallback intended to do.
///
/// The grace window keeps the normal case untouched: a healthy source arms off audio within the
/// first few packets, long before the video renderer can fill and long before the grace expires.
enum SWClockArmPolicy {

    /// How long continuous video back-pressure must persist, with the clock still unarmed, before
    /// the loop arms from video instead. Comfortably longer than any healthy audio-first arming
    /// (which happens within the first handful of packets, i.e. milliseconds) and short enough that
    /// a user never sees a frozen first frame.
    static let graceSeconds: Double = 0.75

    enum Decision: Equatable {
        /// Keep waiting for the renderer to drain; audio may still arm the clock.
        case keepWaiting
        /// Arm the clock from the current video packet — audio-driven arming can no longer arrive.
        case armFromVideo(reason: String)
    }

    /// - Parameters:
    ///   - clockArmed: whether the synchronizer has already been anchored this session.
    ///   - hasAudioDecoder: whether a real audio decoder exists (no decoder = arm immediately; that
    ///                      case is already handled by the caller and is included here so the rule
    ///                      is expressible in one place for tests).
    ///   - audioBuffersProduced: whether the audio decoder has ever produced a buffer.
    ///   - backpressureSeconds: how long the loop has been continuously parked on the video
    ///                          renderer during this park.
    static func decide(
        clockArmed: Bool,
        hasAudioDecoder: Bool,
        audioBuffersProduced: Bool,
        backpressureSeconds: Double
    ) -> Decision {
        // Already anchored: the renderer is draining (or will be); nothing to rescue.
        if clockArmed { return .keepWaiting }

        // No audio decoder at all — there is no audio arming path by definition.
        if !hasAudioDecoder {
            return .armFromVideo(reason: "no-audio-decoder")
        }

        // Audio HAS produced buffers but the clock is somehow still unarmed: arming is imminent on
        // the audio branch, so do not race it.
        if audioBuffersProduced { return .keepWaiting }

        guard backpressureSeconds >= graceSeconds else { return .keepWaiting }

        // Sustained back-pressure, unarmed clock, zero audio buffers ever: the parked loop is the
        // only producer of audio packets, so waiting longer cannot change the outcome.
        return .armFromVideo(reason: "backpressure-starved-audio")
    }
}
