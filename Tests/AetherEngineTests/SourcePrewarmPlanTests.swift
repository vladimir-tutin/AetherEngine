import Testing
import Foundation
@testable import AetherEngine

/// #551: whether a warm needs a second request for the source's trailing object.
///
/// The question is worth asking because the answer is usually no, and a second request against a
/// metered origin is the most expensive thing a speculative path can spend. A fast-start MP4
/// carries its `moov` inside the warm head already; an MP4 whose `moov` is at the end is the
/// layout #281 was reported about.
///
/// Matroska was excluded here until AE#551 round 2 on the reading that it never reads its cues at
/// open. That holds for `matroska_read_header` and not for the session: `HLSVideoEngine` seeks to
/// the middle of the title right after the open so libavformat loads the index, and
/// `matroska_execute_seekhead` parses every non-Cues object the SeekHead points at on the spot.
/// Measured against a logging origin, a warmed 63 MB MKV still spent a request on
/// `bytes=63704296-63708626`, its Cues element to the byte. So the SeekHead is now read, and what
/// it names past the warm head is what the warm fetches.
@Suite("Source prewarm tail plan (#551)")
struct SourcePrewarmPlanTests {

    private func box(_ type: String, size: Int) -> Data {
        var d = Data()
        withUnsafeBytes(of: UInt32(size).bigEndian) { d.append(contentsOf: $0) }
        d.append(type.data(using: .ascii)!)
        d.append(Data(count: max(0, size - 8)))
        return d
    }

