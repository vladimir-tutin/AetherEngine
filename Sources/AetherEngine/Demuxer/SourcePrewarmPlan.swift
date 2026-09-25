import Foundation

/// #551: what a warm still has to fetch once its head is in hand.
///
/// A second request is the most expensive thing a speculative path can spend against a metered
/// origin (#377), so the tail is asked for only where the session that opens this source will
/// actually go looking for it. Two layouts do:
///
/// - an MP4 whose `moov` sits behind media the warm head does not reach, which is the layout #281
///   was reported about, and
/// - a Matroska whose SeekHead names a level-1 object that lies past the warm head. Its Cues are
///   the usual one, and `HLSVideoEngine`'s cue prewarm makes that read a certainty rather than a
///   possibility: right after the open it seeks to the middle of the title so libavformat loads
///   the index, which is priced in its own comment as "1-2 byte-range reads". `read_header` adds
///   the same shape for every non-Cues object the SeekHead points at (Tags, Chapters,
///   Attachments), because `matroska_execute_seekhead` parses those on the spot and defers only
///   the Cues.
///
/// Matroska was excluded here until AE#551 round 2, on the reading that it reads no cues at open.
/// That is true of `read_header` alone and false of the session: measured against a logging origin,
/// a warmed 63 MB MKV still spent a request on `bytes=63704296-63708626`, which is its Cues
/// element to the byte.
enum SourcePrewarmPlan {

    /// How many bytes past the first trailing object a warm is willing to pull.
    ///
    /// The MP4 case asks for a fixed 64 KB suffix; the Matroska case asks for everything from the
    /// first trailing object to the end of the source, because that is the span the reads land in
    /// and only the origin knows where the objects end. That span is normally tiny (4.3 KB of Cues
    /// on the 7 minute fixture this was measured on, tens of KB on a feature title at one cue per
    /// two seconds), so a source that wants more than this is one whose trailing objects are a
    /// download rather than an index, and the warm declines instead of spending the link on it.
    static let maxTrailingSpanBytes: Int64 = 1024 * 1024

    /// What a warm should fetch after its head.
    enum Trailing: Equatable {
        /// Nothing: the head covers what the open reads, or the container cannot say.
        case none
        /// The last `SourcePrewarmFetcher.tailBytes` of the source (MP4 with `moov` at the end).
        case suffix
        /// Everything from `start` to the end of the source (Matroska trailing objects).
        case range(start: Int64)
    }

    /// The decision, given the warm head and where it ends.
    ///
    /// - Parameters:
    ///   - head: the warm's head bytes, starting at byte zero.
    ///   - total: the source's total size, out of the head response's `Content-Range`.
    static func trailing(head: Data, total: Int64) -> Trailing {
        if isMP4Family(head) {
            return needsTrailingObject(head: head) ? .suffix : .none
        }
        if isMatroska(head), let start = firstTrailingObject(head: head, headEnd: Int64(head.count)) {
            guard start < total, total - start <= maxTrailingSpanBytes else { return .none }
            return .range(start: start)
        }
        return .none
    }

    /// Walks the top-level box chain inside `head` and reports whether the source's trailing object
    /// is still unaccounted for. False for anything that is not an MP4-family head, and false as
    /// soon as `moov` is found inside the warm bytes.
    static func needsTrailingObject(head: Data) -> Bool {
        guard isMP4Family(head) else { return false }
        var offset = 0
        while offset + 8 <= head.count {
            let size32 = beUInt32(head, at: offset)
            let type = boxType(head, at: offset + 4)
            if type == "moov" { return false }
            var advance: Int64
            switch size32 {
            case 0:
                // "To the end of the file": nothing follows it, so the walk is over and the warm
                // head never saw a moov.
                return true
            case 1:
                guard offset + 16 <= head.count else { return true }
                let large = beUInt64(head, at: offset + 8)
                guard large >= 16 else { return true }
                advance = Int64(bitPattern: large)
            default:
                guard size32 >= 8 else { return true }
                advance = Int64(size32)
            }
            guard advance > 0, offset < Int.max - Int(clamping: advance) else { return true }
            offset += Int(clamping: advance)
        }
        return true
    }

    // MARK: - Matroska

    private static let idEBMLHeader: UInt64 = 0x1A45_DFA3
    private static let idSegment: UInt64 = 0x1853_8067
    private static let idSeekHead: UInt64 = 0x114D_9B74
    private static let idSeek: UInt64 = 0x4DBB
    private static let idSeekID: UInt64 = 0x53AB
    private static let idSeekPosition: UInt64 = 0x53AC
    private static let idCluster: UInt64 = 0x1F43_B675

    static func isMatroska(_ head: Data) -> Bool {
        head.count >= 4 && readID(head, at: 0)?.value == idEBMLHeader
    }

    /// The lowest absolute offset at or past `headEnd` that the head's SeekHead points at.
    ///
    /// Clusters are excluded: they are media, and a session reads them because it is playing, not
    /// because it is opening. Everything else the SeekHead names is an object `matroska_read_header`
    /// or the cue prewarm goes and parses, so the span from the earliest of them to the end of the
    /// source is exactly the ground those reads land in.
    ///
    /// Positions are relative to the Segment's DATA start, which is what `segment_start` means in
    /// libavformat's matroska demuxer, so the walk has to find the Segment before it can resolve
    /// one.
    static func firstTrailingObject(head: Data, headEnd: Int64) -> Int64? {
        guard let ebml = readElement(head, at: 0), ebml.id == idEBMLHeader, let ebmlSize = ebml.size
        else { return nil }
        var offset = ebml.headerLength + Int(clamping: ebmlSize)
        // Void / CRC-32 between the EBML header and the Segment are legal; walk until the Segment.
        while offset < head.count, let element = readElement(head, at: offset) {
            if element.id == idSegment {
                let dataStart = offset + element.headerLength
                return firstTrailingObject(inSegment: head, dataStart: dataStart, headEnd: headEnd)
            }
            guard let size = element.size else { return nil }
            offset += element.headerLength + Int(clamping: size)
        }
        return nil
    }

