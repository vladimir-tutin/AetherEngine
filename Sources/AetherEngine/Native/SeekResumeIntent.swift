import Foundation

/// Whether a seek on a demuxer-driven host (software video, audio-only) re-arms the clock at
/// `lastRate` or parks it at 0 (#292).
///
/// The hosts park their demux/feeder loops for the duration of a seek by clearing `isPlaying`, and
/// since #254 the reposition that follows is awaited off the main actor. A second seek issued inside
/// that window therefore reads a flag its predecessor cleared, not the transport's intent, and a
/// scrub during playback landed paused with the clock anchored at rate 0. So the seek that owns the
/// window stashes the intent it captured, and whoever supersedes it inherits that instead.
///
/// The stash is not a snapshot of the whole window: `pause()` and `play()` rewrite it, so an explicit
/// transport call while the reposition is in flight still decides the landing.
enum SeekResumeIntent {
    /// - Parameters:
    ///   - isPlaying: the host's loop flag, authoritative only outside a seek window.
    ///   - seekInFlight: whether another seek already owns the window (and cleared the flag).
    ///   - inFlightIntent: the intent stashed by the seek that owns the window.
    static func resolve(isPlaying: Bool, seekInFlight: Bool, inFlightIntent: Bool) -> Bool {
        seekInFlight ? inFlightIntent : isPlaying
    }
}

/// What a transport `play()` does while a reposition is in flight.
///
/// The seek parks the demux loop by clearing `isPlaying` and then awaits the demuxer reposition on
/// `seekQueue`. A `play()` that arrives inside that window (a host re-asserting its "playing" intent
/// the moment the seek is announced) used to flip `isPlaying` straight back on, which woke the loop
/// while the reposition was still QUEUED. The loop's `readPacket` and the reposition contend for the
/// same demuxer lock, and the loop won: it read pre-seek packets under the new generation, fed
/// pre-seek audio (lead jumped from 4 s to 14 s on a 10 s rewind) and pre-seek video (frames the
/// layer held as future frames, `isReadyForDisplay=false`), and the read gate then held everything
/// until the clock had walked back through the pre-seek position. Device trace 2026-09-03 16:24:15:
/// seek target 1027.26, `[SWDiag] aLead=14.42 parked=0 r4d=n` one second later, no picture change for
/// the length of the rewind; a second rewind 1.6 s later landed in 1 ms and played at once.
///
/// Inside the window `play()` therefore only records the intent (#292's stash) and lets the landing
/// resume the clock and the loop.
enum SeekWindowTransport {
    enum PlayAction: Equatable {
        /// No reposition pending: flip the loop flag and resume the clock as before.
        case resumeNow
        /// A reposition is pending: record the intent only; the landing resumes.
        case recordIntent
    }

    static func playAction(seekInFlight: Bool, holdEnabled: Bool) -> PlayAction {
        (seekInFlight && holdEnabled) ? .recordIntent : .resumeNow
    }
}

/// Whether a demuxer-driven loop may take the demuxer for a packet read right now. The reposition
/// pending flag is the second half of `SeekWindowTransport`: whatever wakes the loop inside a seek
/// window, it must not read until the reposition has landed, or the packet it gets is pre-seek.
enum SWDemuxReadAdmission {
    static func mayReadPacket(isPlaying: Bool, repositionPending: Bool, stopRequested: Bool) -> Bool {
        isPlaying && !repositionPending && !stopRequested
    }
}
