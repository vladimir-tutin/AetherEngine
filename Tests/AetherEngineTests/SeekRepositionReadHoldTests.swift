import Testing
@testable import AetherEngine

/// A single 10 s rewind on the software path played nothing for the length of the rewind; a second
/// rewind pressed shortly after played at once. Device trace 2026-09-03 16:24:15 (Apple TV):
///
///     seek#5 programmatic began target=1027.26
///     [SWSeekClock] action=pin-at-entry from=1037.914s target=1027.258s resumeIntent=1
///     [PlayerStateReconcile] action=reassert-play boundary=seek-landed   <-- host play() at "began"
///     [SWHost] layer.isReadyForDisplay=false after 8636 frames
///     [AudioOutput] seekClock to=1027.258 rate=1.0                       <-- reposition landed 45 ms later
///     [SWDiag] clk=1027.52 aLead=14.42 parked=0 enq=+15 r4d=n            <-- lead = PRE-seek frontier
///     [SWDiag] clk=1028.52 aLead=13.42 parked=0 enq=+0  r4d=n            <-- read gate held, no frames
///     seek#6 programmatic began target=1018.27                           <-- second press
///     [AudioOutput] seekClock to=1018.273 rate=1.0                       <-- landed in 1 ms
///     [SWHost] layer.isReadyForDisplay=true after 8641 frames            <-- 53 ms later
///
/// The host `play()` inside the seek window flipped `isPlaying` back on, the demux loop woke while
/// the reposition was still queued behind the demuxer lock, won the lock, and read pre-seek packets
/// under the new generation. The audio lead then read 14 s (pre-seek frontier against the post-seek
/// clock) and the read gate held every read until the clock had walked back to the pre-seek
/// position. The second press found the loop idle, so its reposition landed first.
///
/// Two policies close the window: `play()` inside it records intent only, and the loop refuses
/// to read while the reposition is pending, whatever woke it.
@Suite("seek window: reposition read hold")
struct SeekRepositionReadHoldTests {

    // MARK: play() inside the seek window

    @Test("play() during an in-flight seek records intent instead of waking the loop")
    func playDuringRepositionRecordsIntent() {
        #expect(SeekWindowTransport.playAction(seekInFlight: true, holdEnabled: true) == .recordIntent)
    }

    @Test("play() outside a seek window resumes as before")
    func playOutsideWindowResumesNow() {
        #expect(SeekWindowTransport.playAction(seekInFlight: false, holdEnabled: true) == .resumeNow)
    }

    @Test("the kill switch restores the racing behavior")
    func killSwitchRestoresLegacyPlay() {
        #expect(SeekWindowTransport.playAction(seekInFlight: true, holdEnabled: false) == .resumeNow)
    }

    // MARK: the loop's read admission

    @Test("a playing loop must not read while the reposition is pending")
    func pendingRepositionHoldsTheRead() {
        // The regression: the loop was playing (host play() flipped it) and the reposition had not
        // yet taken the demuxer lock.
        #expect(SWDemuxReadAdmission.mayReadPacket(
            isPlaying: true, repositionPending: true, stopRequested: false) == false)
    }

    @Test("the read is admitted once the reposition has landed")
    func landedRepositionAdmitsTheRead() {
        #expect(SWDemuxReadAdmission.mayReadPacket(
            isPlaying: true, repositionPending: false, stopRequested: false))
    }

    @Test("stop always wins over the hold")
    func stopWinsOverHold() {
        #expect(SWDemuxReadAdmission.mayReadPacket(
            isPlaying: true, repositionPending: true, stopRequested: true) == false)
        #expect(SWDemuxReadAdmission.mayReadPacket(
            isPlaying: true, repositionPending: false, stopRequested: true) == false)
    }

    @Test("a parked loop is not admitted by the hold clearing")
    func parkedLoopStaysParked() {
        #expect(SWDemuxReadAdmission.mayReadPacket(
            isPlaying: false, repositionPending: false, stopRequested: false) == false)
    }

    // MARK: policy surface

    @Test("the hold ships ON and the pre-change preset turns it off")
    func policyDefaults() {
        #expect(AetherSourceBufferPolicy().seekRepositionHoldEnabled)
        #expect(AetherSourceBufferPolicy.stock.seekRepositionHoldEnabled)
        #expect(AetherSourceBufferPolicy.preChange.seekRepositionHoldEnabled == false)
    }

    // MARK: the #292 stash still decides the landing

    @Test("the intent recorded inside the window is what the landing resumes on")
    func recordedIntentDecidesTheLanding() {
        // play() inside the window sets the stash; the landing reads the stash, not the parked flag.
        #expect(SeekResumeIntent.resolve(isPlaying: false, seekInFlight: true, inFlightIntent: true))
    }
}
