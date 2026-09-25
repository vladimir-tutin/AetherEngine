import XCTest
@testable import AetherEngine

final class MovTextSampleBuilderTests: XCTestCase {
    func test_sanitize_plainPassesThrough() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("plain"), "plain")
    }

    func test_sanitize_stripsASSOverrideTagsAndConvertsBreaks() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("{\\an8}{\\b1}Top{\\b0}\\Nline"), "Top\nline")
    }

    func test_sanitize_convertsLowercaseBreakAndHardSpace() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("a\\nb\\hc"), "a\nb c")
    }

    func test_sanitize_trimsSurroundingWhitespace() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("  hello  "), "hello")
    }

    func test_sanitize_keepsAnUnclosedBraceAndWhatFollows() {
        XCTAssertEqual(MovTextSampleBuilder.sanitize("{\\b1}bold{unclosed tail"), "bold{unclosed tail")
        XCTAssertEqual(MovTextSampleBuilder.sanitize("{a{b}c}"), "c}")
    }

    /// Audit SUB-1: stripping this cue block by block took 525 s on an M-series Mac; one pass, 0.15 s.
    func test_sanitize_isLinearOnAHostileCueOfManySmallBlocks() {
        let hostile = String(repeating: "{\\1c&H00FF00&}x", count: 200_000)
        let started = Date()
        let clean = MovTextSampleBuilder.sanitize(hostile)
        XCTAssertEqual(clean.count, 200_000)
        XCTAssertTrue(clean.allSatisfy { $0 == "x" })
        XCTAssertLessThan(Date().timeIntervalSince(started), 2.0)
    }
}
