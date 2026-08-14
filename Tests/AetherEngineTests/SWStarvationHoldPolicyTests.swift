import Testing
import Foundation
@testable import AetherEngine

/// VOD starvation clock hold (2026-08-14 field capture): during a 6.4 s source-read stall the
/// free-running synchronizer ran 2033.73 → 2040.27 while the fed audio PTS sat at 2035.20; on
/// refill the pipeline raced ~8.4 s of media in 2 s to rejoin the clock. The hold pauses the
/// clock at the starvation threshold and resumes IN PLACE after refill.
struct SWStarvationHoldPolicyTests {

    /// The capture's numbers verbatim: hold as the lead collapses, stay held while starved,
    /// resume in place once the feed rebuilds.
    private func decide(
        holdActive: Bool = false,
        enabled: Bool = true,
        isLive: Bool = false,
        clockArmed: Bool = true,
        isPlaying: Bool = true,
        requestedRate: Float = 1,
        effectiveRate: Float = 1,
        // Default lead ≈ 0.10 s: decisively INSIDE the 0.15 s hold threshold, so every guard
        // tested against these defaults is the actual reason a hold does not engage. (An exact
        // 0.15 gap is unusable: 2035.20 - 2035.05 rounds just above 0.15 in binary Double.)
        lastFedAudioPTS: Double = 2035.20,
        clockSeconds: Double = 2035.10,
        sourceEOFSeen: Bool = false,
        holdLeadSeconds: Double = 0.15,
        resumeLeadSeconds: Double = 2.0
    ) -> SWStarvationHoldPolicy.Action {
        SWStarvationHoldPolicy.decide(
            holdActive: holdActive, enabled: enabled, isLive: isLive, clockArmed: clockArmed,
            isPlaying: isPlaying, requestedRate: requestedRate, effectiveRate: effectiveRate,
            lastFedAudioPTS: lastFedAudioPTS, clockSeconds: clockSeconds,
            sourceEOFSeen: sourceEOFSeen, holdLeadSeconds: holdLeadSeconds,
            resumeLeadSeconds: resumeLeadSeconds)
    }

    @Test("the lead collapsing to the threshold engages the hold")
    func holdsAtThreshold() {
        #expect(decide() == .hold)
        // A healthy 1.38 s lead (the capture's steady state) never holds.
        #expect(decide(lastFedAudioPTS: 2035.10, clockSeconds: 2033.73) == .none)
    }

    @Test("while held, a partial refill stays held; the resume threshold releases in place")
    func resumesAfterRefill() {
        #expect(decide(holdActive: true, effectiveRate: 0,
                       lastFedAudioPTS: 2036.0, clockSeconds: 2035.1) == .none)
        #expect(decide(holdActive: true, effectiveRate: 0,
                       lastFedAudioPTS: 2037.2, clockSeconds: 2035.1) == .resume)
    }

    @Test("EOF is a drained file, not a starved source")
    func eofNeverHoldsAndAlwaysDrains() {
        // The tail's natural lead collapse must not freeze the last moments of the file: the
        // defaults are hold-eligible, so EOF is the only thing standing between this and .hold.
        #expect(decide(sourceEOFSeen: true) == .none)
        // A hold active when EOF lands resumes so the queued tail drains (mirrors the live
        // policy's sourceEnded arm).
        #expect(decide(holdActive: true, effectiveRate: 0, lastFedAudioPTS: 2035.20,
                       clockSeconds: 2035.1, sourceEOFSeen: true) == .resume)
    }

    @Test("the hold never fights another clock owner")
    func ownershipRules() {
        // User paused while held: release without touching their rate-0 clock.
        #expect(decide(holdActive: true, isPlaying: false, effectiveRate: 0) == .release)
        // A seek/play restarted the clock underneath the hold: it is no longer ours.
        #expect(decide(holdActive: true, effectiveRate: 1) == .release)
        // Not playing, clock not armed, or rate 0: never engage.
        #expect(decide(isPlaying: false) == .none)
        #expect(decide(clockArmed: false) == .none)
        #expect(decide(requestedRate: 0) == .none)
        // A clock already at effective rate 0 (user pause, pending deferred rate change) is
        // owned elsewhere; holding it would double-manage.
        #expect(decide(effectiveRate: 0) == .none)
    }

    @Test("live sessions are owned by the feeder pump's rebuffer hold")
    func liveIsExcluded() {
        #expect(decide(isLive: true) == .none)
        #expect(decide(holdActive: true, isLive: true) == .release)
    }

    @Test("no audio fed yet (or an audio-less file) gives no basis to hold")
    func nanLeadNeverHolds() {
        #expect(decide(lastFedAudioPTS: .nan) == .none)
    }

    @Test("the kill switch never strands a held clock at rate 0")
    func killSwitchResumesMidHold() {
        #expect(decide(enabled: false) == .none)
        #expect(decide(holdActive: true, enabled: false, effectiveRate: 0) == .resume)
    }
}
