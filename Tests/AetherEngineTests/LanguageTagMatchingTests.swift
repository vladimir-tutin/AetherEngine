import Testing
import Foundation
@testable import AetherEngine

/// Issue #590: preference matching normalizes BCP-47 region and script subtags instead of comparing
/// labels exactly, and ranks within one preference so the most specific same-language track wins.
/// Pure selection, no media fixture and no decoder path involved.
struct LanguageTagMatchingTests {

    private func track(_ id: Int, _ lang: String?, codec: String = "subrip",
                       isForced: Bool = false, isHearingImpaired: Bool = false) -> TrackInfo {
        TrackInfo(id: id, name: "t\(id)", codec: codec, language: lang, isDefault: false,
                  isForced: isForced, isHearingImpaired: isHearingImpaired)
    }

    // MARK: - Identity

    @Test("region and script subtags no longer break a same-language match")
    func normalizedIdentity() {
        // The five rows the report listed as unmatched.
        #expect(AetherEngine.languageMatches("en-US", "en"))
        #expect(AetherEngine.languageMatches("eng", "en-US"))
        #expect(AetherEngine.languageMatches("ara", "ar-SA"))
        #expect(AetherEngine.languageMatches("zh-TW", "zh-Hant"))
        #expect(AetherEngine.languageMatches("zh-CN", "zh-Hans"))
        // The gap that reached the Jellyfin host too: a pt-BR track under a bare pt preference.
        #expect(AetherEngine.languageMatches("pt-BR", "pt"))
        #expect(AetherEngine.languageMatches("pt-BR", "por"))
    }

    @Test("a label that is not a language stays a non-match")
    func nonLanguagesStayClosed() {
        #expect(!AetherEngine.languageMatches(nil, "en"))
        #expect(!AetherEngine.languageMatches("", "en"))
        #expect(!AetherEngine.languageMatches("en", ""))
        #expect(!AetherEngine.languageMatches("und", "en"))
        #expect(!AetherEngine.languageMatches("und", "und"))
        #expect(!AetherEngine.languageMatches("Director's Commentary", "en"))
        #expect(!AetherEngine.languageMatches("dub", "de"))
        #expect(!AetherEngine.languageMatches("en", "de"))
    }

    @Test("related languages are not collapsed onto their macrolanguage")
    func relatedLanguagesStayDistinct() {
        // CLDR aliases cmn onto zh, so that one IS the same identity.
        #expect(AetherEngine.languageMatches("cmn", "zh"))
        // yue and nan are not aliased and must never answer a zh preference. There is deliberately
        // no weak macrolanguage tier: wrong audio is worse than the container default.
        #expect(!AetherEngine.languageMatches("yue", "zh"))
        #expect(!AetherEngine.languageMatches("nan", "zh"))
        #expect(!AetherEngine.languageMatches("yue", "cmn"))
        // Norwegian keeps its three separate identities, as it did before #590.
        #expect(!AetherEngine.languageMatches("nb", "no"))
        #expect(!AetherEngine.languageMatches("nn", "nb"))
    }

    @Test("every pair the pre-#590 synonym table matched still matches")
    func synonymTableRegression() {
        for set in AetherEngine.languageSynonyms {
            for a in set {
                for b in set {
                    #expect(AetherEngine.languageMatches(a, b), "\(a) vs \(b)")
                }
            }
        }
    }

    // MARK: - The ICU trap

    @Test("a bare zh tag carries no script, whatever likely-subtags would infer")
    func bareChineseHasNoScript() {
        // Locale.Language(identifier:).script infers a script for every language it knows: zh -> Hans,
        // en -> Latn, nan -> Hans, yue -> Hant. Reading it would make an unspecified track explicit,
        // and for nan explicitly the wrong one. The parser reads the raw subtags instead.
        #expect(LanguageTag("zh")?.script == nil)
        #expect(LanguageTag("zho")?.script == nil)
        #expect(LanguageTag("chi")?.script == nil)
        #expect(LanguageTag("en")?.script == nil)
        #expect(LanguageTag("nan")?.script == nil)
        #expect(LanguageTag("zh-Hant")?.script == "hant")
        // A media server making the script distinction with the only field it has.
        #expect(LanguageTag("zh-TW")?.script == "hant")
        #expect(LanguageTag("zh-HK")?.script == "hant")
        #expect(LanguageTag("zh-MO")?.script == "hant")
        #expect(LanguageTag("zh-CN")?.script == "hans")
        #expect(LanguageTag("zh-SG")?.script == "hans")
        // The region mapping is Chinese-only: en-CN is not a script statement.
        #expect(LanguageTag("en-CN")?.script == nil)
    }

