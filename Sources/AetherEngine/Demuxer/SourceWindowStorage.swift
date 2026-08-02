import Foundation

/// Storage for `AVIOReader`'s persistent sliding window, behind a protocol so the time-aware
/// buffer policy can install a block ring while `enabled == false` keeps the stock contiguous
/// `Data` byte-for-byte.
///
/// Offsets are WINDOW-RELATIVE. The reader owns `winStart` and the absolute file position; this
/// type only knows "bytes 0..<count of the current window".
protocol SourceWindowStorage: AnyObject {
    var count: Int { get }
    /// Append newly delivered bytes at the tail.
    func append(_ data: Data)
    /// Copy `n` bytes starting at window offset `offset` into `dst`. Caller guarantees the range.
    func copyOut(from offset: Int, into dst: UnsafeMutablePointer<UInt8>, count n: Int)
    /// Drop `n` bytes from the head. Caller adjusts `winStart` by the same amount.
    func trimFront(_ n: Int)
    /// Drop everything (new connection / generation).
    func removeAll()
    /// Leading bytes, for the open-time container sniff. Never called mid-playback.
    func prefixBytes(_ n: Int) -> [UInt8]
}

/// The stock window: one contiguous `Data`, trimmed with `subdata`.
///
/// `subdata` (not `removeFirst`) is load-bearing and predates this file: `removeFirst` only moves
/// the slice's lower bound while `count.setter` in the append path keeps growing the backing
/// store, which leaked ~14 MB/s on an 80 Mbps remux (AetherEngine#31). Keep the semantics exactly.
///
/// The cost this type cannot escape is that every trim reallocates and copies the REMAINDER. At
/// the stock 16 MB high water that is a ~14 MB copy per 4 MB consumed, which is affordable. At a
/// 95 MB time-based window it is a ~93 MB alloc+copy every 4 MB — roughly 73 MB/s of memcpy plus
/// two ~93 MB live blocks during the copy, which is the allocation shape #220 recorded
/// (`bigExact=160301056,135544832`) right before a jetsam scare. Hence `BlockRingSourceWindow`.
final class ContiguousSourceWindow: SourceWindowStorage {
    private var data = Data()

    var count: Int { data.count }

    func append(_ incoming: Data) {
        let base = data.count
        data.count = base + incoming.count
        data.withUnsafeMutableBytes { dst in
            incoming.withUnsafeBytes { src in
                if let d = dst.baseAddress, let s = src.baseAddress {
                    (d + base).copyMemory(from: s, byteCount: incoming.count)
                }
            }
        }
    }

    func copyOut(from offset: Int, into dst: UnsafeMutablePointer<UInt8>, count n: Int) {
        guard n > 0 else { return }
        data.withUnsafeBytes { raw in
            let src = raw.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            dst.update(from: src, count: n)
        }
    }

    func trimFront(_ n: Int) {
        guard n > 0, n <= data.count else { return }
        data = data.subdata(in: n..<data.count)
    }

    func removeAll() { data = Data() }

    func prefixBytes(_ n: Int) -> [UInt8] {
        let k = Swift.min(n, data.count)
        return k > 0 ? Array(data.prefix(k)) : []
    }
}

/// Fixed-size block ring. Appends fill the tail block, trims drop whole head blocks.
///
/// This is what makes a time-based window affordable:
///   - No reallocation of retained bytes, ever. The largest single allocation is `blockSize`
///     (default 1 MB), so a 95 MB window never asks the allocator for a 95 MB contiguous block
///     and never holds two of them at once.
///   - `trimFront` is O(blocks dropped), not O(bytes retained).
///   - Peak resident is `window + at most one partially-filled block`, so the "cap sets the peak
///     at roughly twice its own value" problem from #220 does not apply here.
///
/// Reads spanning a block boundary are stitched by `copyOut`; a 256 KB AVIO read touches at most
/// two 1 MB blocks.
final class BlockRingSourceWindow: SourceWindowStorage {

    private let blockSize: Int
    /// Each element is exactly `blockSize` bytes of allocated storage.
    private var blocks: [[UInt8]] = []
    /// Read offset into `blocks[0]`; bytes before it have been trimmed.
    private var headOffset = 0
    /// Bytes used in the LAST block. Meaningless when `blocks` is empty.
    private var tailUsed = 0

    private(set) var count = 0

    init(blockSize: Int) {
        // Guard the host against a nonsensical runtime value: a tiny block would make `blocks`
        // enormous and turn `removeFirst` into the hot path it was meant to avoid.
        self.blockSize = max(64 * 1024, min(16 * 1024 * 1024, blockSize))
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            var written = 0
            let total = data.count
            while written < total {
                if blocks.isEmpty || tailUsed == blockSize {
                    blocks.append([UInt8](repeating: 0, count: blockSize))
                    tailUsed = 0
                }
                let room = blockSize - tailUsed
                let chunk = Swift.min(room, total - written)
                let dstIndex = blocks.count - 1
                blocks[dstIndex].withUnsafeMutableBufferPointer { dst in
                    dst.baseAddress!.advanced(by: tailUsed)
                        .update(from: base.advanced(by: written), count: chunk)
                }
                tailUsed += chunk
                written += chunk
            }
        }
        count += data.count
    }

    func copyOut(from offset: Int, into dst: UnsafeMutablePointer<UInt8>, count n: Int) {
        guard n > 0 else { return }
        var remaining = n
        var written = 0
        // `headOffset` is the ring's own consumed prefix; window offset 0 lives there.
        var absolute = offset + headOffset
        var blockIndex = absolute / blockSize
        var inBlock = absolute % blockSize
        while remaining > 0, blockIndex < blocks.count {
            let available = (blockIndex == blocks.count - 1 ? tailUsed : blockSize) - inBlock
            if available <= 0 { break }
            let chunk = Swift.min(available, remaining)
            blocks[blockIndex].withUnsafeBufferPointer { src in
                dst.advanced(by: written)
                    .update(from: src.baseAddress!.advanced(by: inBlock), count: chunk)
            }
            written += chunk
            remaining -= chunk
            absolute += chunk
            blockIndex += 1
            inBlock = 0
        }
    }

    func trimFront(_ n: Int) {
        guard n > 0, n <= count else { return }
        headOffset += n
        count -= n
        // Release whole blocks only; a partial head stays resident until its block is fully
        // consumed, which is exactly the cheap behaviour this type exists for.
        let whole = headOffset / blockSize
        if whole > 0 {
            blocks.removeFirst(Swift.min(whole, blocks.count))
            headOffset -= whole * blockSize
        }
        if blocks.isEmpty {
            headOffset = 0
            tailUsed = 0
            count = 0
        }
    }

    func removeAll() {
        blocks.removeAll(keepingCapacity: false)
        headOffset = 0
        tailUsed = 0
        count = 0
    }

    func prefixBytes(_ n: Int) -> [UInt8] {
        let k = Swift.min(n, count)
        guard k > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: k)
        out.withUnsafeMutableBufferPointer { buf in
            copyOut(from: 0, into: buf.baseAddress!, count: k)
        }
        return out
    }

    /// Resident allocation, which is what the memory ceiling actually has to respect
    /// (`count` excludes the trimmed-but-not-yet-released head).
    var residentBytes: Int { blocks.count * blockSize }
}
