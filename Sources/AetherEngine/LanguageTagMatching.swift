import Foundation

/// Which track kind a language comparison is for. The two differ in exactly one place: a subtitle
/// track whose script is explicitly the opposite of the preference is not a fallback at all, while
/// for audio a script mismatch only ranks last (#590).
enum LanguageMatchKind {
    case audio
    case subtitle
}

/// A container / host language label split into the three parts selection ranks on.
///
/// Parsed from the raw tag by SHAPE, never from `Locale.Language`'s subtag expansion. ICU fills a
/// script in for every language it knows (`zh` -> Hans, `en` -> Latn, `nan` -> Hans, `yue` -> Hant),
/// so asking it would turn a script-unspecified track into an explicitly-scripted one and, for the
/// Chinese pair the whole ranking exists for, into the wrong one (#590).
struct LanguageTag: Equatable {
    /// ISO 639-2/T identity: `en` / `eng` / `english` all arrive as `eng`, `ger` as `deu`. Two tags
    /// are the same language exactly when this is equal.
    let canonical: String
    /// Lowercased four-letter script subtag, or the script an explicit Chinese region implies. nil
    /// means the tag says nothing about script, which is a weaker match than agreement, never a
    /// conflict.
    let script: String?
    /// Lowercased region subtag (two letters or three digits).
    let region: String?

    /// nil for anything that is not a language: empty, `und`, a free-form track name, an
    /// unrecognized label. Those must stay non-matches rather than collapse onto each other.
    init?(_ raw: String?) {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        let subtags = trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        guard let primary = subtags.first,
              let canonical = Self.canonicalPrimary(primary) else { return nil }
        self.canonical = canonical

        var script: String?
        var region: String?
        for subtag in subtags.dropFirst() {
            if script == nil, subtag.count == 4, subtag.allSatisfy({ $0.isASCII && $0.isLetter }) {
                script = subtag
            } else if region == nil,
                      (subtag.count == 2 && subtag.allSatisfy { $0.isASCII && $0.isLetter })
                        || (subtag.count == 3 && subtag.allSatisfy { $0.isASCII && $0.isNumber }) {
                region = subtag
            }
        }
        self.region = region
        // A media server that writes zh-CN / zh-TW is making the script distinction with the only
        // field it has; treat it as the explicit script it means. Bare zh / chi / zho carries no
        // script and must not become Simplified by default.
        self.script = script ?? (canonical == "zho" ? Self.chineseScriptByRegion[region ?? ""] : nil)
    }

    private static let chineseScriptByRegion: [String: String] = [
        "cn": "hans", "sg": "hans", "tw": "hant", "hk": "hant", "mo": "hant",
    ]

    /// ISO 639-2/T for a primary subtag, or nil when the label is not a language.
    ///
    /// `AudioLanguageMap` already owns this resolution for the HLS master's `LANGUAGE` tag: the
    /// twenty bibliographic codes, ICU's alpha3 pairs, the CLDR macrolanguage aliases (`cmn` ->
    /// `zho`, while `yue` and `nan` stay themselves), and the 639-3 members ICU can only name. It
    /// fails closed on free text, which is what keeps a commentary title out of the language axis.
    /// The synonym table covers what is left: the English names, which ICU does not resolve.
    static func canonicalPrimary(_ primary: String) -> String? {
        if let code = AudioLanguageMap.iso639_2T(forSourceLanguage: primary) { return code }
        return synonymCanonical[primary]
    }

    /// Every member of `AetherEngine.languageSynonyms` mapped onto the canonical code of the first
    /// member that resolves, so a set whose members ICU handles keeps working through the same
    /// identity as everything else and the English names join it.
    private static let synonymCanonical: [String: String] = {
        var map: [String: String] = [:]
        for set in AetherEngine.languageSynonyms {
            guard let code = set.sorted().lazy
                .compactMap({ AudioLanguageMap.iso639_2T(forSourceLanguage: $0) }).first else { continue }
            for member in set { map[member] = code }
        }
        return map
    }()
}

extension AetherEngine {

    /// How well `trackLanguage` answers `preferred`, or nil when they are not the same language at
    /// all. Lower wins. Exact identity is 0; a same-language tag that differs only in what it leaves
    /// unspecified ranks above one that differs in what it states (#590).
    ///
    /// The two axes are script then region, each scored 0 for agreement (including both silent), 1
    /// when only one side states it, 2 when both state it and differ. Script dominates because it
    /// changes whether a subtitle is readable at all, while a region rarely changes the text.
    nonisolated static func languageMatchRank(
        _ trackLanguage: String?,
        _ preferred: String,
        kind: LanguageMatchKind
    ) -> Int? {
        guard let track = LanguageTag(trackLanguage),
              let want = LanguageTag(preferred),
              track.canonical == want.canonical else { return nil }

        let scriptRank = axisRank(track.script, want.script)
        // A Traditional track is not a weak answer to a Simplified preference, it is the wrong one.
        // Audio has no such reading failure, so there the mismatch only ranks last.
        if kind == .subtitle, scriptRank == 2 { return nil }
        return scriptRank * 3 + axisRank(track.region, want.region)
    }

    nonisolated private static func axisRank(_ lhs: String?, _ rhs: String?) -> Int {
        switch (lhs, rhs) {
        case (nil, nil): return 0
        case let (l?, r?): return l == r ? 0 : 2
        default: return 1
        }
    }

    /// Index of the best track for the first preference that matches anything. Preference order
    /// dominates, so an earlier preference on a worse-ranked track still beats a later preference on
    /// a perfect one; within one preference, language specificity ranks first and `secondaryRank`
    /// (the descriptor axis for subtitles) resolves the remaining ties in container order.
    nonisolated static func bestLanguageMatchIndex(
        languages: [String?],
        preferredLanguages: [String],
        kind: LanguageMatchKind,
        secondaryRank: ((Int) -> Int)? = nil
    ) -> Int? {
        for preferred in preferredLanguages {
            let ranked = languages.indices.compactMap { index -> (index: Int, rank: Int, tie: Int)? in
                guard let rank = languageMatchRank(languages[index], preferred, kind: kind) else { return nil }
                return (index, rank, secondaryRank?(index) ?? 0)
            }
            // min(by:) is stable, so a full tie keeps container order.
            if let best = ranked.min(by: { ($0.rank, $0.tie) < ($1.rank, $1.tie) }) {
                return best.index
            }
        }
        return nil
    }
}
