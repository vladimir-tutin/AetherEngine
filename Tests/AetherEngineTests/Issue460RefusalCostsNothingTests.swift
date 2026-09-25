import Foundation
import Testing
@testable import AetherEngine

/// AE#460 rule 2, re-pinned: a correction that never rebuilds costs the session nothing.
///
/// `reloadAtCurrentPosition(applying:)` has four exits that never reach a rebuild - three throws
/// (a field that names the session, a session that cannot be rebuilt in place, and AE#461's
/// decode-path refusal) and the AE#464 round 4 early return for a field the session owns. The
/// function's own documentation says the refusals "leave the session untouched", and #461 round 2
/// moved the decode-path refusal ahead of `stopInternal` for exactly that reason.
///
/// AE#560 then put `endRecordingIfRunning(reason: .sourceReset)` on the first line of the function,
/// where it is correct for the rebuild below it and wrong for all four of those exits: a refused
/// correction finished the recording, wrote `recordingState = .ended` and left the session playing
/// on, with nothing said. Shipped in 7.8.0 through 7.10.0.
///
/// The rule is an ORDERING inside one function, so there is no policy value to assert and no way to
/// drive four refusals through a real session in a unit test. This reads the site, and it reads
/// positions rather than words so that rewording any of the four exits cannot quietly retire it.
@Suite("AE#460 a correction that does not rebuild costs nothing")
struct Issue460RefusalCostsNothingTests {

    /// The body of `reloadAtCurrentPosition(applying:)`, from its signature to its closing brace.
    private static func correctionBody() throws -> String {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/AetherEngine+ReloadWithOptions.swift")
        let text = try #require(try? String(contentsOf: source, encoding: .utf8))
        let start = try #require(text.range(of: "public func reloadAtCurrentPosition(\n        applying change:"))
        let rest = text[start.lowerBound...]
        // The function's closing brace is the first one at its own indentation.
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.upperBound])
    }

    @Test("every exit that does not rebuild is taken before the recording is ended")
    func refusalsRunBeforeTheRecordingEnds() throws {
        let body = try Self.correctionBody()
        let recordingEnd = try #require(body.range(of: "endRecordingIfRunning"))

        // The three throws, named by the error they carry so a reordering of the checks is fine and
        // a throw moved BELOW the recording teardown is not.
        for refusal in [
            "throw AetherEngineError.loadIdentityNotCorrectable",
            "throw AetherEngineError.sessionNotReloadable",
        ] {
            var searchFrom = body.startIndex
            var found = false
            while let hit = body.range(of: refusal, range: searchFrom..<body.endIndex) {
                found = true
                #expect(hit.upperBound < recordingEnd.lowerBound,
                        "\(refusal) throws after the recording has already been ended")
                searchFrom = hit.upperBound
            }
            #expect(found, "\(refusal) is gone from the correction; the exit it guarded moved")
        }

        // AE#464 round 4: the third answer returns without a rebuild at all.
        let sessionOwnedReturn = try #require(body.range(of: "rebuilt: false"))
        #expect(sessionOwnedReturn.upperBound < recordingEnd.lowerBound,
                "the session-owned early return happens after the recording has been ended")
    }

    @Test("the rebuild itself still ends the recording, exactly once and ahead of the teardown")
    func theRebuildStillEndsIt() throws {
        let body = try Self.correctionBody()
        #expect(body.components(separatedBy: "endRecordingIfRunning").count == 2,
                "the correction ends the recording more than once, or not at all")

        // AE#560's own requirement: the reload re-opens the source, so the recording has to be
        // finished as a source reset before the rebuild runs, not left for `stopInternal`.
        let recordingEnd = try #require(body.range(of: "endRecordingIfRunning"))
        let rebuild = try #require(body.range(of: "try await reloadAtCurrentPosition()"))
        #expect(recordingEnd.upperBound < rebuild.lowerBound,
                "the rebuild runs before the recording is closed as a source reset")

        // It also has to sit after the options are installed, so nothing between the two can throw
        // and leave a finished recording behind again.
        let install = try #require(body.range(of: "applySessionOptionCorrection(proposed)"))
        #expect(install.upperBound < recordingEnd.lowerBound,
                "the recording is ended before the last statement that could still refuse")
    }

    @Test("the reason is a source reset, not a host stop")
    func theReasonNamesWhatHappened() throws {
        let body = try Self.correctionBody()
        #expect(body.contains("endRecordingIfRunning(reason: .sourceReset)"))
    }
}
