import Testing
import Foundation
@testable import AetherEngine

/// AE#585: the open phase ends at `probeStreams`, and the very next thing the native path does is
/// the cue prewarm, a bounded seek into the middle of the title so libavformat loads the container
/// index. That read is outside the retained head, so #281's drop rule fired on it and threw the
/// head away. The cursor is then reset to zero and playback's first read re-fetched the same bytes:
/// 8 MB re-downloaded per warmed session, the whole warm spent on nothing but the parse.
///
/// The drop rule's own premise is that the read is playback ("moved beyond it or started nowhere
/// near it"). The index pass is neither, so it says so, and the rule stands unchanged around it.
@Suite("The index pass keeps the head (#585)")
struct Issue585IndexPassKeepsTheHeadTests {

    private let fileSize: Int64 = 512 * 1024 * 1024

    private func makeReader(_ server: ThrottledOriginServer) -> AVIOReader {
        AVIOReader(url: URL(string: "http://127.0.0.1:\(server.port)/movie.bin")!)
    }

    private func read(_ reader: AVIOReader, _ size: Int) -> Int32 {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buf.deallocate() }
        return reader.read(into: buf, size: Int32(size))
    }

    /// The shape from the report: prewarm to the middle, cursor back to zero, playback's first read
    /// served from bytes already in hand.
    @Test("the cue prewarm's seek does not release the head")
    func indexPassKeepsTheHead() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)   // the parse's walk from byte zero

        reader.markOpenPhaseFinished()
        reader.beginIndexPass()

        // The cue prewarm: one bounded excursion to the middle for the container's index.
        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterPrewarm = server.rangeRequestCount

        reader.endIndexPass()

        // The cursor reset, and then playback's first read.
        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        let got = read(reader, 32 * 1024)

        #expect(got == 32 * 1024, "playback's first read returned \(got)")
        #expect(server.rangeRequestCount == requestsAfterPrewarm,
                "the prewarm dropped the head and playback re-fetched it: \(server.requestedRanges)")
    }

    /// The suppression is the pass, not the session. Once it ends, the head is released by the first
    /// read it cannot answer exactly as #281 leaves it.
    @Test("the head is released again once the index pass has ended")
    func endingThePassRestoresTheDropRule() async throws {
        let server = try #require(ThrottledOriginServer(totalSize: fileSize))
        defer { server.stop() }
        let reader = makeReader(server)
        defer { reader.markClosed(); reader.close() }
        try reader.open()
        _ = read(reader, 1 * 1024 * 1024)

        reader.markOpenPhaseFinished()
        reader.beginIndexPass()
        reader.endIndexPass()

        // Playback moving away, which is what the drop rule exists for.
        let farOffset = fileSize / 2
        #expect(reader.seek(offset: farOffset, whence: SEEK_SET) == farOffset)
        _ = read(reader, 64 * 1024)
        let requestsAfterSeek = server.rangeRequestCount

        #expect(reader.seek(offset: 4096, whence: SEEK_SET) == 4096)
        _ = read(reader, 32 * 1024)

        #expect(server.rangeRequestCount > requestsAfterSeek,
                "the head outlived the index pass: \(server.requestedRanges)")
    }
}
