import Foundation
import Testing
@testable import AetherEngine

/// AE#592: `SoftwarePacketReadAhead` computes the frontier on every produced packet (the
/// backpressure check at `:459`), for video and audio coverage both. `frontier(containing:)` is a
/// binary search; `frontierSeconds(containing:...)` walked the same sorted, disjoint ranges
/// linearly, converting two `Int64` bounds to `Double` and running two exactness guards per range.
/// A CPU-attributed profile put that one loop at about a third of the software route's extra CPU.
///
/// These pin the semantics so the walk can be replaced: the answer is the end of the first range
/// whose end lies past the clock, and only when the clock is not in a gap before it.
@Suite("AE#592: the seconds frontier")
struct Issue592CoverageFrontierTests {

    /// 1/1000 time base keeps ticks and milliseconds the same number, so the expectations read.
    private func coverage(_ spans: [(Int64, Int64)]) -> SoftwarePacketCoverage {
        var c = SoftwarePacketCoverage()
        for (pts, dur) in spans { c.insert(pts: pts, duration: dur) }
        return c
    }

    private func frontier(_ c: SoftwarePacketCoverage, _ seconds: Double) -> Double? {
        c.frontierSeconds(containing: seconds, timeBaseNumerator: 1, timeBaseDenominator: 1000)
    }

    @Test("the frontier is the end of the span holding the clock")
    func insideASpan() {
        let c = coverage([(0, 1000), (1000, 1000), (2000, 1000)])
        #expect(frontier(c, 0.0) == 3.0)
        #expect(frontier(c, 2.999) == 3.0)
    }

    @Test("a clock in a gap has no frontier, and a later island is not one")
    func inAGap() {
        let c = coverage([(0, 1000), (5000, 1000)])
        #expect(frontier(c, 0.5) == 1.0)
        #expect(frontier(c, 1.0) == nil, "the end is exclusive")
        #expect(frontier(c, 3.0) == nil, "a future island is not a frontier for a clock in a gap")
        #expect(frontier(c, 5.5) == 6.0)
    }

    @Test("a clock before all coverage has no frontier")
    func beforeEverything() {
        #expect(frontier(coverage([(2000, 1000)]), 0.5) == nil)
        #expect(frontier(coverage([]), 0.5) == nil)
        #expect(frontier(coverage([(2000, 1000)]), 9.0) == nil)
    }

    /// The property that makes the walk replaceable: on many disjoint islands, every query must
    /// give what a linear scan of the same ranges gives. 600 islands, queried inside, on both
    /// edges and in every gap.
    @Test("many islands answer exactly as a linear scan does")
    func agreesWithALinearScanOnManyIslands() {
        let spans = (0..<600).map { (Int64($0) * 1000, Int64(400)) }   // 0.4 s island every 1.0 s
        let c = coverage(spans)
        #expect(c.rangeCount == 600, "the fixture must actually be fragmented")
        for i in 0..<600 {
            let base = Double(i)
            #expect(frontier(c, base) == base + 0.4, "inside island \(i)")
            #expect(frontier(c, base + 0.399) == base + 0.4, "last tick of island \(i)")
            #expect(frontier(c, base + 0.4) == nil, "the exclusive end of island \(i)")
            #expect(frontier(c, base + 0.7) == nil, "the gap after island \(i)")
        }
    }

    @Test("adjacent spans merge, so a contiguous read stays one range")
    func contiguousStaysOneRange() {
        let c = coverage((0..<500).map { (Int64($0) * 1000, Int64(1000)) })
        #expect(c.rangeCount == 1)
        #expect(frontier(c, 250.0) == 500.0)
    }

    /// Reported, not asserted. The walk's cost grows with the island count; the search's does not.
    @Test("the cost of one frontier query, reported")
    func costReport() {
        for count in [8, 600, 4000] {
            var c = SoftwarePacketCoverage()
            for i in 0..<count { c.insert(pts: Int64(i) * 1000, duration: 400) }
            let queries = 20_000
            let clock = Double(count - 1)
            let start = DispatchTime.now()
            for _ in 0..<queries { _ = frontier(c, clock) }
            let ns = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / Double(queries)
            print(String(format: "[AE592] frontierSeconds over %4d islands: %.0f ns/query", count, ns))
        }
        #expect(Bool(true))
    }
}
