import Foundation

/// Time-aware forward-buffer policy for the persistent (playback) source reader.
///
/// # Why this exists
///
/// `AVIOReader`'s persistent path historically bounded its sliding window with two FIXED BYTE
/// watermarks: suspend the transfer above 16 MB, resume it below 8 MB (#174/#220). Bytes are the
/// wrong unit for a playback cushion. Measured on Apple TV against a 25.2 Mbps direct-play MKV:
///
///   - 8 MB low water  = 2.66 s of media. That is the ENTIRE margin available when the transfer
///     is resumed, i.e. the reader wakes a fully idle HTTP connection with 2.66 s left to live.
///   - 16 MB high water = 5.33 s, so the cycle repeats every ~2.66 s: ~22 suspend/resume rounds
///     per minute, ~1000 per 45-minute episode.
///   - Field capture (`logs/tvos-metro.log`, 2026-08-02): `pumpSusp=1` in 40 of 41 memprobes, so
///     the connection is parked ~97% of wall clock. Two reads then blocked 3.003 s and 3.810 s
///     with `reconnects=0 backoff=0ms connect=0ms lockWait=0ms unaccounted=0ms` — the connection
///     was never lost; the origin simply did not resume at rate, and 2.66 s of cushion ran out.
///
/// The same 8 MB is 0.84 s at 80 Mbps. A byte watermark silently gets MORE fragile exactly where
/// the media is most demanding, which is backwards.
///
/// # What the industry does
///
/// Every mainstream player sizes its forward buffer in TIME, with bytes only as a memory ceiling:
///
///   - Media3 / ExoPlayer `DefaultLoadControl` (verified in androidx/media `release`):
///     `DEFAULT_MIN_BUFFER_MS = 50_000`, `DEFAULT_MAX_BUFFER_MS = 50_000`,
///     `DEFAULT_BUFFER_FOR_PLAYBACK_MS = 1000`, `DEFAULT_TARGET_BUFFER_BYTES = LENGTH_UNSET`
///     (derived from the selected tracks rather than fixed), and a per-role allocation ceiling of
///     `DEFAULT_VIDEO_BUFFER_SIZE = 2000 * 64 KB = 128 MB`. Time first, bytes as the ceiling.
///     Note `DEFAULT_MIN_BUFFER_FOR_LOCAL_PLAYBACK_MS = 1000`: Media3 only drops to a 1 s cushion
///     for genuinely LOCAL files. An HTTP origin — which is what this reader always talks to,
///     even on a LAN — gets the 50 s policy.
///   - AVFoundation `AVPlayerItem.preferredForwardBufferDuration` is a DURATION, defaults to 0
///     ("let the system choose"), and Apple documents that small values increase stalling.
///     `AVPlayer.automaticallyWaitsToMinimizeStalling` exists for the same reason.
///
/// So the defaults below (15 s resume / 30 s target) are conservative relative to Media3's 50 s,
/// and are ~6x the cushion and ~1/6 the restart count of the stock byte policy.
///
/// # Deliberate design choices
///
///   - **Suspension is not eliminated.** `suspend()`/`resume()` on the data task is the only
///     contractual flow control URLSession offers; #174 proved that blocking the delegate instead
///     lets CFNetwork buffer without bound until jetsam. So this keeps the mechanism and fixes the
///     THRESHOLDS, which is what the field data indicts.
///   - **`keepWarmSeconds` bounds how long the socket may stay fully idle.** The observed failure
///     is a COLD restart: the origin here is Node `fs.createReadStream(...).pipe(res)` over an SMB
///     mount, and a multi-second park lets that pipeline (and TCP's congestion window, via
///     slow-start-after-idle) go cold. Resuming early tops the window back up to the high water in
///     small increments instead of one large cold refill, and has the side effect of keeping the
///     resident window near the high water rather than sawtoothing down to the low water.
///   - **`maxWindowBytes` is a hard memory ceiling.** 30 s at 80 Mbps is 300 MB, which this device
///     class cannot afford on top of a ~520 MB RSS. The resolver clamps, and `resolve()` reports
///     which bound won so the log states the APPLIED value, never the requested one.
public struct AetherSourceBufferPolicy: Sendable, Equatable {

    /// Master switch. `false` reproduces the stock byte watermarks and the stock contiguous
    /// window EXACTLY, so the shipped default is the known-good path (AGENTS.md: new native
    /// playback behaviour ships off until explicitly enabled on device).
    public var enabled: Bool

    /// Resume the suspended transfer when the forward buffer falls below this many seconds.
    public var lowWaterSeconds: Double

    /// Suspend the transfer once the forward buffer exceeds this many seconds.
    public var highWaterSeconds: Double

