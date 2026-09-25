import Foundation
import AetherLibavcodec

/// Audit SEG-1: demuxed timestamps reach the pump unchecked (matroskadec stores a uint64 cluster
/// time into an int64 pts, a live fMP4 tfdt is whatever the origin wrote), and Swift traps on
/// Int64 overflow. Values outside `plausibleMagnitude` become AV_NOPTS_VALUE at the source funnel,
/// which the pump's NOPTS repair already handles, and the tick arithmetic downstream saturates
/// instead of trapping.
enum SourceTimestampBounds {

    /// 2^60 still holds an epoch-anchored tfdt at a 10 MHz timescale by three orders of magnitude,
    /// and leaves room for the pump's three-term shift chains below 2^63.
    static let plausibleMagnitude: Int64 = 1 << 60

    static func plausible(_ ticks: Int64) -> Int64 {
        guard ticks != Int64.min else { return ticks }
        return ticks > -plausibleMagnitude && ticks < plausibleMagnitude ? ticks : Int64.min
    }

    /// Returns whether any field was out of range and got replaced.
    @discardableResult
    static func sanitize(_ packet: UnsafeMutablePointer<AVPacket>) -> Bool {
        let pts = plausible(packet.pointee.pts)
        let dts = plausible(packet.pointee.dts)
        let duration = packet.pointee.duration
        let durationOK = duration >= 0 && duration < plausibleMagnitude
        guard pts != packet.pointee.pts || dts != packet.pointee.dts || !durationOK else { return false }
        packet.pointee.pts = pts
        packet.pointee.dts = dts
        if !durationOK { packet.pointee.duration = 0 }
        return true
    }

    /// Saturating tick arithmetic. The floor is `Int64.min + 1` so a result never reads as AV_NOPTS_VALUE.
    static func difference(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.subtractingReportingOverflow(rhs)
        guard overflow else { return max(value, Int64.min + 1) }
        return lhs < rhs ? Int64.min + 1 : Int64.max
    }

    static func sum(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        guard overflow else { return max(value, Int64.min + 1) }
        return lhs < 0 ? Int64.min + 1 : Int64.max
    }
}
