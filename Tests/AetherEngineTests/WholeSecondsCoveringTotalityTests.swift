import Testing
@testable import AetherEngine

/// `wholeSecondsCovering` feeds `#EXT-X-TARGETDURATION` and the holdback. A duration from a broken source
/// used to reach `Int(_:)` unchecked, which traps on infinity, NaN and anything beyond `Int.max`.
@Suite("wholeSecondsCovering is total")
struct WholeSecondsCoveringTotalityTests {

    @Test("Finite durations keep their covering whole second", arguments: [
        (2.0, 2), (2.0000000000000004, 2), (2.0005, 3), (0.2, 1), (6.5, 7),
    ])
    func finiteDurationsUnchanged(seconds: Double, expected: Int) {
        #expect(LiveEdgePolicy.wholeSecondsCovering(seconds) == expected)
    }

    @Test("Hostile durations yield a bounded value instead of trapping", arguments: [
        Double.infinity, 1e300, Double(Int.max), Double.greatestFiniteMagnitude,
    ])
    func unboundedSaturates(seconds: Double) {
        #expect(LiveEdgePolicy.wholeSecondsCovering(seconds) == LiveEdgePolicy.maxCoveredWholeSeconds)
    }

    @Test("NaN, zero and negative durations cover nothing", arguments: [
        Double.nan, -Double.infinity, -1e300, -3.0, 0.0,
    ])
    func emptyCoversNothing(seconds: Double) {
        #expect(LiveEdgePolicy.wholeSecondsCovering(seconds) == 0)
    }

    @Test("The target duration survives a non-finite term, and the holdback stays computable")
    func targetDurationSurvivesHostileTerms() {
        let td = LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: .infinity, cutTargetSeconds: .nan, cadenceFloorSeconds: .infinity)
        #expect(td == LiveEdgePolicy.maxCoveredWholeSeconds)
        #expect(LiveEdgePolicy.holdBackSeconds(targetDuration: td) == Double(3 * td))
        #expect(LiveEdgePolicy.targetDurationSeconds(
            maxSegmentDuration: 2.0, cutTargetSeconds: .nan, cadenceFloorSeconds: .nan) == 2)
    }
}
