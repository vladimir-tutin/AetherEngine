import Foundation
import Testing
@testable import AetherEngine

/// A load that a stop() or a newer load() superseded while it was suspended must unwind without
/// touching the engine: the state it would write belongs to its successor.
@Suite("Superseded loads unwind without touching the successor")
@MainActor
struct StaleLoadGenerationTests {

    /// Audit CORE-6: the remote-HLS bypass read `loadGeneration` itself, after load()'s first
    /// suspension. A stale load resuming there adopted its successor's generation, so every later
    /// guard in the bypass passed, and it mounted its own URL on the shared native host.
    @Test("The remote-HLS bypass refuses a generation that has moved")
    func bypassRefusesStaleGeneration() async throws {
        let engine = try AetherEngine()
        let stale = engine.loadGeneration
        engine.stop()

        await #expect(throws: CancellationError.self) {
            try await engine.loadRemoteHLS(
                url: URL(string: "http://127.0.0.1:9/vod.m3u8")!,
                options: LoadOptions(nativeRemoteHLS: true),
                generation: stale)
        }
        #expect(engine.nativeHost == nil)
        #expect(engine.playbackBackend == .none)
    }
}
