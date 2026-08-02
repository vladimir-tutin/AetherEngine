import Testing
import Foundation
@testable import AetherEngine

/// Time-aware source buffer policy.
///
/// The defect: the persistent reader's forward buffer was bounded by FIXED BYTES (suspend above
/// 16 MB, resume below 8 MB). Apple TV field capture on a 25.2 Mbps direct-play MKV showed 8 MB =
/// 2.54 s of media, the transfer parked ~97% of wall clock, and two reads blocking 3.003 s and
/// 3.810 s with `reconnects=0 connect=0ms lockWait=0ms unaccounted=0ms` — a healthy connection
/// that simply did not resume at rate before the 2.54 s cushion ran out.
struct SourceBufferPolicyTests {

    private let rate25Mbps = 25.2 * 1_000_000 / 8   // 3.15 MB/s
    private let rate80Mbps = 80.0 * 1_000_000 / 8   // 10 MB/s

    @Test("disabled resolves to the stock byte watermarks, exactly")
    func disabledIsStock() {
        let resolved = AetherSourceBufferPolicy.stock.resolve(bytesPerSecond: rate25Mbps)
        #expect(resolved == .stock)
        #expect(resolved.lowWaterBytes == 8 * 1024 * 1024)
        #expect(resolved.highWaterBytes == 16 * 1024 * 1024)
        #expect(resolved.hardCapBytes == 48 * 1024 * 1024)
        #expect(resolved.reason == "stock")
    }

    @Test("an unknown media rate cannot enable the time policy")
    func unknownRateIsStock() {
        var policy = AetherSourceBufferPolicy.timeAware
        policy.enabled = true
        #expect(policy.resolve(bytesPerSecond: 0) == .stock)
        #expect(policy.resolve(bytesPerSecond: -1) == .stock)
    }

    @Test("15s/30s at 25.2 Mbps buys ~6x the cushion the stock policy had")
    func timeTargetsAt25Mbps() {
        let resolved = AetherSourceBufferPolicy.timeAware.resolve(bytesPerSecond: rate25Mbps)
        #expect(resolved.reason == "time")
        // The number that mattered in the field: seconds of media at the RESUME threshold.
        #expect(abs(resolved.lowWaterSeconds - 15) < 0.1)
        #expect(abs(resolved.highWaterSeconds - 30) < 0.1)
        // 3.15 MB/s * 15 s = 47.25 MB (45.1 MiB), * 30 s = 94.5 MB (90.1 MiB).
        #expect(resolved.lowWaterBytes > 44 * 1024 * 1024)
        #expect(resolved.highWaterBytes > 88 * 1024 * 1024)
        // The stock 8 MB low water was 2.54 s; anything at/below that is the defect.
        #expect(Double(AetherSourceBufferStock.lowWaterBytes) / rate25Mbps < 2.6)
    }

    @Test("the memory ceiling wins over the duration target and says so")
    func memoryCeilingClamps() {
        // 30 s at 80 Mbps is 300 MB, which this device class cannot afford.
        let resolved = AetherSourceBufferPolicy.timeAware.resolve(bytesPerSecond: rate80Mbps)
        #expect(resolved.reason == "time-clamped-memory")
        #expect(resolved.highWaterBytes == 128 * 1024 * 1024)
        // The low:high ratio survives the clamp, so the resume threshold does not collapse onto
        // the high water (which would resume-and-re-suspend on every delivery).
        #expect(resolved.lowWaterBytes < resolved.highWaterBytes)
        #expect(abs(Double(resolved.lowWaterBytes) / Double(resolved.highWaterBytes) - 0.5) < 0.02)
        // Even clamped, it is still far better than stock: >12 s instead of 0.8 s.
        #expect(resolved.lowWaterSeconds > 6)
        #expect(Double(AetherSourceBufferStock.lowWaterBytes) / rate80Mbps < 0.9)
    }

    @Test("the policy can only grow the cushion, never shrink it below stock")
    func neverRegressesBelowStock() {
        var policy = AetherSourceBufferPolicy.timeAware
        policy.lowWaterSeconds = 0.1
        policy.highWaterSeconds = 0.2
        // A very low-bitrate source whose duration targets land under the stock bytes.
        let resolved = policy.resolve(bytesPerSecond: 100_000)
        #expect(resolved.lowWaterBytes >= AetherSourceBufferStock.lowWaterBytes)
        #expect(resolved.highWaterBytes >= AetherSourceBufferStock.highWaterBytes)
        #expect(resolved.reason == "time-clamped-floor")
    }

