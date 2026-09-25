import Foundation

/// AE#616: the offset between AVPlayer's item time and the media timestamps of what it presents, on the
/// `nativeRemoteHLS` bypass, measured off the #316 renditions the engine injected itself.
///
/// A server that restarts a transcode at the keyframe before a segment's slot (Jellyfin: `-ss <slot>
/// -noaccurate_seek -copyts`) serves a first segment whose `tfdt` lies before the slot its playlist
/// promises. AVPlayer anchors its item timeline to the first segment it loads after a seek, so item
/// time then leads the displayed frame by that gap, 1 to 8 s measured, different on every seek, and
/// the anchor survives later job restarts. Nothing on the bypass sees a segment, so the gap cannot be
/// read where it arises.
///
/// The injected WebVTT is placed by media timestamp, so each cue reaches the legible output at
/// `item = cue.start + offset`. Matching the presented text back to the cue the engine wrote gives the
/// offset, and it re-measures on every line. Pure so the matching is testable without an item.
struct RemoteHLSCueClock {

    /// Offsets outside this band are a different line with the same text, not a measurement. The gap
    /// is at most one keyframe interval in the seek direction; the band is wide on purpose.
    static let plausibleOffsets: ClosedRange<Double> = -2.0...30.0

    /// Item seconds minus media seconds of the presented frame. Nil until the first line is matched.
    private(set) var offset: Double?

    /// Whether `offset` was measured since the last time jump. A jump keeps the previous offset as the
    /// best guess, but the anchor may have moved, so until the next matched line it is only a guess.
    private(set) var isMeasuredSinceJump = false

    private var startsByText: [String: [Double]] = [:]
    private var presented: Set<String> = []
    /// The first delivery after a time jump reports whatever is active at the landing, stamped with
    /// the landing time rather than the cue's start, so it teaches nothing.
    private var skipNextDelivery = true

    var hasCues: Bool { !startsByText.isEmpty }

    mutating func setCues(_ cues: [(start: Double, text: String)]) {
        var index: [String: [Double]] = [:]
        for cue in cues {
            let key = Self.normalize(cue.text)
            guard !key.isEmpty else { continue }
            index[key, default: []].append(cue.start)
        }
        startsByText = index
    }

    /// A seek or an item change: the anchor may move, and the next delivery is a landing.
    mutating func noteTimeJump() {
        presented = []
        skipNextDelivery = true
        isMeasuredSinceJump = false
    }

    /// Feed one legible-output delivery. Returns the new offset when this delivery measured one.
    mutating func observe(strings: [String], itemTime: Double) -> Double? {
        let now = Set(strings.map(Self.normalize).filter { !$0.isEmpty })
        let appeared = now.subtracting(presented)
        presented = now
        if skipNextDelivery {
            skipNextDelivery = false
            return nil
        }
        // A cue ending changes the set without starting anything; only an appearing line is stamped
        // with its own start.
        guard !appeared.isEmpty else { return nil }

        var unique: Double?
        var ambiguous: [Double] = []
        for text in appeared {
            let candidates = (startsByText[text] ?? [])
                .map { itemTime - $0 }
                .filter { Self.plausibleOffsets.contains($0) }
            if candidates.count == 1 {
                unique = candidates[0]
                break
            }
            ambiguous.append(contentsOf: candidates)
        }
        let reference = offset ?? 0
        guard let measured = unique ?? ambiguous.min(by: { abs($0 - reference) < abs($1 - reference) })
        else { return nil }
        offset = measured
        isMeasuredSinceJump = true
        return measured
    }

    /// What the legible output hands back, reduced to what the served `.vtt` said: the rendition's
    /// text went through `MovTextSampleBuilder.sanitize`, and AVPlayer drops the WebVTT markup and may
    /// re-break lines.
    static func normalize(_ text: String) -> String {
        var s = MovTextSampleBuilder.sanitize(text)
        while let open = s.firstIndex(of: "<"), let close = s[open...].firstIndex(of: ">") {
            s.removeSubrange(open...close)
        }
        s = s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
        return s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
