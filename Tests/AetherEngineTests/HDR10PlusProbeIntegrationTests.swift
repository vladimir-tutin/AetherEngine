import Testing
import Foundation
@testable import AetherEngine

/// End-to-end tests for `AetherEngine.probe(url:detecting: .hdr10Plus)` against two fixtures that differ in
/// exactly one thing: the presence of an ITU-T T.35 SEI carrying ST 2094-40 metadata.
///
/// Both are 64x64 HEVC Main 10, PQ / BT.2020, two frames, generated locally (`Scripts/make-hdr10plus-fixture.py`)
/// and embedded here because they are ~1 KB each. The positive one's payload is a real HDR10+ payload built to
/// `libavutil/hdr_dynamic_metadata.c`'s bit layout, and `ffprobe -show_frames` on it reports
/// "HDR Dynamic Metadata SMPTE2094-40 (HDR10+)": FFmpeg's own parser accepting it is what makes this a
/// fixture of the case rather than a byte pattern that resembles it.
///
/// The negative fixture is the same encode WITHOUT the SEI. It is the load-bearing half: a scan that reports
/// HDR10+ for everything would pass every positive test in this file.
@Suite("HDR10+ probe: bounded pre-playback detection against real HEVC fixtures")
struct HDR10PlusProbeIntegrationTests {

