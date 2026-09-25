import Foundation
import Testing
@testable import AetherEngine

/// #227 round 2: the edge hold was on ONE of the engine's session-preserving rebuilds, and the other
/// three went without it. Every rebuild tears down the item the external-playback KVO watches, so
/// every one of them raises a `false` edge that describes the teardown and not the route.
///
/// Measured on an AirPlay route (device log 2026-09-19, Sodalite#156): an audio pick cleared
/// `airPlayActive` on that unheld edge before `loadNative` read it, rebuilt the session on 127.0.0.1,
/// which a receiver cannot reach, and then paid for a second full rebuild when the receiver
/// re-engaged. The log shows the asymmetry directly: no "holding the edge" line during the audio
/// rebuild, two of them during the `reloadAtCurrentPosition` that followed it.
///
/// The invariant is structural (WHERE the hold is raised), so the test is structural too, the same
/// shape `Issue541ReloadCarriesHDRRouteTests` uses to pin its reload call site.
struct Issue227EveryRebuildHoldsTheEdgeTests {

    private func engineSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/AetherEngine/\(name)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the shared rebuild funnel raises the hold, so the audio and disc-title picks inherit it")
    func reloadWithAudioOverrideHoldsTheEdge() throws {
        let text = try engineSource("AetherEngine+Loading.swift")
        let body = try #require(text.range(of: "func reloadWithAudioOverride(").map { text[$0.lowerBound...] })
        let head = String(body.prefix(4000))
        #expect(head.contains("sessionPreservingReloadInFlight = true"))
        #expect(head.contains("reconcileExternalPlaybackAfterReload()"))
    }

    @Test("neither rebuild site clears the flag outright, which would end an outer hold early")
    func theHoldIsRestoredNotCleared() throws {
        for name in ["AetherEngine.swift", "AetherEngine+Loading.swift"] {
            let text = try engineSource(name)
            // The property's own initialiser is the one `= false` allowed to stand.
            let clears = text.components(separatedBy: "sessionPreservingReloadInFlight = false").count - 1
            let declares = text.contains("var sessionPreservingReloadInFlight = false") ? 1 : 0
            #expect(clears == declares, "\(name) clears the hold instead of restoring it")
            #expect(text.contains("sessionPreservingReloadInFlight = wasPreservingSession"))
        }
    }

    @Test("only the outermost rebuild reconciles the held edge")
    func nestedRebuildsDoNotReconcile() {
        #expect(AetherEngine.rebuildOwnsHeldExternalPlaybackEdge(wasAlreadyRebuilding: false))
        #expect(!AetherEngine.rebuildOwnsHeldExternalPlaybackEdge(wasAlreadyRebuilding: true))
    }
}
