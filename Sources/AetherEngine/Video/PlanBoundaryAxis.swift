import Foundation

/// AE#561: which timestamp axis a keyframe-aligned plan's boundaries are stamped on.
///
/// The keyframe-aligned plan's boundaries ARE the container's index entries (`indexedKeyframes`),
/// and containers do not agree on what an index entry's timestamp means. mov/mp4 builds its index
/// from `stts`/`stss`, so an entry is a DECODE time; a Matroska Cue stores the block's timestamp,
/// which is a PRESENTATION time. The VOD cutter compares a video packet against those boundaries,
/// so it has to be handed the matching timestamp.
///
/// Mixing the two offsets every comparison by the frame's composition offset, in whichever direction
/// the mismatch runs, and both directions have been paid for:
///
/// - Presentation packet against decode boundaries (#358): a keyframe reached boundaries beyond its
///   own, consuming plan indices that then never opened a segment while the playlist kept offering
///   them. That is why the gate compares decode times today.
/// - Decode packet against presentation boundaries (AE#561): on a Matroska with B-frames NO IRAP
///   ever reaches its own boundary, because its decode time sits a composition offset below it. The
///   keyframe gate therefore never opens on the IRAP the plan named; audio, which is routed by
///   boundary and not gated, opens the segment instead, and the IRAP stays in the segment before.
///   Every segment then begins mid-GOP, roughly one IRAP below its own first random-access point
///   (`#412 seg-N opens 0.751s below its first random-access point` on every segment of the field
///   report), so nothing in it can start a decode run. Playback survives only while AVPlayer decodes
///   THROUGH the boundaries; the first time it has to decode FROM one it answers with -19602.
///
/// The fix is not to pick one axis but to compare like with like, and then a keyframe hits its own
/// boundary exactly, on either container.
enum PlanBoundaryAxis: Sendable, Equatable {

    /// Index entries are decode timestamps: mov/mp4, and everything libavformat indexes from
    /// `pkt->dts`.
    case decode

    /// Index entries are presentation timestamps: Matroska/WebM Cues.
    case presentation

    /// The axis `formatName`'s index entries are stamped on, from libavformat's demuxer name
    /// ("matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2", "mpegts").
    ///
    /// Only Matroska claims presentation. `.decode` stays the default on purpose: it is what every
    /// other container the engine indexes uses, and what the cutter did before this axis existed, so
    /// an unrecognised format keeps today's behaviour instead of inheriting a guess.
    static func forContainer(formatName: String?) -> PlanBoundaryAxis {
        let names = formatName?.split(separator: ",") ?? []
        return names.contains("matroska") || names.contains("webm") ? .presentation : .decode
    }

    /// The packet timestamp to compare against a plan boundary on this axis.
    ///
    /// Falls back to the other axis when the preferred one is absent (`Int64.min`), which is what the
    /// cutter did for a DTS-less packet before the axis existed: a timestamp on the wrong axis still
    /// orders the stream, a missing one does not.
    func timestamp(dts: Int64, pts: Int64) -> Int64 {
        switch self {
        case .decode:
            return dts != Int64.min ? dts : pts
        case .presentation:
            return pts != Int64.min ? pts : dts
        }
    }
}