    @Test("hysteresis gap and ordering invariants hold for every input")
    func invariantsHold() {
        let rates: [Double] = [50_000, 500_000, rate25Mbps, rate80Mbps, 40 * 1024 * 1024]
        let lows: [Double] = [1, 5, 15, 40]
        let highs: [Double] = [2, 10, 30, 60]
        let ceilings = [8 * 1024 * 1024, 32 * 1024 * 1024, 128 * 1024 * 1024, 512 * 1024 * 1024]
        for rate in rates {
            for low in lows {
                for high in highs where high > low {
                    for ceiling in ceilings {
                        var policy = AetherSourceBufferPolicy.timeAware
                        policy.lowWaterSeconds = low
                        policy.highWaterSeconds = high
                        policy.maxWindowBytes = ceiling
                        let r = policy.resolve(bytesPerSecond: rate)
                        // A low >= high deadlocks the reader: it would resume and immediately
                        // re-suspend on every single delivery.
                        #expect(r.lowWaterBytes < r.highWaterBytes,
                                "low must stay below high (rate=\(rate) low=\(low) high=\(high) ceiling=\(ceiling))")
                        // The hard cap must sit clear of the high water or a healthy fill trips
                        // the #220 "transport ignored suspend()" path on every cycle.
                        #expect(r.hardCapBytes > r.highWaterBytes,
                                "hard cap must exceed high water (rate=\(rate) ceiling=\(ceiling))")
                        #expect(r.lowWaterBytes >= AetherSourceBufferStock.lowWaterBytes)
                        #expect(r.lookbackBytes > 0)
                        #expect(r.seekKeepForwardBytes >= AetherSourceBufferStock.seekKeepForwardBytes)
                    }
                }
            }
        }
    }

    @Test("the memory breaker shrinks the applied watermarks but never below stock")
    func breakerShrinks() {
        let policy = AetherSourceBufferPolicy.timeAware
        let full = policy.resolve(bytesPerSecond: rate25Mbps, shrinkFactor: 1)
        let half = policy.resolve(bytesPerSecond: rate25Mbps, shrinkFactor: 0.5)
        let quarter = policy.resolve(bytesPerSecond: rate25Mbps, shrinkFactor: 0.25)
        #expect(half.highWaterBytes < full.highWaterBytes)
        #expect(quarter.highWaterBytes < half.highWaterBytes)
        #expect(half.reason == "breaker")
        #expect(quarter.lowWaterBytes >= AetherSourceBufferStock.lowWaterBytes)
        #expect(quarter.highWaterBytes >= AetherSourceBufferStock.highWaterBytes)
        #expect(quarter.lowWaterBytes < quarter.highWaterBytes)
    }

    @Test("a degenerate ceiling below the stock floor still yields a usable band")
    func degenerateCeiling() {
        var policy = AetherSourceBufferPolicy.timeAware
        policy.maxWindowBytes = 1024        // absurd host value
        let r = policy.resolve(bytesPerSecond: rate25Mbps)
        #expect(r.lowWaterBytes < r.highWaterBytes)
        #expect(r.hardCapBytes > r.highWaterBytes)
        #expect(r.lowWaterBytes >= AetherSourceBufferStock.lowWaterBytes)
    }

    @Test("the applied description reports applied values, not requested ones")
    func appliedDescriptionIsApplied() {
        let resolved = AetherSourceBufferPolicy.timeAware.resolve(bytesPerSecond: rate80Mbps)
        AetherSourceBuffer.recordApplied(resolved)
        let previous = AetherSourceBuffer.policy
        AetherSourceBuffer.policy = .timeAware
        defer { AetherSourceBuffer.policy = previous }
        let text = AetherSourceBuffer.appliedDescription()
        // 30 s was REQUESTED; 128 MB is what the ceiling allowed. The log must show the latter.
        #expect(text.contains("highMB=128"))
        #expect(text.contains("reason=time-clamped-memory"))
    }
}

/// The block ring exists so a time-based window is affordable. The stock contiguous window trims
/// with `subdata`, which reallocates and copies the retained remainder: ~93 MB per 4 MB consumed
/// at a 95 MB window, and two ~93 MB live blocks during the copy — the allocation shape #220
/// recorded (`bigExact=160301056,135544832`) right before a jetsam scare.
struct SourceWindowStorageTests {

    private func bytes(_ n: Int, seed: UInt8 = 0) -> Data {
        Data((0..<n).map { UInt8(truncatingIfNeeded: $0 &+ Int(seed)) })
    }

    private func readAll(_ w: SourceWindowStorage, from: Int, count n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        out.withUnsafeMutableBufferPointer { buf in
            w.copyOut(from: from, into: buf.baseAddress!, count: n)
        }
        return out
    }