    // MARK: - Audio ranking

    @Test("audio: an exact region beats a generic tag, which beats another region")
    func audioPrefersExactRegion() {
        // The report's acceptance example, with the exact match last in container order.
        let tracks = [track(0, "en-US", codec: "aac"), track(1, "eng", codec: "aac"),
                      track(2, "en-GB", codec: "aac")]
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["en-GB"]) == 2)
        // Drop the exact one and the unspecified region ranks above the wrong one.
        #expect(AetherEngine.selectAudioIndex(
            tracks: Array(tracks.prefix(2)), override: nil, preferredLanguages: ["en-GB"]) == 1)
        // A bare preference is answered by a bare tag before a regional one.
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["en"]) == 1)
    }

    @Test("preference order still dominates specificity")
    func preferenceOrderDominates() {
        let tracks = [track(0, "de-AT", codec: "aac"), track(1, "en-GB", codec: "aac")]
        // A worse-ranked track under the first preference beats a perfect one under the second.
        #expect(AetherEngine.selectAudioIndex(
            tracks: tracks, override: nil, preferredLanguages: ["de-DE", "en-GB"]) == 0)
    }

    @Test("audio tolerates a script mismatch that subtitles reject")
    func audioDoesNotRejectOnScript() {
        // Reading is what a wrong script breaks, and audio is not read.
        #expect(AetherEngine.languageMatchRank("zh-CN", "zh-Hant", kind: .audio) != nil)
        #expect(AetherEngine.languageMatchRank("zh-CN", "zh-Hant", kind: .subtitle) == nil)
    }

    // MARK: - Subtitle ranking

    @Test("subtitles: the explicit matching script wins, generic is the fallback")
    func subtitlePrefersMatchingScript() {
        let tracks = [track(0, "zh-CN"), track(1, "zho"), track(2, "zh-TW")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["zh-Hant"]) == 2)
    }

    @Test("subtitles: a script-unspecified track answers when no explicit one does")
    func subtitleFallsBackToUnspecifiedScript() {
        let tracks = [track(0, "zh-CN"), track(1, "zho")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["zh-Hant"]) == 1)
    }

    @Test("subtitles: an explicitly opposite script is not a fallback")
    func subtitleRejectsOppositeScript() {
        let tracks = [track(0, "zh-CN")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["zh-Hant"]) == nil)
    }

    @Test("language specificity ranks before the descriptor axis")
    func specificityOutranksDescriptor() {
        // A full zho track and a forced zh-TW one: the matching script wins even though forced
        // ranks below full, because language is resolved first.
        let tracks = [track(0, "zho"), track(1, "zh-TW", isForced: true)]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: tracks, preferredLanguages: ["zh-Hant"]) == 1)
        // At equal language specificity the descriptor axis decides, as it did before #590.
        let equal = [track(0, "zh-TW", isForced: true), track(1, "zh-TW")]
        #expect(AetherEngine.selectSubtitleIndex(
            tracks: equal, preferredLanguages: ["zh-Hant"]) == 1)
    }

    @Test("the native rendition default resolves the same way as the overlay pick")
    func nativeDefaultAgreesWithOverlay() {
        let languages: [String?] = ["zh-CN", "zho", "zh-TW"]
        #expect(AetherEngine.bestLanguageMatchIndex(
            languages: languages, preferredLanguages: ["zh-Hant"], kind: .subtitle) == 2)
        #expect(AetherEngine.bestLanguageMatchIndex(
            languages: languages, preferredLanguages: ["zh-Hans"], kind: .subtitle) == 0)
        #expect(AetherEngine.bestLanguageMatchIndex(
            languages: languages, preferredLanguages: ["ja"], kind: .subtitle) == nil)
    }

    @Test("an empty preference list stays a no-op")
    func emptyPreferencesAreNoOp() {
        #expect(AetherEngine.bestLanguageMatchIndex(
            languages: ["en", "de"], preferredLanguages: [], kind: .audio) == nil)
    }
}
