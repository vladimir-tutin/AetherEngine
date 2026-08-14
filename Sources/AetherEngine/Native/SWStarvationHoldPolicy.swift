import Foundation

/// VOD starvation clock hold (2026-08-14 field capture).
///
/// # The defect
///
/// `AVSampleBufferRenderSynchronizer` is a free-running timebase: once running it advances
/// whether or not the renderers have media. During a 6.4 s source-read stall the master clock ran
/// 2033.73 → 2040.27 while the last fed audio PTS sat at 2035.20 (`[SWAudioLead] leadS=-5.07
/// decision=STARVED`); when bytes arrived the pipeline decoded ~8.4 s of media in 2 s and the
/// renderers raced to rejoin the runaway clock — on screen: a freeze, then fast-forward.
///
/// Live sessions already handle this (`AudioLookaheadPolicy.clockAction` pauses the clock at the
/// ring edge and resumes after refill). VOD had no equivalent because the combined demux thread —
/// the only place that knows the feed stopped — is itself BLOCKED inside the stalled read. So
/// this decision runs on the host's 0.25 s time tick instead, against the demux thread's last
/// published fed-audio PTS.
///
/// # Ownership rules
///
/// The hold may only ever take the clock from RUNNING to held, and may only resume a clock it
/// held itself. A user pause, a seek re-anchor, or a host rate change each make `effectiveRate`
/// or `isPlaying` disagree with the hold's expectations, and the hold RELEASES (clears its state
/// without touching the clock) rather than fight the new owner.
enum SWStarvationHoldPolicy {

    enum Action: Equatable {
        /// Nothing to do this tick.
        case none
        /// Pause the clock: the source has starved the audio feed to the hold threshold.
        case hold
        /// The feed refilled (or nothing more will ever arrive): restart the clock in place.
        case resume
        /// Someone else took clock ownership while held (user pause, seek, teardown): clear the
        /// hold state and do not touch the clock.
        case release
    }

    // swiftlint:disable:next function_parameter_count
    static func decide(
        holdActive: Bool,
        enabled: Bool,
        isLive: Bool,
        clockArmed: Bool,
        isPlaying: Bool,
        requestedRate: Float,
        effectiveRate: Float,
        lastFedAudioPTS: Double,
        clockSeconds: Double,
        sourceEOFSeen: Bool,
        holdLeadSeconds: Double,
        resumeLeadSeconds: Double
    ) -> Action {
        // Live sessions own their rebuffer hold in the feeder pump; never double-manage.
        guard !isLive else { return holdActive ? .release : .none }
        let lead = lastFedAudioPTS.isFinite ? lastFedAudioPTS - clockSeconds : Double.nan

        if holdActive {
            // Kill switch flipped mid-hold: restore the clock rather than strand it at rate 0.
            guard enabled else { return .resume }
            // User paused, or the session is tearing down: they own the clock now.
            guard isPlaying, requestedRate > 0 else { return .release }
            // A seek/play restarted the clock underneath the hold: it is no longer ours.
            if effectiveRate > 0 { return .release }
            // EOF: nothing more will arrive; resume and drain what is queued (mirrors the live
            // policy's `sourceEnded` arm).
            if sourceEOFSeen { return .resume }
            if lead.isFinite, lead >= resumeLeadSeconds { return .resume }
            return .none
        }

        guard enabled, clockArmed, isPlaying, requestedRate > 0 else { return .none }
        // Only hold a clock that is actually running; effectiveRate 0 with a positive requested
        // rate is either a pending deferred rate change or a wedge — both owned elsewhere.
        guard effectiveRate > 0 else { return .none }
        // EOF tail: the queued media drains against the running clock; a hold here would freeze
        // the last moments of the file forever.
        guard !sourceEOFSeen else { return .none }
        // NaN lead = no audio fed yet this session/seek (or an audio-less file): no basis to hold.
        guard lead.isFinite, lead <= holdLeadSeconds else { return .none }
        return .hold
    }
}