    /// Absolute ceiling on the resident forward window, whatever the duration targets ask for.
    public var maxWindowBytes: Int

    /// `hardCap = highWater * this`. The hard cap is #220's bound for a transport that ignores
    /// `suspend()`; past it the connection is ended and re-requested at the frontier.
    public var hardCapMultiplier: Double

    /// Longest the data task may stay suspended before it is resumed anyway, seconds.
    /// `0` disables keep-warm (pure hysteresis, the stock shape at the new thresholds).
    public var keepWarmSeconds: Double

    /// Allocation granularity of the block-ring window.
    public var blockSizeBytes: Int

    /// `false` keeps the stock contiguous `Data` window. The ring exists because the stock window
    /// trims with `subdata`, which reallocates and copies the whole remainder: at 95 MB that is a
    /// ~93 MB alloc+copy every 4 MB consumed, and #220 already recorded 153/129 MB paired blocks
    /// as a jetsam risk. Large windows are only affordable in fixed-size blocks.
    public var useBlockRing: Bool

    /// Bytes kept behind the read cursor for matroska's small backward re-reads.
    public var lookbackBytes: Int

    /// Forward seeks within this distance keep the live connection instead of reconnecting.
    /// `0` means "derive from the low water" (half of it), which is what a large window wants.
    public var seekKeepForwardBytes: Int

    /// Memory circuit breaker: this many hard-cap connection ends inside
    /// `breakerWindowSeconds` halves the applied watermarks (never below stock) for the rest of
    /// the session, without touching the persisted policy.
    public var breakerHardCapEvents: Int
    public var breakerWindowSeconds: Double

    public init(
        enabled: Bool = false,
        lowWaterSeconds: Double = 15,
        highWaterSeconds: Double = 30,
        maxWindowBytes: Int = 128 * 1024 * 1024,
        hardCapMultiplier: Double = 1.5,
        keepWarmSeconds: Double = 4,
        blockSizeBytes: Int = 1024 * 1024,
        useBlockRing: Bool = true,
        lookbackBytes: Int = 2 * 1024 * 1024,
        seekKeepForwardBytes: Int = 0,
        breakerHardCapEvents: Int = 3,
        breakerWindowSeconds: Double = 60
    ) {
        self.enabled = enabled
        self.lowWaterSeconds = lowWaterSeconds
        self.highWaterSeconds = highWaterSeconds
        self.maxWindowBytes = maxWindowBytes
        self.hardCapMultiplier = hardCapMultiplier
        self.keepWarmSeconds = keepWarmSeconds
        self.blockSizeBytes = blockSizeBytes
        self.useBlockRing = useBlockRing
        self.lookbackBytes = lookbackBytes
        self.seekKeepForwardBytes = seekKeepForwardBytes
        self.breakerHardCapEvents = breakerHardCapEvents
        self.breakerWindowSeconds = breakerWindowSeconds
    }

    /// Shipped default: stock behaviour, byte watermarks, contiguous window.
    public static let stock = AetherSourceBufferPolicy(enabled: false)

    /// The recommended time-aware policy. Not the default; the host opts in.
    public static let timeAware = AetherSourceBufferPolicy(enabled: true)
}

/// The stock byte watermarks, kept in one place so `enabled == false` is provably identical to
/// the pre-change build and so the resolver has a floor it can never go below.
public enum AetherSourceBufferStock {
    public static let lowWaterBytes = 8 * 1024 * 1024
    public static let highWaterBytes = 16 * 1024 * 1024
    public static let hardCapBytes = 48 * 1024 * 1024
    public static let lookbackBytes = 2 * 1024 * 1024
    public static let seekKeepForwardBytes = 8 * 1024 * 1024
}

/// The watermarks a reader actually installed, plus why. `reason` is what the diagnostics print,
/// so the log always reports the APPLIED value rather than the requested one.
public struct AetherResolvedWatermarks: Sendable, Equatable {
    public let lowWaterBytes: Int
    public let highWaterBytes: Int
    public let hardCapBytes: Int
    public let lookbackBytes: Int
    public let seekKeepForwardBytes: Int
    /// Media rate the durations were resolved against, bytes/sec. 0 when unknown (stock applied).
    public let bytesPerSecond: Double
    /// `stock` | `time` | `time-clamped-memory` | `time-clamped-floor` | `breaker`
    public let reason: String

    public var lowWaterSeconds: Double { bytesPerSecond > 0 ? Double(lowWaterBytes) / bytesPerSecond : 0 }
    public var highWaterSeconds: Double { bytesPerSecond > 0 ? Double(highWaterBytes) / bytesPerSecond : 0 }

