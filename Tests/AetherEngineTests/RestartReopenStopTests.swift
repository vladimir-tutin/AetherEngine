import Testing
import Foundation
@testable import AetherEngine

/// The #79 / #169 restart opens a replacement demuxer while the old pump is wedged. `stop()` has to reach
/// that open: an unregistered one ran its connect and stream probe to the end after the session was gone.
@Suite("Restart reopen: stop() reaches the replacement demuxer")
struct RestartReopenStopTests {

    private func makeEngine() -> HLSVideoEngine {
        HLSVideoEngine(url: URL(fileURLWithPath: "/nonexistent/restart-reopen.mkv"), dvModeAvailable: false)
    }

    @Test("A stop after registration aborts the replacement's open before it reaches the origin")
    func stopAbortsTheRegisteredOpen() throws {
        let origin = try ProbeHTTPTestOrigin(data: try ProbeTestFixtures.hdr10Plus())
        defer { origin.stop() }
        let engine = makeEngine()
        let fresh = try #require(engine.registerRestartReopenDemuxer(epoch: 0))
        defer { fresh.close() }

        engine.stop()

        let url = try #require(URL(string: "http://127.0.0.1:\(origin.port)/restart-reopen.mp4"))
        #expect(throws: (any Error).self) { try fresh.open(url: url) }
        #expect(origin.requests.isEmpty)
    }

    @Test("A restart that a stop already superseded opens no replacement at all")
    func supersededRestartRegistersNothing() {
        let engine = makeEngine()
        engine.stop()
        #expect(engine.registerRestartReopenDemuxer(epoch: 0) == nil)
    }
}
