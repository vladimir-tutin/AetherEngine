import XCTest
@testable import AetherEngine

final class UDFReaderTests: XCTestCase {
    private func image() -> Data {
        // tiny mpls (2s clip 00001) + a recognizable m2ts payload
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        // Incremental += build avoids Swift type-checker timeout on long + chains.
        var pi: [UInt8] = []
        pi += Array("00001".utf8); pi += Array("M2TS".utf8); pi += be16(0); pi.append(0)
        pi += be32(0); pi += be32(90000); pi += [UInt8](repeating: 0, count: 8)
        var playlist: [UInt8] = []
        playlist += be32(0); playlist += be16(0); playlist += be16(1); playlist += be16(0)
        playlist += be16(pi.count); playlist += pi
        var mpls: [UInt8] = []
        mpls += Array("MPLS".utf8); mpls += Array("0200".utf8); mpls += be32(40); mpls += be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count); mpls += playlist
        // m2ts: BDAV-ish: 4-byte TP_extra header then 0x47 sync, repeated; make it 2 sectors
        var m2ts: [UInt8] = []
        for _ in 0..<400 { m2ts += [0x00, 0x00, 0x00, 0x00, 0x47]; m2ts += [UInt8](repeating: 0x10, count: 187) }
        return UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts)
    }

    func test_listsBDMVChildren() throws {
        let udf = try UDFReader(reader: DataIOReader(data: image()))
        let root = try udf.list(path: [])
        XCTAssertTrue(root.contains { $0.name == "BDMV" && $0.isDir })
        let bdmv = try udf.list(path: ["BDMV"])
        let names = bdmv.map(\.name).sorted()
        XCTAssertEqual(names, ["PLAYLIST", "STREAM"])
    }

    func test_resolvesPlaylistFileExtents() throws {
        let udf = try UDFReader(reader: DataIOReader(data: image()))
        let pl = try udf.list(path: ["BDMV", "PLAYLIST"])
        let mpls = try XCTUnwrap(pl.first { $0.name == "00000.mpls" })
        let extents = try udf.extents(of: mpls)
        XCTAssertFalse(extents.isEmpty)
        let reader = ConcatIOReader(base: DataIOReader(data: image()), extents: extents)
        var buf = [UInt8](repeating: 0, count: 4)
        _ = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 4) }
        XCTAssertEqual(buf, Array("MPLS".utf8))
    }

    func test_resolvesFragmentedM2TS() throws {
        let udf = try UDFReader(reader: DataIOReader(data: image()))
        let stream = try udf.list(path: ["BDMV", "STREAM"])
        let m2ts = try XCTUnwrap(stream.first { $0.name == "00001.m2ts" })
        let extents = try udf.extents(of: m2ts)
        XCTAssertEqual(extents.count, 2) // fragmented: two extents
        let reader = ConcatIOReader(base: DataIOReader(data: image()), extents: extents)
        var buf = [UInt8](repeating: 0, count: 5)
        _ = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 5) }
        XCTAssertEqual(buf, [0x00,0x00,0x00,0x00,0x47]) // first TP_extra + sync
    }

    func test_resolvesM2TSViaAEDContinuation() throws {
        // Defensive: the second m2ts extent sits behind a type-3 allocation-extent
        // continuation (AED, tag 258), the overflow path UDF uses when a file's
        // descriptors do not fit inline in the (E)FE. The reader must follow the chain.
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        var pi: [UInt8] = []
        pi += Array("00001".utf8); pi += Array("M2TS".utf8); pi += be16(0); pi.append(0)
        pi += be32(0); pi += be32(90000); pi += [UInt8](repeating: 0, count: 8)
        var playlist: [UInt8] = []
        playlist += be32(0); playlist += be16(0); playlist += be16(1); playlist += be16(0)
        playlist += be16(pi.count); playlist += pi
        var mpls: [UInt8] = []
        mpls += Array("MPLS".utf8); mpls += Array("0200".utf8); mpls += be32(40); mpls += be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count); mpls += playlist
        var m2ts: [UInt8] = []
        for _ in 0..<400 { m2ts += [0x00, 0x00, 0x00, 0x00, 0x47]; m2ts += [UInt8](repeating: 0x10, count: 187) }
        let data = UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts, m2tsViaAED: true)

        let udf = try UDFReader(reader: DataIOReader(data: data))
        let stream = try udf.list(path: ["BDMV", "STREAM"])
        let entry = try XCTUnwrap(stream.first { $0.name == "00001.m2ts" })
        let extents = try udf.extents(of: entry)
        XCTAssertEqual(extents.count, 2)  // one inline + one reached through the AED
        // Without continuation following, the old reader appended the type-3 pointer as a
        // bogus 1-sector extent, so the total would be ext1 + 2048, not the full payload.
        XCTAssertEqual(extents.reduce(0) { $0 + Int($1.length) }, m2ts.count)
        let reader = ConcatIOReader(base: DataIOReader(data: data), extents: extents)
        var buf = [UInt8](repeating: 0, count: 5)
        _ = buf.withUnsafeMutableBufferPointer { reader.read($0.baseAddress, size: 5) }
        XCTAssertEqual(buf, [0x00,0x00,0x00,0x00,0x47])
    }

    func test_rejectsNonUDF() {
        XCTAssertThrowsError(try UDFReader(reader: DataIOReader(data: Data(repeating: 0, count: 600*1024)))) { err in
            guard case DiscError.notUDF = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    // audit NET-4: `off + len <= lvd.count` only bounds the map's OWN declared length; a type 1 or
    // type 2 map short enough to pass that check but too short to hold the fields the reader
    // indexes (off+4, off+38..43) used to read past the sector buffer and trap once a run of
    // padding maps pushed `off` near the sector's end.
    func test_craftedPartitionMapDoesNotReadPastSector() {
        var data = [UInt8](image())
        let lvdBase = 258 * 2048
        var maps: [UInt8] = []
        for _ in 0..<6 { maps += [0, 255] + [UInt8](repeating: 0, count: 253) } // type 0, len 255 (padding)
        maps += [0, 74] + [UInt8](repeating: 0, count: 72)                     // type 0, len 74 (padding)
        maps += [1, 2]                                                         // type 1, len 2: too short for off+4
        XCTAssertLessThanOrEqual(440 + maps.count, 2048, "the crafted layout must still fit the sector")
        for (i, b) in maps.enumerated() { data[lvdBase + 440 + i] = b }
        for (i, b) in UDFFixture.le32(maps.count).enumerated() { data[lvdBase + 264 + i] = b } // MapTableLength
        for (i, b) in UDFFixture.le32(8).enumerated() { data[lvdBase + 268 + i] = b }          // NumberOfPartitionMaps
        XCTAssertThrowsError(try UDFReader(reader: DataIOReader(data: Data(data))))
    }

    // audit NET-11: `vdsLen` is an untrusted u32 from the anchor; unclamped it can drive up to
    // ~2 million sequential sector reads before parsing fails. The scan must stay capped near the
    // real Volume Descriptor Sequence's size (ECMA-167: 16 sectors) instead of trusting the anchor.
    func test_hostileAnchorLengthCapsTheVDSScan() {
        let mock = SparseSectorReader()
        var avdp = [UInt8](repeating: 0, count: 2048)
        UDFFixture.tag(2, location: 256, into: &avdp)
        avdp[16..<24] = ArraySlice(UDFFixture.extentAD(lenBytes: 0xFFFF_FFFF, location: 300))
        mock.setSector(256, avdp)
        XCTAssertThrowsError(try UDFReader(reader: mock))
        XCTAssertTrue((200...300).contains(mock.sectorReads),
                      "expected the VDS scan capped near 256 sectors, got \(mock.sectorReads)")
    }

    func test_truncatedImageThrowsNotTrap() throws {
        // UDF image truncated before VDS (AVDP present at sector 256, VDS cut off): must throw, not trap.
        func be16(_ v: Int) -> [UInt8] { [UInt8((v>>8)&0xff), UInt8(v&0xff)] }
        func be32(_ v: Int) -> [UInt8] { [UInt8((v>>24)&0xff),UInt8((v>>16)&0xff),UInt8((v>>8)&0xff),UInt8(v&0xff)] }
        var pi: [UInt8] = []
        pi += Array("00001".utf8); pi += Array("M2TS".utf8); pi += be16(0); pi.append(0)
        pi += be32(0); pi += be32(90000); pi += [UInt8](repeating: 0, count: 8)
        var playlist: [UInt8] = []
        playlist += be32(0); playlist += be16(0); playlist += be16(1); playlist += be16(0)
        playlist += be16(pi.count); playlist += pi
        var mpls: [UInt8] = []
        mpls += Array("MPLS".utf8); mpls += Array("0200".utf8); mpls += be32(40); mpls += be32(0)
        mpls += [UInt8](repeating: 0, count: 40 - mpls.count); mpls += playlist
        var m2ts: [UInt8] = []
        for _ in 0..<400 { m2ts += [0x00, 0x00, 0x00, 0x00, 0x47]; m2ts += [UInt8](repeating: 0x10, count: 187) }
        let full = UDFFixture.make(mplsBytes: mpls, m2tsBytes: m2ts)
        let truncated = full.prefix(258 * 2048) // AVDP present (sector 256), VDS cut off
        XCTAssertThrowsError(try {
            let udf = try UDFReader(reader: DataIOReader(data: Data(truncated)))
            _ = try udf.list(path: ["BDMV"])
        }())
    }
}

/// Answers every sector as zero-filled unless a specific one was set, and counts reads: proves a
/// scan is bounded rather than trusting an untrusted extent length (audit NET-11).
private final class SparseSectorReader: IOReader, @unchecked Sendable {
    private let ss = 2048
    private var sectors: [Int: [UInt8]] = [:]
    private var position: Int64 = 0
    private let lock = NSLock()
    private var _sectorReads = 0
    var sectorReads: Int { lock.lock(); defer { lock.unlock() }; return _sectorReads }

    func setSector(_ index: Int, _ bytes: [UInt8]) { sectors[index] = bytes }

    func read(_ buffer: UnsafeMutablePointer<UInt8>?, size: Int32) -> Int32 {
        guard let buffer, size > 0 else { return -1 }
        lock.lock(); defer { lock.unlock() }
        let sector = Int(position / Int64(ss))
        let bytes = sectors[sector] ?? [UInt8](repeating: 0, count: ss)
        let n = min(Int(size), bytes.count)
        bytes.withUnsafeBufferPointer { buffer.update(from: $0.baseAddress!, count: n) }
        position += Int64(n)
        _sectorReads += 1
        return Int32(n)
    }

    func seek(offset: Int64, whence: Int32) -> Int64 {
        if whence == 65536 { return Int64.max / 2 }
        guard whence == SEEK_SET else { return -1 }
        position = offset
        return position
    }

    func close() {}
}