    public static let stock = AetherResolvedWatermarks(
        lowWaterBytes: AetherSourceBufferStock.lowWaterBytes,
        highWaterBytes: AetherSourceBufferStock.highWaterBytes,
        hardCapBytes: AetherSourceBufferStock.hardCapBytes,
        lookbackBytes: AetherSourceBufferStock.lookbackBytes,
        seekKeepForwardBytes: AetherSourceBufferStock.seekKeepForwardBytes,
        bytesPerSecond: 0,
        reason: "stock"
    )
}

public extension AetherSourceBufferPolicy {

    /// Pure resolver: policy + measured media rate -> the byte watermarks to install.
    /// Unit-tested without any network or engine state.
    ///
    /// Invariants it guarantees, because violating any of them deadlocks or thrashes the reader:
    ///   - `low < high` with a real gap (a low equal to high resumes and re-suspends per delivery).
    ///   - `low >= stock low` and `high >= stock high`: this feature only ever GROWS the cushion.
    ///   - `high <= maxWindowBytes`, and `hardCap > high` so the cap cannot fire during normal fill.
    ///
    /// `shrinkFactor` is the memory circuit breaker (1 = untripped, 0.5 = halved, ...).
    func resolve(bytesPerSecond: Double, shrinkFactor: Double = 1) -> AetherResolvedWatermarks {
        guard enabled, bytesPerSecond > 0,
              lowWaterSeconds > 0, highWaterSeconds > lowWaterSeconds else {
            return .stock
        }

        let shrink = max(0.25, min(1, shrinkFactor))
        let ceiling = max(AetherSourceBufferStock.highWaterBytes, maxWindowBytes)

        var reason = shrink < 1 ? "breaker" : "time"

        // Duration targets -> bytes.
        var high = Int((bytesPerSecond * highWaterSeconds * shrink).rounded())
        var low = Int((bytesPerSecond * lowWaterSeconds * shrink).rounded())

        // Memory ceiling wins over the duration target. Preserve the low:high ratio so the
        // clamped policy still resumes with a proportionate cushion instead of collapsing onto
        // the high water (which would resume-and-immediately-re-suspend on every delivery).
        if high > ceiling {
            let ratio = Double(low) / Double(high)
            high = ceiling
            low = Int((Double(high) * ratio).rounded())
            reason = "time-clamped-memory"
        }

        // Never regress below stock; this change exists to enlarge the cushion, never shrink it.
        if high < AetherSourceBufferStock.highWaterBytes || low < AetherSourceBufferStock.lowWaterBytes {
            high = max(high, AetherSourceBufferStock.highWaterBytes)
            low = max(low, AetherSourceBufferStock.lowWaterBytes)
            reason = shrink < 1 ? "breaker" : "time-clamped-floor"
        }

        // Keep a real hysteresis gap. Without it the transfer resumes and re-suspends on every
        // single delivery, which is the pathological opposite of what this policy is for.
        let minGap = max(2 * 1024 * 1024, high / 8)
        if high - low < minGap {
            low = max(AetherSourceBufferStock.lowWaterBytes, high - minGap)
        }
        // Degenerate ceiling (a host setting maxWindowBytes at/below the floor): give the gap
        // priority over the ceiling rather than returning low >= high.
        if low >= high {
            high = low + minGap
        }

        // The hard cap is the "transport ignored suspend()" bound, so it must sit clear of the
        // high water or a healthy fill would trip it.
        let hardCap = max(
            AetherSourceBufferStock.hardCapBytes,
            Int((Double(high) * max(1.25, hardCapMultiplier)).rounded())
        )

        let lookback = max(64 * 1024, lookbackBytes)
        let seekKeep = seekKeepForwardBytes > 0
            ? seekKeepForwardBytes
            : max(AetherSourceBufferStock.seekKeepForwardBytes, low / 2)

        return AetherResolvedWatermarks(
            lowWaterBytes: low,
            highWaterBytes: high,
            hardCapBytes: hardCap,
            lookbackBytes: lookback,
            seekKeepForwardBytes: seekKeep,
            bytesPerSecond: bytesPerSecond,
            reason: reason
        )
    }
}

/// Process-global, host-settable tuning channel for the source buffer policy.
///
/// A global rather than constructor plumbing on purpose: readers are created deep inside
/// `Demuxer.openHTTP` from an `OpenProfile`, and the host (the FlexUI native module) needs to
/// change these AT RUNTIME on an already-playing session without another native build
/// (AGENTS.md: "Before requesting or triggering a native build ... verify that each item can be
/// changed after installation"). Readers re-read the policy on every connection start and on every
/// watermark recomputation, so a mid-playback change takes effect at the next fill cycle.
public enum AetherSourceBuffer {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _policy = AetherSourceBufferPolicy.stock
    nonisolated(unsafe) private static var _lastApplied = AetherResolvedWatermarks.stock

