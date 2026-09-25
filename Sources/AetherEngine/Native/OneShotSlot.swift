/// AE#595: a value built at most once, on first use, and never rebuilt after a failure.
///
/// The shape a lazily built session resource needs, and the second half is the one that bites. A
/// held scrub asks for a still about sixteen times a second, so a build that cannot succeed must be
/// attempted once rather than once per request: otherwise deferring the work trades a fixed cost at
/// session start for an unbounded one during playback, and a log line per attempt on top.
///
/// Not thread-safe by itself. Its owner is expected to be isolated, which on the software host is
/// the main actor.
struct OneShotSlot<Value> {
    private var value: Value?
    private var attempted = false

    /// What the slot holds, without building anything. Teardown asks this.
    var current: Value? { value }

    /// The value, building it on the first ask. `make` runs at most once, whether or not it
    /// produces one.
    mutating func resolve(_ make: () -> Value?) -> Value? {
        if let value { return value }
        guard !attempted else { return nil }
        attempted = true
        value = make()
        return value
    }

    /// Empties the slot and hands back what it held, so a caller can close it. The next `resolve`
    /// is entitled to its own attempt, which is what makes this the per-session boundary.
    @discardableResult
    mutating func reset() -> Value? {
        let held = value
        value = nil
        attempted = false
        return held
    }
}