    private static func firstTrailingObject(inSegment head: Data,
                                            dataStart: Int,
                                            headEnd: Int64) -> Int64? {
        var offset = dataStart
        var earliest: Int64?
        while offset < head.count, let element = readElement(head, at: offset) {
            if element.id == idSeekHead {
                guard let size = element.size else { return earliest }
                let start = offset + element.headerLength
                let end = min(head.count, start + Int(clamping: size))
                // A SeekHead truncated by the warm head's edge still yields the entries that fit.
                for position in seekPositions(head, from: start, to: end) {
                    // Audit DMX-2: an 8-byte SeekPosition reaches Int64.max; such an entry names
                    // nothing a source can hold, so it is skipped rather than added.
                    let (absolute, overflow) = Int64(dataStart).addingReportingOverflow(position)
                    guard !overflow, absolute >= headEnd else { continue }
                    earliest = min(earliest ?? absolute, absolute)
                }
            }
            guard let size = element.size else { return earliest }
            let next = offset + element.headerLength + Int(clamping: size)
            guard next > offset else { return earliest }
            offset = next
        }
        return earliest
    }

    /// The `SeekPosition` of every `Seek` entry in the range whose `SeekID` is not a Cluster.
    private static func seekPositions(_ head: Data, from: Int, to end: Int) -> [Int64] {
        var positions: [Int64] = []
        var offset = from
        while offset < end, let entry = readElement(head, at: offset) {
            guard let entrySize = entry.size else { return positions }
            let entryEnd = min(end, offset + entry.headerLength + Int(clamping: entrySize))
            if entry.id == idSeek {
                var seekID: UInt64?
                var position: Int64?
                var inner = offset + entry.headerLength
                while inner < entryEnd, let field = readElement(head, at: inner) {
                    guard let size = field.size else { break }
                    let valueStart = inner + field.headerLength
                    let valueEnd = min(entryEnd, valueStart + Int(clamping: size))
                    if field.id == idSeekID {
                        seekID = beUInt(head, from: valueStart, to: valueEnd)
                    } else if field.id == idSeekPosition {
                        position = beUInt(head, from: valueStart, to: valueEnd).map { Int64(clamping: $0) }
                    }
                    inner = valueStart + Int(clamping: size)
                }
                if let position, position >= 0, seekID != idCluster {
                    positions.append(position)
                }
            }
            offset = entryEnd > offset ? entryEnd : end
        }
        return positions
    }

    private struct Element {
        let id: UInt64
        /// Nil for the unknown-size form, which only a Segment or Cluster uses.
        let size: UInt64?
        let headerLength: Int
    }

    private static func readElement(_ data: Data, at offset: Int) -> Element? {
        guard let id = readID(data, at: offset),
              let size = readSize(data, at: offset + id.length)
        else { return nil }
        return Element(id: id.value, size: size.value, headerLength: id.length + size.length)
    }

    private static func readID(_ data: Data, at offset: Int) -> (value: UInt64, length: Int)? {
        guard offset >= 0, offset < data.count else { return nil }
        let base = data.startIndex + offset
        let first = data[base]
        guard first != 0 else { return nil }
        var length = 0
        for i in 0..<4 where first & (0x80 >> UInt8(i)) != 0 {
            length = i + 1
            break
        }
        guard length > 0, offset + length <= data.count else { return nil }
        var value: UInt64 = 0
        for i in 0..<length { value = (value << 8) | UInt64(data[base + i]) }
        return (value, length)
    }

    private static func readSize(_ data: Data, at offset: Int) -> (value: UInt64?, length: Int)? {
        guard offset >= 0, offset < data.count else { return nil }
        let base = data.startIndex + offset
        let first = data[base]
        guard first != 0 else { return nil }
        var length = 0
        for i in 0..<8 where first & (0x80 >> UInt8(i)) != 0 {
            length = i + 1
            break
        }
        guard length > 0, offset + length <= data.count else { return nil }
        var value = UInt64(first & (0xFF >> UInt8(length)))
        for i in 1..<length { value = (value << 8) | UInt64(data[base + i]) }
        // All value bits set is the unknown-length form.
        let unknown = (UInt64(1) << (7 * UInt64(length))) - 1
        return (value == unknown ? nil : value, length)
    }

    private static func beUInt(_ data: Data, from: Int, to end: Int) -> UInt64? {
        guard from >= 0, end <= data.count, from < end, end - from <= 8 else { return nil }
        let base = data.startIndex
        var value: UInt64 = 0
        for i in from..<end { value = (value << 8) | UInt64(data[base + i]) }
        return value
    }

    // MARK: - MP4

    /// `ftyp` at the start is the ISO base-media brand marker; `moov` / `mdat` / `free` cover the
    /// QuickTime files that open without one.
    private static func isMP4Family(_ head: Data) -> Bool {
        guard head.count >= 8 else { return false }
        switch boxType(head, at: 4) {
        case "ftyp", "moov", "mdat", "free", "skip", "wide", "pnot": return true
        default: return false
        }
    }

    private static func boxType(_ data: Data, at offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        let base = data.startIndex + offset
        let bytes = [UInt8](data[base..<(base + 4)])
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func beUInt32(_ data: Data, at offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(data[base + i]) }
        return v
    }

    private static func beUInt64(_ data: Data, at offset: Int) -> UInt64 {
        let base = data.startIndex + offset
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(data[base + i]) }
        return v
    }
}