    @Test("a read spanning several blocks is stitched correctly")
    func crossBlockRead() {
        let ring = BlockRingSourceWindow(blockSize: 64 * 1024)
        let payload = bytes(200 * 1024)
        ring.append(payload)
        #expect(ring.count == payload.count)
        #expect(readAll(ring, from: 0, count: payload.count) == Array(payload))
        // A read that starts mid-block and ends mid-block, three blocks later.
        #expect(readAll(ring, from: 60_000, count: 140_000) == Array(payload[60_000..<200_000]))
    }

    @Test("append in many small deliveries matches one large delivery")
    func chunkedAppendMatches() {
        let a = BlockRingSourceWindow(blockSize: 64 * 1024)
        let b = BlockRingSourceWindow(blockSize: 64 * 1024)
        let payload = bytes(300 * 1024)
        a.append(payload)
        var offset = 0
        // 64 KB is the delivery size the field capture actually observed from the origin.
        while offset < payload.count {
            let n = Swift.min(64 * 1024, payload.count - offset)
            b.append(payload.subdata(in: offset..<(offset + n)))
            offset += n
        }
        #expect(a.count == b.count)
        #expect(readAll(a, from: 0, count: a.count) == readAll(b, from: 0, count: b.count))
    }

    @Test("trimFront drops whole blocks and keeps the partial head addressable")
    func trimSemantics() {
        let ring = BlockRingSourceWindow(blockSize: 64 * 1024)
        let payload = bytes(256 * 1024)
        ring.append(payload)
        // Partial trim inside the first block: nothing is released, offsets rebase.
        ring.trimFront(1000)
        #expect(ring.count == payload.count - 1000)
        #expect(readAll(ring, from: 0, count: 500) == Array(payload[1000..<1500]))
        // Cross a block boundary: the head block is released.
        ring.trimFront(70 * 1024)
        let consumed = 1000 + 70 * 1024
        #expect(ring.count == payload.count - consumed)
        #expect(readAll(ring, from: 0, count: 4096) == Array(payload[consumed..<(consumed + 4096)]))
        // Appending after a trim must land at the tail, not at a released block.
        let more = bytes(10_000, seed: 7)
        ring.append(more)
        #expect(readAll(ring, from: ring.count - 10_000, count: 10_000) == Array(more))
    }

    @Test("ring and contiguous windows are observationally identical")
    func ringMatchesContiguous() {
        let ring = BlockRingSourceWindow(blockSize: 64 * 1024)
        let flat = ContiguousSourceWindow()
        var rng = SystemRandomNumberGenerator()
        var seed: UInt8 = 0
        var cursor = 0
        for step in 0..<200 {
            let n = Int.random(in: 1...(96 * 1024), using: &rng)
            seed = seed &+ 1
            let payload = bytes(n, seed: seed)
            ring.append(payload)
            flat.append(payload)
            #expect(ring.count == flat.count, "count diverged at step \(step)")
            if ring.count > 0 {
                let from = Int.random(in: 0..<ring.count, using: &rng)
                let len = Int.random(in: 1...(ring.count - from), using: &rng)
                #expect(readAll(ring, from: from, count: len) == readAll(flat, from: from, count: len),
                        "payload diverged at step \(step)")
            }
            // Trim on the same cadence the reader does: lookback + batch behind the cursor.
            if step % 3 == 0, ring.count > 8192 {
                let drop = Int.random(in: 1...(ring.count / 2), using: &rng)
                ring.trimFront(drop)
                flat.trimFront(drop)
                cursor += drop
                #expect(ring.count == flat.count, "count diverged after trim at step \(step)")
            }
        }
        #expect(cursor >= 0)
        #expect(ring.prefixBytes(16) == flat.prefixBytes(16))
    }

    @Test("removeAll returns the ring to empty and it refills cleanly")
    func removeAllResets() {
        let ring = BlockRingSourceWindow(blockSize: 64 * 1024)
        ring.append(bytes(150 * 1024))
        ring.trimFront(100 * 1024)
        ring.removeAll()
        #expect(ring.count == 0)
        #expect(ring.prefixBytes(4) == [])
        let payload = bytes(1000, seed: 3)
        ring.append(payload)
        #expect(readAll(ring, from: 0, count: 1000) == Array(payload))
    }

    @Test("an absurd host block size is clamped instead of exploding the block count")
    func blockSizeIsClamped() {
        let tiny = BlockRingSourceWindow(blockSize: 1)
        tiny.append(bytes(300_000))
        #expect(tiny.count == 300_000)
        #expect(tiny.residentBytes <= 300_000 + 64 * 1024)
        let huge = BlockRingSourceWindow(blockSize: 1 << 30)
        huge.append(bytes(1000))
        #expect(huge.count == 1000)
        #expect(huge.residentBytes <= 16 * 1024 * 1024)
    }
}
