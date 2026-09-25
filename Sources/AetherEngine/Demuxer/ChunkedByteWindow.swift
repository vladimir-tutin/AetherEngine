import Foundation

/// AE#619: the persistent reader's byte window, held as the chunks the connection delivered.
///
/// The reader used to keep one contiguous `Data` and drop its consumed head with `subdata(in:)`,
/// which copied everything still ahead of the cut: up to ~18 MB once per 4 MB consumed, several
/// times the stream's own rate in `memmove`, and each append after it reallocated the fresh buffer.
/// Here a drop advances an offset and releases the chunks it passed, and nothing ahead of it moves.
/// Callers see one contiguous run of `count` bytes; the chunking is invisible to them.
///
/// Not thread-safe. The reader guards it with `winCond` like the `Data` it replaces.
struct ChunkedByteWindow {
    private var chunks: [Data] = []
    /// Storage offset one past the end of `chunks[i]`. Storage offsets only grow until
    /// `removeAll`, so a drop never rewrites them.
    private var ends: [Int] = []
    /// Index of the first chunk still holding live bytes.
    private var first = 0
    /// Storage offset of logical byte 0.
    private var head = 0
    /// Storage offset one past the last byte.
    private var tail = 0

    var count: Int { tail - head }
    var isEmpty: Bool { tail == head }

    mutating func append(_ data: Data) {
        guard !data.isEmpty else { return }
        chunks.append(data)
        tail += data.count
        ends.append(tail)
    }

    /// Drops the first `n` bytes. `n` is clamped to `count`.
    mutating func dropFirst(_ n: Int) {
        head += min(max(0, n), count)
        while first < chunks.count, ends[first] <= head {
            chunks[first] = Data()
            first += 1
        }
        if first == chunks.count {
            removeAll()
        } else if first >= 64, first * 2 >= chunks.count {
            chunks.removeFirst(first)
            ends.removeFirst(first)
            first = 0
        }
    }

    /// Keeps the first `keep` bytes and drops the rest. `keep` is clamped to `0...count`.
    mutating func truncate(to keep: Int) {
        let newTail = head + min(max(0, keep), count)
        guard newTail < tail else { return }
        if newTail == head {
            removeAll()
            return
        }
        let i = chunkIndex(containing: newTail - 1)
        let start = ends[i] - chunks[i].count
        let c = chunks[i]
        chunks[i] = c[c.startIndex..<c.startIndex + (newTail - start)]
        ends[i] = newTail
        chunks.removeSubrange(i + 1..<chunks.count)
        ends.removeSubrange(i + 1..<ends.count)
        tail = newTail
    }

    mutating func removeAll() {
        chunks = []
        ends = []
        first = 0
        head = 0
        tail = 0
    }

    /// Copies `count` bytes starting at logical `offset` into `destination`.
    /// `offset + count` must not exceed `self.count`.
    func copyBytes(to destination: UnsafeMutablePointer<UInt8>, from offset: Int, count n: Int) {
        precondition(offset >= 0 && n >= 0 && offset + n <= count, "ChunkedByteWindow read out of range")
        guard n > 0 else { return }
        var position = head + offset
        var written = 0
        var i = chunkIndex(containing: position)
        while written < n {
            let c = chunks[i]
            let start = ends[i] - c.count
            let local = position - start
            let take = min(c.count - local, n - written)
            let from = c.startIndex + local
            c.copyBytes(to: UnsafeMutableBufferPointer(start: destination + written, count: take),
                        from: from..<from + take)
            written += take
            position += take
            i += 1
        }
    }

    /// The first `n` bytes, or all of them when fewer are held.
    func prefix(_ n: Int) -> [UInt8] {
        let take = min(max(0, n), count)
        var out = [UInt8](repeating: 0, count: take)
        out.withUnsafeMutableBufferPointer { buffer in
            if let base = buffer.baseAddress { copyBytes(to: base, from: 0, count: take) }
        }
        return out
    }

    /// Index of the chunk holding storage offset `position`, which must be in `head..<tail`.
    private func chunkIndex(containing position: Int) -> Int {
        var lower = first
        var upper = ends.count - 1
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if ends[middle] <= position { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }

    #if DEBUG
    /// Test hook: the storage address of every live chunk, first to last.
    func chunkStorageAddresses() -> [UnsafeRawPointer?] {
        chunks[first...].map { $0.withUnsafeBytes { UnsafeRawPointer($0.baseAddress) } }
    }
    #endif
}
