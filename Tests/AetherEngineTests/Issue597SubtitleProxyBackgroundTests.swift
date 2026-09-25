import Foundation
import Testing
@testable import AetherEngine

/// AE#597 defect 3. `RemoteHLSSubtitleProxy.Prepared` owns an `HLSLocalServer` bound on `0.0.0.0`
/// with an accept thread and up to 32 connection threads, plus an optional `HLSOriginRelay`. It is
/// released in `load(source:)`'s prologue and in `stop()`, and **`stopInternal` never mentions it**,
/// so the one teardown the background path runs is the one teardown that leaves it standing. On
/// tvOS that socket then rides the whole suspension, which on a wake-from-sleep report is hours.
///
/// The release has to be conditional, and that is the whole difficulty of this defect: it may only
/// be dropped where the foreground return rebuilds it. A URL session returns through
/// `reloadAtCurrentPosition()`'s URL branch into `load()`, whose prologue re-prepares the stand-in.
/// A custom source returns through `reloadWithAudioOverride` into `loadNative`/`loadSoftware`, which
/// never reach `loadRemoteHLS`, so dropping it there would take the injected subtitle renditions
/// with it for the rest of the session.
@Suite("AE#597: the subtitle proxy does not ride a suspension")
struct Issue597SubtitleProxyBackgroundTests {

    @Test("a URL session releases the proxy, because its return rebuilds it")
    func urlSessionReleases() {
        #expect(AetherEngine.shouldReleaseSubtitleProxyForBackground(
            hasProxy: true, isCustomSource: false))
    }

    @Test("a custom source keeps it, because its return never reaches loadRemoteHLS")
    func customSourceKeepsIt() {
        #expect(!AetherEngine.shouldReleaseSubtitleProxyForBackground(
            hasProxy: true, isCustomSource: true))
    }

    @Test("a session with no proxy has nothing to release")
    func noProxyIsNotAnEvent() {
        #expect(!AetherEngine.shouldReleaseSubtitleProxyForBackground(
            hasProxy: false, isCustomSource: false))
        #expect(!AetherEngine.shouldReleaseSubtitleProxyForBackground(
            hasProxy: false, isCustomSource: true))
    }
}