    /// Host-settable policy. Thread-safe; readable from the demux thread and any delegate queue.
    public static var policy: AetherSourceBufferPolicy {
        get { lock.lock(); defer { lock.unlock() }; return _policy }
        set {
            lock.lock()
            let changed = _policy != newValue
            _policy = newValue
            lock.unlock()
            if changed {
                EngineLog.emit(
                    "[SourceBuffer] policy set enabled=\(newValue.enabled) "
                    + "low=\(newValue.lowWaterSeconds)s high=\(newValue.highWaterSeconds)s "
                    + "keepWarm=\(newValue.keepWarmSeconds)s "
                    + "maxWindowMB=\(newValue.maxWindowBytes / 1024 / 1024) "
                    + "ring=\(newValue.useBlockRing) blockKB=\(newValue.blockSizeBytes / 1024)",
                    category: .demux)
            }
        }
    }

    /// What the PLAYBACK reader most recently installed. This is the JS-visible "what did the
    /// installed binary actually apply" answer; it is never the requested value.
    public static var lastApplied: AetherResolvedWatermarks {
        get { lock.lock(); defer { lock.unlock() }; return _lastApplied }
    }

    static func recordApplied(_ resolved: AetherResolvedWatermarks) {
        lock.lock()
        _lastApplied = resolved
        lock.unlock()
    }

    // MARK: - Session telemetry
    //
    // Process-global rather than plumbed through Demuxer -> SoftwarePlaybackHost -> memprobe,
    // for the same reason `policy` is: the reader that owns these numbers sits three layers below
    // the diagnostics emitter, and only the PRIMARY playback reader writes them.

    nonisolated(unsafe) private static var _suspends = 0
    nonisolated(unsafe) private static var _keepWarmResumes = 0
    nonisolated(unsafe) private static var _underruns = 0

    /// Zero the counters for a new playback source. Called when the primary reader opens.
    public static func beginSession() {
        lock.lock()
        _suspends = 0
        _keepWarmResumes = 0
        _underruns = 0
        lock.unlock()
    }

    static func noteSuspend() { lock.lock(); _suspends += 1; lock.unlock() }
    static func noteKeepWarmResume() { lock.lock(); _keepWarmResumes += 1; lock.unlock() }
    static func noteUnderrun() { lock.lock(); _underruns += 1; lock.unlock() }

    /// `suspends` = transfer parks (each one is a restart opportunity), `keepWarmResumes` = early
    /// wakes that avoided a long cold park, `underruns` = times the forward buffer hit empty at
    /// the read cursor, i.e. the events that become visible freezes.
    public static var telemetry: (suspends: Int, keepWarmResumes: Int, underruns: Int) {
        lock.lock(); defer { lock.unlock() }
        return (_suspends, _keepWarmResumes, _underruns)
    }

    /// Compact memprobe fragment. Empty while the policy is off so the stock log is unchanged.
    public static func probeFragment() -> String {
        let p = policy
        guard p.enabled else { return "" }
        let a = lastApplied
        let t = telemetry
        return "bufLowMB=\(a.lowWaterBytes / 1024 / 1024) "
            + "bufHighMB=\(a.highWaterBytes / 1024 / 1024) "
            + String(format: "bufLowS=%.1f bufHighS=%.1f ", a.lowWaterSeconds, a.highWaterSeconds)
            + "bufReason=\(a.reason) "
            + "bufSusp=\(t.suspends) bufWarm=\(t.keepWarmResumes) bufUnder=\(t.underruns) "
    }

    /// One-line applied-state summary for the host bridge / memprobe.
    public static func appliedDescription() -> String {
        let p = policy
        let a = lastApplied
        let kbps = a.bytesPerSecond > 0 ? Int((a.bytesPerSecond * 8 / 1000).rounded()) : 0
        return "enabled=\(p.enabled) reason=\(a.reason) "
            + "lowMB=\(a.lowWaterBytes / 1024 / 1024) highMB=\(a.highWaterBytes / 1024 / 1024) "
            + "hardCapMB=\(a.hardCapBytes / 1024 / 1024) "
            + String(format: "lowS=%.1f highS=%.1f ", a.lowWaterSeconds, a.highWaterSeconds)
            + "srcKbps=\(kbps) keepWarmS=\(p.keepWarmSeconds) ring=\(p.useBlockRing)"
    }
}
