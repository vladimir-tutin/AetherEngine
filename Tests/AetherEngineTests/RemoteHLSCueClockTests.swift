import Testing
import Foundation
@testable import AetherEngine

/// AE#616: on `nativeRemoteHLS`, a Jellyfin transcode restarted at the keyframe before a slot makes
/// AVPlayer's item time lead the picture. The injected #316 renditions are placed by media timestamp,
/// so a line presented at item time T whose cue starts at S measures the lead T - S. Values are the
/// reporter's measurements (seg 494: slot 1483.482, keyframe 1482.272, lead 1.209).
struct RemoteHLSCueClockTests {

    private func clock(_ cues: [(Double, String)]) -> RemoteHLSCueClock {
        var clock = RemoteHLSCueClock()
        clock.setCues(cues.map { (start: $0.0, text: $0.1) })
        clock.noteTimeJump()
        // The landing delivery after the jump teaches nothing by design.
        _ = clock.observe(strings: [], itemTime: 0)
        return clock
    }

    @Test("A presented line measures item time minus its cue start")
    func measuresLead() throws {
        var c = clock([(1490.0, "Where were you?"), (1493.5, "Out.")])
        let measured = c.observe(strings: ["Where were you?"], itemTime: 1491.209)
        let lead = try #require(measured)
        #expect(abs(lead - 1.209) < 1e-9)
        #expect(c.offset == lead)
    }

    @Test("Each new line re-measures, so a seek that moved the anchor is corrected on the next line")
    func remeasuresAfterSeek() throws {
        var c = clock([(1490.0, "Where were you?"), (1800.0, "Run.")])
        _ = c.observe(strings: ["Where were you?"], itemTime: 1491.209)
        c.noteTimeJump()
        _ = c.observe(strings: [], itemTime: 1790.0)
        let measured = c.observe(strings: ["Run."], itemTime: 1803.086)
        let lead = try #require(measured)
        #expect(abs(lead - 3.086) < 1e-9)
    }

    @Test("The delivery at a seek landing is skipped: a line active there is stamped with the landing, not its start")
    func skipsLandingDelivery() {
        var c = RemoteHLSCueClock()
        c.setCues([(start: 100.0, text: "Long line")])
        c.noteTimeJump()
        let measured = c.observe(strings: ["Long line"], itemTime: 103.5)
        #expect(measured == nil)
        #expect(c.offset == nil)
    }

    @Test("A line ending measures nothing; the survivor was stamped when it appeared")
    func endingLineMeasuresNothing() {
        var c = clock([(10.0, "A"), (11.0, "B")])
        _ = c.observe(strings: ["A"], itemTime: 12.0)
        _ = c.observe(strings: ["A", "B"], itemTime: 13.0)
        let measured = c.observe(strings: ["B"], itemTime: 14.0)
        #expect(measured == nil)
        #expect(c.offset == 2.0)
    }

    @Test("Repeated text resolves to the start nearest the current lead")
    func repeatedTextPicksNearestToCurrentLead() throws {
        var c = clock([(20.0, "First"), (100.0, "Yeah."), (104.0, "Yeah.")])
        _ = c.observe(strings: ["First"], itemTime: 23.0)   // lead 3
        _ = c.observe(strings: [], itemTime: 24.0)
        // Candidates 107 - 100 = 7 and 107 - 104 = 3; the current lead is 3.
        let measured = c.observe(strings: ["Yeah."], itemTime: 107.0)
        let lead = try #require(measured)
        #expect(lead == 3.0)
    }

    @Test("A text with one plausible start wins over an ambiguous sibling in the same delivery")
    func uniqueCandidateWins() throws {
        var c = clock([(50.0, "Yeah."), (56.5, "Yeah."), (52.0, "Only once")])
        let measured = c.observe(strings: ["Yeah.", "Only once"], itemTime: 57.5)
        let lead = try #require(measured)
        #expect(lead == 5.5)
    }

    @Test("A match outside the plausible band is a different line, not a measurement")
    func implausibleMatchIgnored() {
        var c = clock([(10.0, "Hello")])
        let measured = c.observe(strings: ["Hello"], itemTime: 500.0)
        #expect(measured == nil)
        #expect(c.offset == nil)
    }

    @Test("Text AVPlayer hands back matches the sanitized cue the .vtt carried")
    func normalizationMatchesServedText() throws {
        var c = clock([(30.0, "{\\an8}Line one\\Nline  two")])
        let measured = c.observe(strings: ["<i>Line one</i>\nline two"], itemTime: 31.25)
        let lead = try #require(measured)
        #expect(lead == 1.25)
    }

    @Test("Unknown text measures nothing")
    func unknownText() {
        var c = clock([(30.0, "Known")])
        let measured = c.observe(strings: ["Origin's own rendition"], itemTime: 31.0)
        #expect(measured == nil)
    }

    @Test("A time jump marks the kept offset as unmeasured until the next matched line")
    func timeJumpClearsMeasuredUntilNextLine() {
        var c = clock([(1490.0, "Where were you?"), (1800.0, "Run.")])
        #expect(!c.isMeasuredSinceJump)
        _ = c.observe(strings: ["Where were you?"], itemTime: 1491.209)
        #expect(c.isMeasuredSinceJump)
        c.noteTimeJump()
        #expect(!c.isMeasuredSinceJump)
        #expect(c.offset.map { abs($0 - 1.209) < 1e-9 } == true)
        _ = c.observe(strings: [], itemTime: 1790.0)
        #expect(!c.isMeasuredSinceJump)
        _ = c.observe(strings: ["Run."], itemTime: 1803.086)
        #expect(c.isMeasuredSinceJump)
    }
}
