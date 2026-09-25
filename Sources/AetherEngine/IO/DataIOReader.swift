import Foundation

/// In-memory `IOReader` over immutable `Data` parts read back to back as one stream. The scrub-thumbnail
/// path hands it init.mp4 plus a memory-mapped cached segment, so the segment is never copied into the heap
/// (audit SEG-2: concatenating the two made two full heap copies per still, one retained per LRU entry).
/// NSLock makes read/seek safe off the demux thread.
final class DataIOReader: IOReader, @unchecked Sendable {
    private let parts: [Data]
    private let partStarts: [Int]
    private let totalCount: Int
    private var position = 0
    private let lock = NSLock()

    convenience init(data: Data) {
        self.init(parts: [data])
    }

    init(parts: [Data]) {
        self.parts = parts
        var starts: [Int] = []
        var offset = 0
        for part in parts {
            starts.append(offset)
            offset += part.count
        }
        self.partStarts = starts
        self.totalCount = offset
    }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock()
        defer { lock.unlock() }
        guard position < totalCount else { return 0 }  // EOF
        let n = min(Int(size), totalCount - position)
        var copied = 0
        var partIndex = (partStarts.lastIndex(where: { $0 <= position }) ?? 0)
        while copied < n, partIndex < parts.count {
            let part = parts[partIndex]
            let offsetInPart = position + copied - partStarts[partIndex]
            let take = min(n - copied, part.count - offsetInPart)
            if take > 0 {
                let lower = part.startIndex + offsetInPart
                part.copyBytes(
                    to: UnsafeMutableBufferPointer(start: buffer + copied, count: take),
                    from: lower..<(lower + take)
                )
                copied += take
            }
            partIndex += 1
        }
        position += copied
        return Int32(copied)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        // AVSEEK_SIZE (65536): report total length, do not move.
        if whence == 65536 { return Int64(totalCount) }
        lock.lock()
        defer { lock.unlock() }
        let target: Int
        switch whence {
        case SEEK_SET: target = Int(offset)
        case SEEK_CUR: target = position + Int(offset)
        case SEEK_END: target = totalCount + Int(offset)
        default: return -1
        }
        guard target >= 0 else { return -1 }
        position = min(target, totalCount)
        return Int64(position)
    }

    func close() {}
}
