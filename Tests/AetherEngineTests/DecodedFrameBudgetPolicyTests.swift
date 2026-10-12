import Testing
import Foundation
@testable import AetherEngine

/// FlexUI decoded-frame memory budget.
///
/// The defect: a 4K 10-bit HEVC session held 15 decoded frames of 23.75 MiB (356 MiB of IOSurface)
/// because nothing bounded the admitted lead by MEMORY; the queue target's own fill point and the
/// reorder buffer set the count regardless of what a frame costs. The resolver here turns a byte
/// budget into a frame count from the measured frame size, with a floor the reorder path needs.
struct DecodedFrameBudgetPolicyTests {

    /// 3840x2160 P010: 3 bytes per pixel.
    private let frame4K10 = 3840 * 2160 * 3
    /// 3840x2160 NV12: 1.5 bytes per pixel.
    private let frame4K8 = 3840 * 2160 * 3 / 2
    /// 1920x1080 NV12.
    private let frame1080p8 = 1920 * 1080 * 3 / 2
    private let frame24 = 1001.0 / 24000.0

    private func policy(_ mib: Int) -> AetherDecodedFrameBudgetPolicy {
        AetherDecodedFrameBudgetPolicy(enabled: true, budgetBytes: mib * 1024 * 1024, minFrames: 6, maxFrames: 64)
    }

    @Test("disabled leaves the gate open")
    func disabledIsUnlimited() {
        let limit = AetherDecodedFrameBudgetPolicy.stock.resolve(frameBytes: frame4K10, frameDurationSeconds: frame24)
        #expect(!limit.isLimited)
        #expect(limit.reason == "disabled")
    }

    @Test("no frame seen or no frame rate leaves the gate open rather than guessing")
    func unresolvedIsUnlimited() {
        #expect(policy(150).resolve(frameBytes: 0, frameDurationSeconds: frame24).reason == "unresolved")
        #expect(policy(150).resolve(frameBytes: frame4K10, frameDurationSeconds: 0).reason == "unresolved")
        #expect(!policy(150).resolve(frameBytes: frame4K10, frameDurationSeconds: .nan).isLimited)
    }

    @Test("150 MiB buys 6 frames of 4K 10-bit, 12 of 4K 8-bit")
    func budgetScalesWithFrameCost() {
        let hdr = policy(150).resolve(frameBytes: frame4K10, frameDurationSeconds: frame24)
        #expect(hdr.frames == 6)
        #expect(hdr.reason == "budget")
        #expect(abs(hdr.leadSeconds - 6 * frame24) < 1e-9)
        let sdr = policy(150).resolve(frameBytes: frame4K8, frameDurationSeconds: frame24)
        #expect(sdr.frames == 12)
        #expect(sdr.reason == "budget")
    }

    @Test("a budget below the floor still admits the frames the reorder path needs")
    func floorWins() {
        let limit = policy(50).resolve(frameBytes: frame4K10, frameDurationSeconds: frame24)
        #expect(limit.frames == 6)
        #expect(limit.reason == "floor")
    }

    @Test("small frames hit the ceiling, not an unbounded count")
    func ceilingWins() {
        let limit = policy(400).resolve(frameBytes: frame1080p8, frameDurationSeconds: frame24)
        #expect(limit.frames == 64)
        #expect(limit.reason == "ceiling")
    }

    @Test("a policy change bumps the revision; an identical set does not")
    func revisionTracksChanges() {
        let before = AetherDecodedFrameBudget.revision
        AetherDecodedFrameBudget.policy = policy(150)
        let after = AetherDecodedFrameBudget.revision
        #expect(after == before + 1)
        AetherDecodedFrameBudget.policy = policy(150)
        #expect(AetherDecodedFrameBudget.revision == after)
        AetherDecodedFrameBudget.policy = .stock
    }
}
