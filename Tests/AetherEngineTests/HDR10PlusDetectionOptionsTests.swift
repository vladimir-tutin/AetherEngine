import Testing
import Foundation
@testable import AetherEngine

/// Stop-condition and outcome semantics for the bounded HDR10+ carriage scan. Pure: no demuxer, no media.
@Suite("HDR10PlusDetection: bounds and outcome semantics")
struct HDR10PlusDetectionOptionsTests {

    @Test("Defaults are finite and non-zero on all three axes")
    func defaultsAreFinite() {
        let options = HDR10PlusDetectionOptions()
        #expect(options.maxPackets > 0)
        #expect(options.maxBytes > 0)
        #expect(options.timeBudget > 0)
    }

    @Test("Within every budget no cap is reported")
    func withinBudgetsNoCap() {
        let options = HDR10PlusDetectionOptions(maxPackets: 10, maxBytes: 1000, timeBudget: 1)
        #expect(AetherEngine.hdr10PlusScanCapReached(
            packetsRead: 9, bytesRead: 999, elapsed: 0.9, options: options) == nil)
    }

    @Test("Cap priority is packets, then bytes, then time")
    func capPriority() {
        let options = HDR10PlusDetectionOptions(maxPackets: 10, maxBytes: 1000, timeBudget: 1)
        // All three exceeded at once: the packet cap is the one reported, so a log line names the same
        // reason whichever axis a source happens to also cross.
        #expect(AetherEngine.hdr10PlusScanCapReached(
            packetsRead: 10, bytesRead: 5000, elapsed: 5, options: options) == .packetCap)
        #expect(AetherEngine.hdr10PlusScanCapReached(
            packetsRead: 1, bytesRead: 1000, elapsed: 5, options: options) == .byteCap)
        #expect(AetherEngine.hdr10PlusScanCapReached(
            packetsRead: 1, bytesRead: 1, elapsed: 1, options: options) == .timeCap)
    }

    @Test("Only .found is a positive answer; every other stop reason is inconclusive")
    func onlyFoundIsPositive() {
        let reasons: [HDR10PlusDetectionOutcome.StopReason] = [
            .noVideoTrack, .packetCap, .byteCap, .timeCap, .demuxEOF, .demuxError
        ]
        for reason in reasons {
            let outcome = HDR10PlusDetectionOutcome(stopReason: reason, packetsRead: 3, bytesRead: 300)
            #expect(!outcome.carriesHDR10Plus, "\(reason) must not confirm HDR10+")
        }
        let found = HDR10PlusDetectionOutcome(stopReason: .found, packetsRead: 1, bytesRead: 100)
        #expect(found.carriesHDR10Plus)
    }

    @Test("The foreign-packet fuse saturates instead of trapping on Int.max")
    func fuseSaturates() {
        #expect(AetherEngine.hdr10PlusForeignPacketFuse(maxPackets: Int.max) == Int.max)
        #expect(AetherEngine.hdr10PlusForeignPacketFuse(maxPackets: 32)
                == 32 * AetherEngine.foreignPacketFuseMultiplier)
    }

    @Test("An HDR10 source upgrades to HDR10+, and only that format does")
    func formatUpgradeIsScopedToHDR10() {
        // Mirrors the session's own rule (`handleHDR10PlusDetected`): the payload rides an HDR10 base, so
        // that is the only label the scan moves. A Dolby Vision source keeps saying Dolby Vision even when
        // it carries an HDR10+ base layer (Profile 7, and 8.1 remuxed from it), and the flag carries the
        // evidence instead.
        #expect(AetherEngine.hdr10PlusUpgradedFormat(.hdr10) == .hdr10Plus)
        #expect(AetherEngine.hdr10PlusUpgradedFormat(.hdr10Plus) == .hdr10Plus)
        #expect(AetherEngine.hdr10PlusUpgradedFormat(.dolbyVision) == .dolbyVision)
        #expect(AetherEngine.hdr10PlusUpgradedFormat(.hlg) == .hlg)
        #expect(AetherEngine.hdr10PlusUpgradedFormat(.sdr) == .sdr)
    }

    @Test("ProbeDetail combines and tests as a set")
    func probeDetailSetSemantics() {
        let both: ProbeDetail = [.atmos, .hdr10Plus]
        #expect(both.contains(.atmos))
        #expect(both.contains(.hdr10Plus))
        #expect(!ProbeDetail.atmos.contains(.hdr10Plus))
        #expect(ProbeDetail().isEmpty)
    }

    @Test("HDR10+ enrichment preserves known Atmos and commutes with independent Atmos confirmation")
    func knownAtmosIsPreserved() {
        let tracks = [true, false].enumerated().map { index, knownAtmos in
            TrackInfo(
                id: index + 1, name: "Audio \(index + 1)", codec: "eac3", language: "eng",
                channels: 6, bitrate: 768_000, isDefault: index == 0,
                isForced: false, isHearingImpaired: false, isCommentary: false,
                isAtmos: knownAtmos, assHeader: nil, isExternal: false)
        }
        let base = SourceProbe(
            url: URL(fileURLWithPath: "/synthetic-hdr-atmos.mkv"), durationSeconds: 1,
            videoFormat: .hdr10, videoCodecID: 173, videoCodecName: "hevc",
            videoWidth: 64, videoHeight: 64, videoFrameRate: 24, isDolbyVision: false,
            audioTracks: tracks, subtitleTracks: [])

        let hdr = AetherEngine.enrichHDR10Plus(base: base)
        #expect(hdr.audioTracks == tracks)
        #expect(hdr.videoFormat == .hdr10Plus)
        #expect(hdr.carriesHDR10PlusMetadata)

        let hdrThenAtmos = AetherEngine.enrichAtmos(base: hdr, confirmedTrackID: 2)
        let atmosThenHDR = AetherEngine.enrichHDR10Plus(
            base: AetherEngine.enrichAtmos(base: base, confirmedTrackID: 2))
        #expect(hdrThenAtmos.audioTracks == atmosThenHDR.audioTracks)
        #expect(hdrThenAtmos.audioTracks.map(\.isAtmos) == [true, true])
        #expect(hdrThenAtmos.carriesHDR10PlusMetadata && atmosThenHDR.carriesHDR10PlusMetadata)
        #expect(hdrThenAtmos.videoFormat == atmosThenHDR.videoFormat)
        #expect(AetherEngine.enrichAtmos(base: hdr, confirmedTrackID: 99).audioTracks == tracks)
        #expect(!base.carriesHDR10PlusMetadata)
        #expect(base.audioTracks.map(\.isAtmos) == [true, false])
    }
}
