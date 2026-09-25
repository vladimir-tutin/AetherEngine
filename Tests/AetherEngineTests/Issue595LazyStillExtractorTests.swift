import Testing
@testable import AetherEngine

/// AE#595: the software live still extractor was built for every session that had a DVR ring,
/// whether a still was ever asked for or not, which is a second decoder and its frame buffers
/// standing for the whole session on a box with under 4 GB of RAM.
///
/// Deferring it puts two promises on one slot, and the second is the one that bites: a held scrub
/// asks about sixteen times a second, so a build that cannot succeed must be attempted once rather
/// than once per request. These pin the slot rather than the host, which owns a demuxer and a ring
/// a test cannot stand up.
@Suite("A one-shot slot builds late and at most once (#595)")
struct Issue595LazyStillExtractorTests {

    private final class Counter {
        private(set) var calls = 0
        func record() { calls += 1 }
    }

    @Test("nothing is built until something asks")
    func idleSlotBuildsNothing() {
        let counter = Counter()
        var slot = OneShotSlot<String>()

        #expect(slot.current == nil)
        #expect(counter.calls == 0)

        _ = slot.resolve { counter.record(); return "built" }
        #expect(counter.calls == 1)
    }

    @Test("the first ask builds it and every later ask gets the same one")
    func firstAskBuildsAndCaches() {
        let counter = Counter()
        var slot = OneShotSlot<String>()

        #expect(slot.resolve { counter.record(); return "extractor" } == "extractor")
        #expect(slot.resolve { counter.record(); return "another" } == "extractor")
        #expect(slot.current == "extractor")
        #expect(counter.calls == 1, "the slot rebuilt what it already held")
    }

    /// The log-flood half. A source the extractor cannot open fails on every request alike, and a
    /// scrub asks sixteen times a second.
    @Test("a build that fails is not attempted again")
    func failedBuildIsNotRetried() {
        let counter = Counter()
        var slot = OneShotSlot<String>()

        #expect(slot.resolve { counter.record(); return nil } == nil)
        #expect(slot.resolve { counter.record(); return nil } == nil)
        #expect(slot.resolve { counter.record(); return "late success" } == nil,
                "a slot that failed once answered a later factory")
        #expect(counter.calls == 1, "the failed build was retried \(counter.calls) times")
    }

    /// Teardown empties the slot, and the next session is entitled to its own attempt.
    @Test("a reset slot builds again")
    func resetSlotBuildsAgain() {
        let counter = Counter()
        var slot = OneShotSlot<String>()

        _ = slot.resolve { counter.record(); return nil }
        slot.reset()
        #expect(slot.resolve { counter.record(); return "fresh session" } == "fresh session")
        #expect(counter.calls == 2)
    }

    @Test("reset hands back what it held so a caller can close it")
    func resetReturnsTheHeldValue() {
        var slot = OneShotSlot<String>()
        _ = slot.resolve { "extractor" }

        #expect(slot.reset() == "extractor")
        #expect(slot.current == nil)
        #expect(slot.reset() == nil)
    }
}
