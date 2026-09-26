import Foundation
import UIKit

/// One queue entry for a composited native video engine (VLC or Aether). Ordinals index the
/// server-reported audio/subtitle streams; language/title are the fallback match when an engine
/// numbers tracks differently.
public struct FlexVideoQueueItem {
    public let url: URL
    public let ratingKey: String
    public let title: String
    public let audioOrdinal: Int
    public let subtitleOrdinal: Int
    public let audioLanguage: String
    public let audioTitle: String
    public let subtitleLanguage: String
    public let subtitleTitle: String

    public init(url: URL, ratingKey: String, title: String,
                audioOrdinal: Int, subtitleOrdinal: Int,
                audioLanguage: String, audioTitle: String,
                subtitleLanguage: String, subtitleTitle: String) {
        self.url = url
        self.ratingKey = ratingKey
        self.title = title
        self.audioOrdinal = audioOrdinal
        self.subtitleOrdinal = subtitleOrdinal
        self.audioLanguage = audioLanguage
        self.audioTitle = audioTitle
        self.subtitleLanguage = subtitleLanguage
        self.subtitleTitle = subtitleTitle
    }
}

/// Per-play options. The `vlc*` fields are VLC-only tuning and are ignored by other engines;
/// `headers`/`cookies` are what AVPlayer receives on the plain lane (VLC authenticates via URL).
public struct FlexVideoPlayOptions {
    public var startPositionMs: Int = 0
    public var headers: [String: String] = [:]
    public var cookies: [HTTPCookie] = []
    public var vlcAvformatDemux = false
    public var vlcDiagnostics = true
    public var vlcDecoderMode = "auto"
    public var vlcNetworkCachingMs = 0
    public var vlcFramePolicy = "stock"

    public init() {}
}

/// The engine surface NativePlayerPlugin drives. VlcEngine lives in this pod; the Aether engine
/// lives in the App target (AetherEngine is a Swift Package, which a CocoaPod cannot depend on)
/// and is handed in through `FlexVideoEngineRegistry` at launch.
public protocol FlexVideoEngine: AnyObject {
    /// "vlc" or "aether" — used in logs and to decide whether an engine can be reused.
    var engineName: String { get }

    var onProgress: ((_ ratingKey: String, _ positionMs: Int, _ durationMs: Int, _ playing: Bool) -> Void)? { get set }
    var onEnded: ((_ ratingKey: String) -> Void)? { get set }
    var onItemChanged: ((_ ratingKey: String, _ index: Int) -> Void)? { get set }
    var onError: ((_ ratingKey: String, _ message: String) -> Void)? { get set }
    var onTracksChanged: (() -> Void)? { get set }
    var onPictureInPictureStateChanged: ((_ active: Bool) -> Void)? { get set }
    var onLog: ((String) -> Void)? { get set }

    var currentRatingKey: String { get }
    var isPlaying: Bool { get }
    var positionMs: Int { get }
    var durationMs: Int { get }

    /// drawable nil = audio-only (no video surface).
    func play(items: [FlexVideoQueueItem], startIndex: Int, options: FlexVideoPlayOptions, drawable: UIView?)
    func append(items: [FlexVideoQueueItem])
    /// Completion runs once the engine has released its output; only then may the drawable go.
    func stop(keepDrawable: Bool, completion: (() -> Void)?)

    func pause()
    func resume()
    func seek(toMs ms: Int)
    func seekBy(deltaMs: Int)
    func setRate(_ rate: Float)
    func setVolume(_ volume: Float)
    func next()
    func previousRestart()

    /// Rows in the shape the web client reads: type ("audio"|"text"), groupIndex (0|1),
    /// trackIndex (the id passed back to select*), language, label, selected.
    func trackList() -> [[String: Any]]
    func selectAudioTrack(id: Int)
    /// nil = subtitles off.
    func selectTextTrack(id: Int?)

    func requestPictureInPicture() -> Bool
    func stopPictureInPicture()
    func setCropRatio(_ ratio: Double)
    func relayout()
}

/// Engines that cannot live in this pod register themselves here from the App target.
public enum FlexVideoEngineRegistry {
    public static var aetherFactory: (() -> FlexVideoEngine)?
}