    @Test("a fast-start MP4 carries its moov in the head and needs nothing more")
    func faststartNeedsNoTail() {
        var head = box("ftyp", size: 32)
        head.append(box("moov", size: 4096))
        head.append(box("mdat", size: 65536))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == false)
    }

    @Test("an MP4 whose mdat runs past the warm head needs the tail")
    func moovAtEndNeedsTail() {
        var head = box("ftyp", size: 32)
        // An mdat larger than anything the warm holds: the moov is somewhere behind it.
        head.append(box("mdat", size: 512 * 1024 * 1024))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head.prefix(1 << 20)) == true)
    }

    @Test("Matroska is not an MP4 box chain, so the box walker says nothing about it")
    func matroskaIsNotWalkedAsMP4() {
        var head = Data([0x1A, 0x45, 0xDF, 0xA3])
        head.append(Data(count: 4096))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == false)
    }

    // MARK: - Matroska (AE#551 round 2)

    private func vint4(_ value: Int) -> Data {
        Data([UInt8(0x10 | ((value >> 24) & 0x0F)), UInt8((value >> 16) & 0xFF),
              UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
    }

    private func idBytes(_ id: UInt64) -> Data {
        var bytes: [UInt8] = []
        var started = false
        for shift in stride(from: 56, through: 0, by: -8) {
            let byte = UInt8((id >> UInt64(shift)) & 0xFF)
            if byte != 0 { started = true }
            if started { bytes.append(byte) }
        }
        return Data(bytes)
    }

    private func element(_ id: UInt64, _ payload: Data) -> Data {
        var d = idBytes(id)
        d.append(vint4(payload.count))
        d.append(payload)
        return d
    }

    private func beBytes(_ value: Int64) -> Data {
        var d = Data()
        withUnsafeBytes(of: value.bigEndian) { d.append(contentsOf: $0) }
        return d
    }

    private func seekEntry(id: UInt64, position: Int64) -> Data {
        var payload = element(0x53AB, idBytes(id))
        payload.append(element(0x53AC, beBytes(position)))
        return element(0x4DBB, payload)
    }

    /// An MKV head: EBML header, then a Segment whose SeekHead names the given objects. The
    /// positions are Segment-DATA relative, the way libavformat resolves them.
    private func matroskaHead(entries: [(id: UInt64, position: Int64)],
                              padTo: Int) -> (head: Data, segmentDataStart: Int) {
        var head = element(0x1A45_DFA3, Data(count: 31))
        var seekHeadPayload = Data()
        for entry in entries { seekHeadPayload.append(seekEntry(id: entry.id, position: entry.position)) }
        let seekHead = element(0x114D_9B74, seekHeadPayload)
        var segmentPayload = seekHead
        // Tracks, to prove the walk steps over what it does not care about.
        segmentPayload.append(element(0x1654_AE6B, Data(count: 64)))
        let segmentHeader = idBytes(0x1853_8067) + vint4(1 << 27)
        let segmentDataStart = head.count + segmentHeader.count
        head.append(segmentHeader)
        head.append(segmentPayload)
        if head.count < padTo { head.append(Data(count: padTo - head.count)) }
        return (head, segmentDataStart)
    }

    private let cuesID: UInt64 = 0x1C53_BB6B
    private let tagsID: UInt64 = 0x1254_C367
    private let clusterID: UInt64 = 0x1F43_B675

    @Test("a Matroska whose Cues sit past the warm head is warmed from the Cues to the end")
    func matroskaTrailingCuesAreFetched() {
        let headBytes = 64 * 1024
        let total: Int64 = 63_708_627
        // The fixture this was measured on: Cues 4331 bytes before the end.
        let cuesAbsolute = total - 4331
        // Positions are Segment-DATA relative, so the fixture has to state the entry that way.
        let dataStart = Int64(matroskaHead(entries: [], padTo: headBytes).segmentDataStart)
        let fixture = matroskaHead(entries: [(cuesID, cuesAbsolute - dataStart)], padTo: headBytes)
        #expect(SourcePrewarmPlan.trailing(head: fixture.head, total: total)
                == .range(start: cuesAbsolute))
    }

    @Test("a SeekPosition at the top of the 64-bit range is skipped instead of overflowing")
    func overflowingSeekPositionIsSkipped() {
        let fixture = matroskaHead(entries: [(cuesID, -1)], padTo: 4096)
        #expect(SourcePrewarmPlan.trailing(head: fixture.head, total: 63_708_627) == SourcePrewarmPlan.Trailing.none)
        let dataStart = Int64(fixture.segmentDataStart)
        let mixed = matroskaHead(entries: [(tagsID, Int64.max), (cuesID, 60_000 - dataStart)], padTo: 4096)
        #expect(SourcePrewarmPlan.trailing(head: mixed.head, total: 63_000) == .range(start: 60_000))
    }

    @Test("a Matroska whose objects all sit inside the warm head needs nothing more")
    func matroskaWithEverythingInTheHeadNeedsNothing() {
        let fixture = matroskaHead(entries: [(cuesID, 2048), (tagsID, 4096)], padTo: 64 * 1024)
        #expect(SourcePrewarmPlan.trailing(head: fixture.head, total: 63_708_627) == SourcePrewarmPlan.Trailing.none)
    }

    @Test("the earliest trailing object is what the span starts at")
    func earliestTrailingObjectWins() {
        let headBytes = 64 * 1024
        let total: Int64 = 8 * 1024 * 1024
        let probe = matroskaHead(entries: [], padTo: headBytes)
        let dataStart = Int64(probe.segmentDataStart)
        let tags = total - 300_000
        let cues = total - 500_000
        let fixture = matroskaHead(
            entries: [(tagsID, tags - dataStart), (cuesID, cues - dataStart)], padTo: headBytes)
        #expect(SourcePrewarmPlan.trailing(head: fixture.head, total: total) == .range(start: cues))
    }

    /// A Cluster is media. A session reads one because it is playing, not because it is opening,
    /// and warming from the first cluster to the end of a film is a download.
    @Test("a Cluster entry is not a trailing object")
    func clusterEntriesAreIgnored() {
        let headBytes = 64 * 1024
        let total: Int64 = 63_708_627
        let probe = matroskaHead(entries: [], padTo: headBytes)
        let dataStart = Int64(probe.segmentDataStart)
        let fixture = matroskaHead(entries: [(clusterID, 1_000_000 - dataStart)], padTo: headBytes)
        #expect(SourcePrewarmPlan.trailing(head: fixture.head, total: total) == SourcePrewarmPlan.Trailing.none)
    }

    /// The cap is what keeps this a warm rather than a transfer: an index that starts right behind
    /// the head and runs for tens of megabytes is not something to fetch speculatively.
    @Test("a trailing span wider than the cap is declined")
    func spanBeyondTheCapIsDeclined() {
        let headBytes = 64 * 1024
        let total: Int64 = 63_708_627
        let probe = matroskaHead(entries: [], padTo: headBytes)
        let dataStart = Int64(probe.segmentDataStart)
        let justInside = total - SourcePrewarmPlan.maxTrailingSpanBytes
        let justOutside = justInside - 1
        let inside = matroskaHead(entries: [(cuesID, justInside - dataStart)], padTo: headBytes)
        let outside = matroskaHead(entries: [(cuesID, justOutside - dataStart)], padTo: headBytes)
        #expect(SourcePrewarmPlan.trailing(head: inside.head, total: total) == .range(start: justInside))
        #expect(SourcePrewarmPlan.trailing(head: outside.head, total: total) == SourcePrewarmPlan.Trailing.none)
    }

    @Test("a Matroska head without a SeekHead is left alone")
    func matroskaWithoutSeekHeadNeedsNothing() {
        var head = element(0x1A45_DFA3, Data(count: 31))
        head.append(idBytes(0x1853_8067) + vint4(1 << 27))
        head.append(element(0x1654_AE6B, Data(count: 64)))
        head.append(Data(count: 4096))
        #expect(SourcePrewarmPlan.trailing(head: head, total: 63_708_627) == SourcePrewarmPlan.Trailing.none)
    }

    // MARK: - The MP4 answer, through the same entry point

    @Test("the MP4 layouts answer through trailing() the way they did through needsTrailingObject()")
    func mp4AnswersThroughTrailing() {
        var faststart = box("ftyp", size: 32)
        faststart.append(box("moov", size: 4096))
        faststart.append(box("mdat", size: 65536))
        #expect(SourcePrewarmPlan.trailing(head: faststart, total: 64 << 20) == SourcePrewarmPlan.Trailing.none)

        var moovEnd = box("ftyp", size: 32)
        moovEnd.append(box("mdat", size: 512 * 1024 * 1024))
        #expect(SourcePrewarmPlan.trailing(head: moovEnd.prefix(1 << 20), total: 512 << 20) == .suffix)
    }

    @Test("a container the sniffer does not know is left alone")
    func unknownNeedsNoTail() {
        let ts = Data([UInt8](repeating: 0x47, count: 4096))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: ts) == false)
        #expect(SourcePrewarmPlan.needsTrailingObject(head: Data()) == false)
    }

    /// A 64-bit `largesize` is how any real film-sized `mdat` states its length, so a walker that
    /// only reads the 32-bit field would read the first eight bytes of the payload as the next box.
    @Test("a 64-bit largesize box is walked, not misread")
    func largesizeIsWalked() {
        var head = box("ftyp", size: 32)
        var mdat = Data()
        withUnsafeBytes(of: UInt32(1).bigEndian) { mdat.append(contentsOf: $0) }
        mdat.append("mdat".data(using: .ascii)!)
        withUnsafeBytes(of: UInt64(8 * 1024 * 1024 * 1024).bigEndian) { mdat.append(contentsOf: $0) }
        head.append(mdat)
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == true)
    }

    /// A truncated header at the very end of the warm is not a box, and reading it as one would
    /// jump to an offset the file never had.
    @Test("a partial box header at the end of the head stops the walk")
    func partialHeaderStopsTheWalk() {
        var head = box("ftyp", size: 32)
        head.append(Data([0x00, 0x00, 0x10]))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == true)
    }

    @Test("a box claiming to run to end of file ends the walk")
    func sizeZeroEndsTheWalk() {
        var head = box("ftyp", size: 32)
        var toEOF = Data()
        withUnsafeBytes(of: UInt32(0).bigEndian) { toEOF.append(contentsOf: $0) }
        toEOF.append("mdat".data(using: .ascii)!)
        head.append(toEOF)
        head.append(Data(count: 1024))
        #expect(SourcePrewarmPlan.needsTrailingObject(head: head) == true)
    }
}