    /// 64x64 HEVC Main 10, PQ/BT.2020, 2 frames, each access unit preceded by a prefix SEI (NAL type 39)
    /// carrying a valid ST 2094-40 T.35 payload.
    static let hdr10PlusBase64 = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAAwG1kYXQAAABFTgEEQLUAPAAB
    BABCYloAhNA+gB1MC7gkCA+gKB9AUC7gyE4hkH0CWLuC0PoC+RlDGTiAZE+hLCRkMhLGQfSWK8yD
    hACAAAAADigBr3jrrvv//FtlXy08AAAARU4BBEC1ADwAAQQAQmJaAITQPoAdTAu4JAgPoCgfQFAu
    4MhOIZB9Ali7gtD6AvkZQxk4gGRPoSwkZDISxkH0livMg4QAgAAAABAoAa8J4CQEyH//J2Eew0j8
    AAADw21vb3YAAABsbXZoZAAAAAAAAAAAAAAAAAAAA+gAAADIAAEAAAEAAAAAAAAAAAAAAAABAAAA
    AAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    AAIAAALtdHJhawAAAFx0a2hkAAAAAwAAAAAAAAAAAAAAAQAAAAAAAADIAAAAAAAAAAAAAAAAAAAA
    AAABAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAQAAAAABAAAAAQAAAAAAAJGVkdHMAAAAc
    ZWxzdAAAAAAAAAABAAAAyAAAAAAAAQAAAAACZW1kaWEAAAAgbWRoZAAAAAAAAAAAAAAAAAAST4AA
    A6mAVcQAAAAAAC1oZGxyAAAAAAAAAAB2aWRlAAAAAAAAAAAAAAAAVmlkZW9IYW5kbGVyAAAAAhBt
    aW5mAAAAFHZtaGQAAAABAAAAAAAAAAAAAAAkZGluZgAAABxkcmVmAAAAAAAAAAEAAAAMdXJsIAAA
    AAEAAAHQc3RibAAAAWRzdHNkAAAAAAAAAAEAAAFUaHZjMQAAAAAAAAABAAAAAAAAAAAAAAAAAAAA
    AABAAEAASAAAAEgAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAABj//wAA
    AMdodmNDAQQIAAAAnagAAAAAHvAA/P36+gAADwOgAAIAF0ABDAH//wQIAAADAJ2oAAADAAAeugJA
    ABdAAQwB//8ECAAAAwCdqAAAAwAAHroCQKEAAgArQgEBBAgAAAMAnagAAAMAAB6gIIEE2W6kkyvA
    WoSIBIIAAAMAAgAAAwAUEAArQgEBBAgAAAMAnagAAAMAAB6gIIEE2W6kkyvAWoSIBIIAAAMAAgAA
    AwAUEKIAAgAHRAHBcrAiQAAIRAHBcrAiQAAAAAATY29scm5jbHgACQAQAAkAAAAAEHBhc3AAAAAB
    AAAAAQAAABRidHJ0AAAAAAAAHMAAABzAAAAAGHN0dHMAAAAAAAAAAQAAAAIAAdTAAAAAHHN0c2MA
    AAAAAAAAAQAAAAEAAAACAAAAAQAAABxzdHN6AAAAAAAAAAAAAAACAAAAWwAAAF0AAAAUc3RjbwAA
    AAAAAAABAAAALAAAAGJ1ZHRhAAAAWm1ldGEAAAAAAAAAIWhkbHIAAAAAAAAAAG1kaXJhcHBsAAAA
    AAAAAAAAAAAALWlsc3QAAAAlqXRvbwAAAB1kYXRhAAAAAQAAAABMYXZmNjIuMTIuMTAx
    """

    /// The same encode with no SEI injected: HDR10, no dynamic metadata.
    static let hdr10Base64 = """
    AAAAHGZ0eXBpc29tAAACAGlzb21pc28ybXA0MQAAAAhmcmVlAAAALm1kYXQAAAAOKAGveOuu+//8
    W2VfLTwAAAAQKAGvCeAkBMh//ydhHsNI/AAAA8Ntb292AAAAbG12aGQAAAAAAAAAAAAAAAAAAAPo
    AAAAyAABAAABAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAAAEAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAACAAAC7XRyYWsAAABcdGtoZAAAAAMAAAAAAAAAAAAA
    AAEAAAAAAAAAyAAAAAAAAAAAAAAAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAEAAAAAAAAAAAAAAAAA
    AEAAAAAAQAAAAEAAAAAAACRlZHRzAAAAHGVsc3QAAAAAAAAAAQAAAMgAAAAAAAEAAAAAAmVtZGlh
    AAAAIG1kaGQAAAAAAAAAAAAAAAAAEk+AAAOpgFXEAAAAAAAtaGRscgAAAAAAAAAAdmlkZQAAAAAA
    AAAAAAAAAFZpZGVvSGFuZGxlcgAAAAIQbWluZgAAABR2bWhkAAAAAQAAAAAAAAAAAAAAJGRpbmYA
    AAAcZHJlZgAAAAAAAAABAAAADHVybCAAAAABAAAB0HN0YmwAAAFkc3RzZAAAAAAAAAABAAABVGh2
    YzEAAAAAAAAAAQAAAAAAAAAAAAAAAAAAAAAAQABAAEgAAABIAAAAAAAAAAEAAAAAAAAAAAAAAAAA
    AAAAAAAAAAAAAAAAAAAAAAAAAAAY//8AAADHaHZjQwEECAAAAJ2oAAAAAB7wAPz9+voAAA8DoAAC
    ABdAAQwB//8ECAAAAwCdqAAAAwAAHroCQAAXQAEMAf//BAgAAAMAnagAAAMAAB66AkChAAIAK0IB
    AQQIAAADAJ2oAAADAAAeoCCBBNlupJMrwFqEiASCAAADAAIAAAMAFBAAK0IBAQQIAAADAJ2oAAAD
    AAAeoCCBBNlupJMrwFqEiASCAAADAAIAAAMAFBCiAAIAB0QBwXKwIkAACEQBwXKwIkAAAAAAE2Nv
    bHJuY2x4AAkAEAAJAAAAABBwYXNwAAAAAQAAAAEAAAAUYnRydAAAAAAAAAXwAAAF8AAAABhzdHRz
    AAAAAAAAAAEAAAACAAHUwAAAABxzdHNjAAAAAAAAAAEAAAABAAAAAgAAAAEAAAAcc3RzegAAAAAA
    AAAAAAAAAgAAABIAAAAUAAAAFHN0Y28AAAAAAAAAAQAAACwAAABidWR0YQAAAFptZXRhAAAAAAAA
    ACFoZGxyAAAAAAAAAABtZGlyYXBwbAAAAAAAAAAAAAAAAC1pbHN0AAAAJal0b28AAAAdZGF0YQAA
    AAEAAAAATGF2ZjYyLjEyLjEwMQ==
    """

    private static func writeFixture(_ base64: String, name: String) throws -> URL {
        let cleaned = base64.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: cleaned) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-hdr10plus-\(name)-\(UUID().uuidString).mp4")
        try data.write(to: url)
        return url
    }

    @Test("The base probe does not report HDR10+ on a carrying source, and does not read packets to find out")
    func baseProbeStaysHDR10() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "plus")
        defer { try? FileManager.default.removeItem(at: url) }

        let probe = try AetherEngine.probe(url: url)
        #expect(probe.videoFormat == .hdr10)
        #expect(!probe.carriesHDR10PlusMetadata)
    }

    @Test("Asking for .hdr10Plus finds the T.35 payload and upgrades the label before playback")
    func detectingUpgradesToHDR10Plus() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "plus")
        defer { try? FileManager.default.removeItem(at: url) }

        let probe = try AetherEngine.probe(url: url, detecting: .hdr10Plus)
        #expect(probe.carriesHDR10PlusMetadata)
        #expect(probe.videoFormat == .hdr10Plus)
    }

    @Test("A plain HDR10 source is not upgraded")
    func plainHDR10IsNotUpgraded() throws {
        let url = try Self.writeFixture(Self.hdr10Base64, name: "plain")
        defer { try? FileManager.default.removeItem(at: url) }

        let probe = try AetherEngine.probe(url: url, detecting: .hdr10Plus)
        #expect(!probe.carriesHDR10PlusMetadata)
        #expect(probe.videoFormat == .hdr10)
    }

    @Test("Everything the base probe reports is unchanged by the scan")
    func baseMetadataSurvivesTheScan() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "plus")
        defer { try? FileManager.default.removeItem(at: url) }

        let base = try AetherEngine.probe(url: url)
        let scanned = try AetherEngine.probe(url: url, detecting: .hdr10Plus)
        #expect(scanned.videoCodecName == base.videoCodecName)
        #expect(scanned.videoWidth == base.videoWidth)
        #expect(scanned.videoHeight == base.videoHeight)
        #expect(scanned.durationSeconds == base.durationSeconds)
        #expect(scanned.audioTracks.count == base.audioTracks.count)
        #expect(scanned.subtitleTracks.count == base.subtitleTracks.count)
        #expect(scanned.isDolbyVision == base.isDolbyVision)
    }

    @Test("An empty detail set is exactly the base probe")
    func emptyDetailSetIsTheBaseProbe() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "plus")
        defer { try? FileManager.default.removeItem(at: url) }

        let probe = try AetherEngine.probe(url: url, detecting: [])
        #expect(!probe.carriesHDR10PlusMetadata)
        #expect(probe.videoFormat == .hdr10)
    }

    @Test("A zero packet budget cannot confirm, and leaves the base answer alone")
    func zeroBudgetCannotConfirm() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "plus")
        defer { try? FileManager.default.removeItem(at: url) }

        let probe = try AetherEngine.probe(
            url: url, detecting: .hdr10Plus,
            hdr10PlusDetection: HDR10PlusDetectionOptions(maxPackets: 0))
        #expect(!probe.carriesHDR10PlusMetadata)
        #expect(probe.videoFormat == .hdr10)
    }

    @Test("The scan confirms on the first video packet")
    func confirmsOnFirstPacket() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "plus")
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let outcome = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
            options: HDR10PlusDetectionOptions(maxPackets: 1, maxBytes: 91))
        #expect(outcome.stopReason == .found)
        #expect(outcome.packetsRead == 1)
        #expect(outcome.bytesRead == 91)
    }

    @Test("An oversized first video packet cannot confirm HDR10+", arguments: [Int64(1), 90])
    func oversizedPacketCannotConfirm(maxBytes: Int64) throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "oversized")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let outcome = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
            options: HDR10PlusDetectionOptions(maxBytes: maxBytes))
        #expect(outcome.stopReason == .byteCap)
        #expect(!outcome.carriesHDR10Plus)
        #expect(outcome.packetsRead == 0)
        #expect(outcome.bytesRead == 0)
    }

    @Test("A later carrying packet must fit the remaining byte budget", arguments: [Int64(183), 184])
    func remainingByteBudget(maxBytes: Int64) throws {
        var fixture = try #require(Data(base64Encoded: Self.hdr10PlusBase64, options: .ignoreUnknownCharacters))
        let firstHeader = try #require(fixture.range(of: Data([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04])))
        fixture[firstHeader.lowerBound + 2] = 0x3B // First packet has a different registered provider.
        let url = try Self.writeFixture(fixture.base64EncodedString(), name: "remaining")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let outcome = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
            options: HDR10PlusDetectionOptions(maxBytes: maxBytes))
        #expect(outcome.stopReason == (maxBytes == 184 ? .found : .byteCap))
        #expect(outcome.packetsRead == (maxBytes == 184 ? 2 : 1))
        #expect(outcome.bytesRead == (maxBytes == 184 ? 184 : 91))
    }

    @Test("A read that returns at the deadline is rejected before metadata inspection")
    func deadlineAfterRead() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "read-deadline")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        var clockReads = 0
        let outcome = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
            options: HDR10PlusDetectionOptions(timeBudget: 1),
            now: {
                defer { clockReads += 1 }
                return clockReads < 2 ? 0 : 1_000_000_000
            })
        #expect(outcome.stopReason == .timeCap)
        #expect(outcome.packetsRead == 0)
        #expect(outcome.bytesRead == 0)
        #expect(clockReads == 3)
    }

    /// The budget bounds what the pass SPENDS, not what it may report. A confirmation is already paid
    /// for by the time the clock is read again, and withholding it hands the caller a `false` it cannot
    /// tell apart from a source that carries no HDR10+ at all.
    @Test("Metadata found as the deadline passes is still published")
    func deadlineAfterScan() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "scan-deadline")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        var clockReads = 0
        let outcome = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
            options: HDR10PlusDetectionOptions(timeBudget: 1),
            now: {
                defer { clockReads += 1 }
                // The cap check and the post-read check still fall inside the budget; the read that
                // used to follow the scan, and retract the finding, is the one that would be over it.
                return clockReads < 3 ? 0 : 1_000_000_000
            })
        #expect(outcome.stopReason == .found)
        #expect(outcome.carriesHDR10Plus)
        #expect(outcome.packetsRead == 1)
        #expect(outcome.bytesRead == 91)
        // The start stamp, the cap check and the post-read check. The fourth read, the one that was
        // over budget and used to retract the finding, is never taken.
        #expect(clockReads == 3)
    }

    @Test("A read returning EOF after the deadline still reports the time cap")
    func deadlineAtEOF() throws {
        let url = try Self.writeFixture(Self.hdr10Base64, name: "eof-deadline")
        defer { try? FileManager.default.removeItem(at: url) }
        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        var clockReads = 0
        let outcome = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex,
            options: HDR10PlusDetectionOptions(timeBudget: 1),
            now: {
                defer { clockReads += 1 }
                return clockReads < 8 ? 0 : 1_000_000_000
            })
        #expect(outcome.stopReason == .timeCap)
        #expect(outcome.packetsRead == 2)
        #expect(outcome.bytesRead == 38)
        #expect(clockReads == 9)
    }

    @Test("A source scanned to its end without a hit reports EOF, not a cap")
    func exhaustedSourceReportsEOF() throws {
        let url = try Self.writeFixture(Self.hdr10Base64, name: "plain")
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let outcome = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: demuxer.videoStreamIndex, options: HDR10PlusDetectionOptions())
        #expect(outcome.stopReason == .demuxEOF)
        #expect(!outcome.carriesHDR10Plus)
    }

    @Test("A source with no video track degrades to .noVideoTrack rather than throwing")
    func noVideoTrackDegrades() throws {
        let url = try Self.writeFixture(Self.hdr10Base64, name: "plain")
        defer { try? FileManager.default.removeItem(at: url) }

        let demuxer = Demuxer()
        try demuxer.open(url: url)
        defer { demuxer.close() }
        let outcome = AetherEngine.detectHDR10Plus(
            demuxer: demuxer, videoIndex: -1, options: HDR10PlusDetectionOptions())
        #expect(outcome.stopReason == .noVideoTrack)
    }

    @Test("A custom byte source is scanned like a URL one (the SMB / WebDAV shape)")
    func customReaderIsScanned() throws {
        let url = try Self.writeFixture(Self.hdr10PlusBase64, name: "plus")
        defer { try? FileManager.default.removeItem(at: url) }

        guard let reader = FileIOReader(url: url) else {
            Issue.record("FileIOReader could not open the fixture")
            return
        }
        defer { reader.close() }
        let probe = try AetherEngine.probe(
            source: .custom(reader, formatHint: "mp4"), detecting: .hdr10Plus)
        #expect(probe.carriesHDR10PlusMetadata)
        #expect(probe.videoFormat == .hdr10Plus)
    }

    @Test("Combined HDR/Atmos probing skips audio work for no-audio and non-EAC3 sources",
          arguments: [0, 1, 2])
    func combinedDetailsPreserveHDRIndependence(fixtureIndex: Int) throws {
        let fixtures = [Self.hdr10PlusBase64, Self.hdr10Base64, AtmosDetectionProbeIntegrationTests.aacBase64]
        let formats: [VideoFormat] = [.hdr10Plus, .hdr10, .sdr]
        let data = try #require(Data(base64Encoded: fixtures[fixtureIndex], options: .ignoreUnknownCharacters))
        let hdrReader = ProbeRecordingReader(data: data)
        let combinedReader = ProbeRecordingReader(data: data)
        let hdrOnly = try AetherEngine.probe(
            source: .custom(hdrReader, formatHint: "mp4"), detecting: .hdr10Plus)
        let combined = try AetherEngine.probe(
            source: .custom(combinedReader, formatHint: "mp4"), detecting: [.hdr10Plus, .atmos])

        #expect(combined.videoFormat == formats[fixtureIndex])
        #expect(combined.videoFormat == hdrOnly.videoFormat)
        #expect(combined.carriesHDR10PlusMetadata == (fixtureIndex == 0))
        #expect(combined.carriesHDR10PlusMetadata == hdrOnly.carriesHDR10PlusMetadata)
        #expect(combined.audioTracks == hdrOnly.audioTracks)
        #expect(combined.audioTracks.count == (fixtureIndex == 2 ? 1 : 0))
        #expect(combined.audioTracks.allSatisfy { !$0.isAtmos })
        #expect(combinedReader.seeks.map(\.offset) == hdrReader.seeks.map(\.offset))
        #expect(combinedReader.seeks.map(\.whence) == hdrReader.seeks.map(\.whence))
        #expect(combinedReader.reads.map(\.offset) == hdrReader.reads.map(\.offset))
        #expect(combinedReader.bytesRead == hdrReader.bytesRead)
    }
}
