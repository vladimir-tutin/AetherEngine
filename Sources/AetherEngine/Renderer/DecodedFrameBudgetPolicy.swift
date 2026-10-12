import Foundation

// MARK: - FlexUI decoded-frame memory budget
//
// Field capture (Apple TV 4K, FlexUI build 269, 2026-10-11: `logs/tvos-native.log` plus a VM
// region map of the playing process): a 3840x2160 10-bit HEVC session held 15 IOSurfaces of
// 23.75 MiB each (P010, 3 bytes per pixel) = 356 MiB resident, the largest native owner after the
// source window. The count is set by RETENTION, not by the decoder: the queue target refuses data
// at about 8 frames (`[Renderer] isReadyForMoreMediaData=false at enqueue #9`), the reorder buffer
// holds 4 more, and VideoToolbox keeps a few spare. `vLead` sat at a 0.52 s median, which is
// 12 frames at 23.976 fps. The same session's lead fell under 0.25 s in 12 of 1114 seconds, every
// one at a seek and every one already a frame drop, so steady playback never used the cushion.
//
// VideoToolbox documents only a requested MINIMUM output-pool count
// (`kVTDecompressionPropertyKey_OutputPoolRequestedMinimumBufferCount`), never a maximum. The one
// lever is how many decoded frames the engine admits ahead of the clock. This policy turns a memory
// figure into that count from the ACTUAL decoded buffer (planes x bytes-per-row x height, read off
// the first frame), so 4K 8-bit, 4K 10-bit, a cropped 3840x1600 and 1080p each get the count their
// frames cost. Bitrate plays no part: it changes the source window, not the decoded frame.
//
// The gate lives in `SampleBufferRenderer.isReadyForMoreMediaData`, which every demux-side video
// feed already waits on, so no loop learned a new condition. It only engages while the renderer's
// timebase is RUNNING: an unarmed or paused clock cannot drain the queue, and holding decode on it
// would be the deadlock the clock-arming policies exist to avoid.

/// Host-settable budget. `budgetBytes` is the memory allowed for decoded frames admitted ahead of
/// the clock; `minFrames` is the floor the reorder buffer and the layer need to keep presenting
/// (4 reorder + 2 in flight); `maxFrames` is a sanity ceiling for tiny frames.
public struct AetherDecodedFrameBudgetPolicy: Equatable, Sendable {
    public var enabled: Bool
    public var budgetBytes: Int
    public var minFrames: Int
    public var maxFrames: Int

    public static let stock = AetherDecodedFrameBudgetPolicy(
        enabled: false, budgetBytes: 0, minFrames: 6, maxFrames: 64)

    public init(enabled: Bool, budgetBytes: Int, minFrames: Int, maxFrames: Int) {
        self.enabled = enabled
        self.budgetBytes = budgetBytes
        self.minFrames = minFrames
        self.maxFrames = maxFrames
    }

    /// Pure resolver: policy + measured frame cost + frame interval -> the lead cap to enforce.
    /// Unit-tested without a renderer. An unresolved input (no frame seen yet, unknown frame rate,
    /// disabled policy) leaves the gate OPEN rather than guessing a cost.
    public func resolve(frameBytes: Int, frameDurationSeconds: Double) -> AetherDecodedFrameLimit {
        guard enabled, budgetBytes > 0 else {
            return AetherDecodedFrameLimit(
                frames: 0, leadSeconds: .infinity, frameBytes: frameBytes,
                frameDurationSeconds: frameDurationSeconds, reason: "disabled")
        }
        guard frameBytes > 0, frameDurationSeconds > 0, frameDurationSeconds.isFinite else {
            return AetherDecodedFrameLimit(
                frames: 0, leadSeconds: .infinity, frameBytes: frameBytes,
                frameDurationSeconds: frameDurationSeconds, reason: "unresolved")
        }
        let floor = max(1, minFrames)
        let ceiling = max(floor, maxFrames)
        let affordable = budgetBytes / frameBytes
        let frames: Int
        let reason: String
        if affordable < floor {
            frames = floor
            reason = "floor"
        } else if affordable > ceiling {
            frames = ceiling
            reason = "ceiling"
        } else {
            frames = affordable
            reason = "budget"
        }
        return AetherDecodedFrameLimit(
            frames: frames, leadSeconds: Double(frames) * frameDurationSeconds,
            frameBytes: frameBytes, frameDurationSeconds: frameDurationSeconds, reason: reason)
    }
}

/// What the renderer gate enforces for the open stream. `leadSeconds` is infinite when open.
public struct AetherDecodedFrameLimit: Equatable, Sendable {
    public let frames: Int
    public let leadSeconds: Double
    public let frameBytes: Int
    public let frameDurationSeconds: Double
    /// `disabled` | `unresolved` | `floor` | `budget` | `ceiling`
    public let reason: String

    public static let unlimited = AetherDecodedFrameLimit(
        frames: 0, leadSeconds: .infinity, frameBytes: 0, frameDurationSeconds: 0, reason: "disabled")

    public var isLimited: Bool { leadSeconds.isFinite }
}

/// Process-global policy + telemetry, the shape `AetherSourceBuffer` uses and for the same reason:
/// the renderer that enforces it sits below the host the bridge talks to.
public enum AetherDecodedFrameBudget {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _policy = AetherDecodedFrameBudgetPolicy.stock
    nonisolated(unsafe) private static var _revision = 0
    nonisolated(unsafe) private static var _lastApplied = AetherDecodedFrameLimit.unlimited
    nonisolated(unsafe) private static var _holds = 0

    /// Host-settable. Thread-safe; a change bumps `revision`, and the renderer re-resolves its
    /// limit on the next gate read, so a Settings change applies to the PLAYING stream.
    public static var policy: AetherDecodedFrameBudgetPolicy {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set {
            lock.lock()
            let changed = _policy != newValue
            if changed {
                _policy = newValue
                _revision += 1
            }
            lock.unlock()
            if changed {
                EngineLog.emit(
                    "[DecodedFrameBudget] policy set enabled=\(newValue.enabled) "
                    + "budgetMB=\(newValue.budgetBytes / 1024 / 1024) "
                    + "minFrames=\(newValue.minFrames) maxFrames=\(newValue.maxFrames) "
                    + "applies=live",
                    category: .swPlayback)
            }
        }
    }

    /// Monotonic; compared by the renderer against the revision it resolved under.
    static var revision: Int {
        lock.lock(); defer { lock.unlock() }; return _revision
    }

    /// What the renderer most recently resolved for the open stream, never the requested value.
    public static var lastApplied: AetherDecodedFrameLimit {
        get { lock.lock(); defer { lock.unlock() }; return _lastApplied }
    }

    static func recordApplied(_ limit: AetherDecodedFrameLimit) {
        lock.lock()
        _lastApplied = limit
        lock.unlock()
    }

    /// Times the gate closed on the budget (counted per park, not per poll).
    public static var holds: Int {
        lock.lock(); defer { lock.unlock() }; return _holds
    }

    static func noteHold() {
        lock.lock()
        _holds += 1
        lock.unlock()
    }

    /// Zero the counters and forget the last applied limit for a new playback source.
    public static func resetTelemetry() {
        lock.lock()
        _holds = 0
        _lastApplied = .unlimited
        lock.unlock()
    }
}
