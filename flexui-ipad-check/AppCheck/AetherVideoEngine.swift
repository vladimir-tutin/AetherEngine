import AVFoundation
import AVKit
import Combine
import Foundation
import MediaPlayer
import UIKit
import AetherEngine
import FlexuiNative

//
// AetherVideoEngine — the AetherEngine playback lane for the iPad/iPhone app.
//
// Why it exists: VLC on iPad could not hold 4K Dolby Vision (P7) + TrueHD direct play — it decoded
// every frame but dropped ~2/s at display from the first second, then stalled and skipped. Aether
// demuxes with FFmpeg, decodes on VideoToolbox and presents through Apple's own display layers,
// the same shape Plex's player uses, and it is the engine the Apple TV app already direct-plays with.
//
// Lives in the App target, not the FlexuiNative pod: AetherEngine is a Swift Package and a CocoaPod
// cannot depend on one. Registered at launch through FlexVideoEngineRegistry (AppDelegate).
//
// Linked as the fork's DYNAMIC product (AetherEngineDynamic). VLCKit's dylib exports the same
// av*/sws* symbols as AetherLib*; with the engine linked statically into this executable those
// calls were bound at the app's link where VLCKit sorts first (build 83: 105 of them, so TrueHD had
// no decoder). As its own framework the engine binds them when IT links, against AetherLib*.
// Audio-only sessions (no drawable) serve music; live HLS is a plain load.
//
// JS chooses the engine per play() (queue item `engine`), so switching back to VLC never needs a
// native rebuild. UNVERIFIED on device at the time of writing.
//
@MainActor
final class AetherVideoEngine: NSObject {

    // MARK: FlexVideoEngine callbacks
    var onProgress: ((_ ratingKey: String, _ positionMs: Int, _ durationMs: Int, _ playing: Bool) -> Void)?
    var onEnded: ((_ ratingKey: String) -> Void)?
    var onItemChanged: ((_ ratingKey: String, _ index: Int) -> Void)?
    var onError: ((_ ratingKey: String, _ message: String) -> Void)?
    var onTracksChanged: (() -> Void)?
    var onPictureInPictureStateChanged: ((_ active: Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private var engine: AetherEngine?
    private let surface = AetherPlayerView(frame: .zero)
    private let cropHostView = UIView()
    private let subtitleLabel = UILabel()
    private let subtitleImageView = UIImageView()
    private weak var container: UIView?

    private var queue: [FlexVideoQueueItem] = []
    private var currentIndex = 0
    private var options = FlexVideoPlayOptions()
    private var subscriptions = Set<AnyCancellable>()
    private var loadTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var tick = 0
    private var cropRatio: Double = 0
    private var latestCues: [SubtitleCue] = []
    private var endedHandledForIndex = -1
    private var loadStartedAt: CFTimeInterval = 0
    /// An audio switch the load could not express. Issued once playback is actually running: a
    /// switch requested before the clock anchors is dropped by the engine (measured: at=0.000s).
    private var pendingAudioTrackID: Int?
    /// No drawable: audio-only session (music). No surface, subtitles or PiP.
    private var isAudioSession = false

    private var pipController: AVPictureInPictureController?
    private var pipPlaybackDelegate: SoftwarePiPPlaybackDelegate?

    // Engine log forwarding is rate-limited: the web layer relays every line into the server log.
    private var logWindowStart: CFTimeInterval = 0
    private var logWindowCount = 0
    private var logDropped = 0
    private static let maxEngineLogLinesPerSecond = 40

    override init() {
        super.init()
        cropHostView.backgroundColor = .black
        cropHostView.clipsToBounds = true
        cropHostView.isUserInteractionEnabled = false
        surface.backgroundColor = .black
        surface.isUserInteractionEnabled = false
        cropHostView.addSubview(surface)

        subtitleImageView.contentMode = .scaleToFill
        subtitleImageView.isHidden = true
        subtitleImageView.isUserInteractionEnabled = false

        subtitleLabel.numberOfLines = 0
        subtitleLabel.textAlignment = .center
        subtitleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        subtitleLabel.layer.shadowColor = UIColor.black.cgColor
        subtitleLabel.layer.shadowOpacity = 1
        subtitleLabel.layer.shadowRadius = 2
        subtitleLabel.layer.shadowOffset = .zero
        subtitleLabel.isHidden = true
        subtitleLabel.isUserInteractionEnabled = false

        EngineLog.handler = { [weak self] line in
            Task { @MainActor [weak self] in self?.forwardEngineLog(line) }
        }
    }

    // MARK: - Lifecycle

    func play(items: [FlexVideoQueueItem], startIndex: Int, options: FlexVideoPlayOptions, drawable: UIView?) {
        guard !items.isEmpty else { return }
        queue = items
        currentIndex = min(max(0, startIndex), items.count - 1)
        self.options = options
        isAudioSession = drawable == nil
        attach(to: drawable)
        startCurrent(startPositionMs: options.startPositionMs)
    }

    func append(items: [FlexVideoQueueItem]) {
        queue.append(contentsOf: items)
    }

    func stop(keepDrawable: Bool, completion: (() -> Void)?) {
        log("[AetherHost] action=stop rk=\(currentRatingKey) keepDrawable=\(keepDrawable ? 1 : 0)")
        loadTask?.cancel()
        loadTask = nil
        progressTimer?.invalidate()
        progressTimer = nil
        teardownPictureInPicture()
        subscriptions.removeAll()
        engine?.stop()
        engine = nil
        latestCues = []
        subtitleLabel.isHidden = true
        subtitleImageView.isHidden = true
        if !keepDrawable {
            cropHostView.removeFromSuperview()
            subtitleLabel.removeFromSuperview()
            subtitleImageView.removeFromSuperview()
            container = nil
        }
        // Aether's stop is synchronous for the host: the display layer is detached on return.
        DispatchQueue.main.async { completion?() }
    }

    private func attach(to drawable: UIView?) {
        guard let drawable else { return }
        if container !== drawable {
            cropHostView.removeFromSuperview()
            subtitleImageView.removeFromSuperview()
            subtitleLabel.removeFromSuperview()
            drawable.addSubview(cropHostView)
            drawable.addSubview(subtitleImageView)
            drawable.addSubview(subtitleLabel)
            container = drawable
        }
        applyCropLayout()
    }

    private func makeEngine() -> AetherEngine? {
        do {
            let created = try AetherEngine()
            created.videoGravity = .resizeAspect
            created.bind(view: surface)
            observe(created)
            return created
        } catch {
            log("[AetherHost] action=init-failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private func startCurrent(startPositionMs: Int) {
        guard currentIndex < queue.count else { return }
        let item = queue[currentIndex]
        loadTask?.cancel()
        progressTimer?.invalidate()
        teardownPictureInPicture()
        subscriptions.removeAll()
        engine?.stop()
        engine = makeEngine()
        guard let engine else {
            onError?(item.ratingKey, "AetherEngine could not be created")
            return
        }
        endedHandledForIndex = -1
        latestCues = []
        tick = 0
        pendingAudioTrackID = nil
        loadStartedAt = CACurrentMediaTime()

        var headers = options.headers
        if !options.cookies.isEmpty {
            for (key, value) in HTTPCookie.requestHeaderFields(with: options.cookies) where headers[key] == nil {
                headers[key] = value
            }
        }
        let startSeconds = startPositionMs > 1000 ? Double(startPositionMs) / 1000 : nil
        log("[AetherHost] action=load rk=\(item.ratingKey) startMs=\(startPositionMs) "
            + "headers=\(headers.keys.sorted().joined(separator: ",")) "
            + "audioOrdinal=\(item.audioOrdinal) audioStream=\(item.audioStreamIndex) "
            + "subtitleOrdinal=\(item.subtitleOrdinal) subtitleStream=\(item.subtitleStreamIndex) "
            + "session=\(isAudioSession ? "audio" : "video")")
        let audioStream: Int32? = item.audioStreamIndex >= 0 ? Int32(item.audioStreamIndex) : nil

        loadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let probe = try await engine.load(
                    url: item.url,
                    startPosition: startSeconds,
                    options: LoadOptions(
                        httpHeaders: headers,
                        matchContentEnabled: false,
                        autoplay: true
                    ),
                    audioSourceStreamIndex: audioStream
                )
                guard !Task.isCancelled, self.engine === engine else { return }
                let elapsedMs = Int((CACurrentMediaTime() - self.loadStartedAt) * 1000)
                self.log("[AetherHost] action=loaded rk=\(item.ratingKey) loadMs=\(elapsedMs) "
                         + "video=\(probe?.videoWidth ?? 0)x\(probe?.videoHeight ?? 0) "
                         + "duration=\(String(format: "%.1f", engine.duration))s "
                         + "audioTracks=\(engine.audioTracks.count) subtitleTracks=\(engine.subtitleTracks.count)")
                self.applyStartupSelection(item: item, engine: engine)
                if self.isAudioSession {
                    engine.setAudioNowPlayingInfo([MPMediaItemPropertyTitle: item.title])
                } else {
                    self.applyCropLayout()
                    self.preparePictureInPicture()
                }
                self.onItemChanged?(item.ratingKey, self.currentIndex)
                self.onTracksChanged?()
                self.startProgressTimer()
            } catch is CancellationError {
                return
            } catch {
                guard self.engine === engine else { return }
                self.log("[AetherHost] action=load-failed rk=\(item.ratingKey) error=\(error.localizedDescription)")
                self.onError?(item.ratingKey, "Aether load failed: \(error.localizedDescription)")
            }
        }
    }

    /// Plex's container stream index is Aether's track id, so the selection is exact. Audio was
    /// already opened by index at load; a mismatch (or an ordinal-only request) becomes a switch
    /// deferred until playback runs. Subtitles select immediately (no clock dependency).
    private func applyStartupSelection(item: FlexVideoQueueItem, engine: AetherEngine) {
        let audio = engine.audioTracks
        var audioTarget: TrackInfo?
        var audioVia = "none"
        if item.audioStreamIndex >= 0, let byIndex = audio.first(where: { $0.id == item.audioStreamIndex }) {
            audioTarget = byIndex
            audioVia = "stream-index"
        } else if item.audioOrdinal >= 0, item.audioOrdinal < audio.count {
            audioTarget = audio[item.audioOrdinal]
            audioVia = "ordinal"
        }
        if let target = audioTarget {
            let active = engine.activeAudioTrackIndex
            if active != target.id { pendingAudioTrackID = target.id }
            log("[AetherTracks] audio via=\(audioVia) id=\(target.id) codec=\(target.codec) ch=\(target.channels) "
                + "lang=\(target.language ?? "-") active=\(active.map(String.init) ?? "-") "
                + "decision=\(active == target.id ? "opened-at-load" : "deferred-switch")")
        }

        let subtitles = engine.subtitleTracks
        var subtitleTarget: TrackInfo?
        var subtitleVia = "none"
        if item.subtitleStreamIndex >= 0, let byIndex = subtitles.first(where: { $0.id == item.subtitleStreamIndex }) {
            subtitleTarget = byIndex
            subtitleVia = "stream-index"
        } else if item.subtitleOrdinal >= 0, item.subtitleOrdinal < subtitles.count {
            subtitleTarget = subtitles[item.subtitleOrdinal]
            subtitleVia = "ordinal"
        }
        if let target = subtitleTarget {
            engine.selectSubtitleTrack(index: target.id)
            log("[AetherTracks] subtitle via=\(subtitleVia) id=\(target.id) codec=\(target.codec) "
                + "lang=\(target.language ?? "-") decision=select")
        } else if item.subtitleOrdinal < 0 {
            engine.clearSubtitle()
        } else {
            log("[AetherTracks] subtitle ordinal=\(item.subtitleOrdinal) stream=\(item.subtitleStreamIndex) "
                + "tracks=\(subtitles.count) decision=none")
        }
    }

    /// Issue the deferred audio switch once the engine is playing past its start.
    private func applyPendingAudioSwitchIfReady(_ engine: AetherEngine) {
        guard let id = pendingAudioTrackID, engine.state == .playing, tick >= 1 else { return }
        pendingAudioTrackID = nil
        guard engine.activeAudioTrackIndex != id else { return }
        log("[AetherTracks] audio deferred-switch id=\(id) at=\(positionMs)ms")
        engine.selectAudioTrack(index: id)
    }

    // MARK: - Observation

    private func observe(_ engine: AetherEngine) {
        engine.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak engine] state in
                guard let self, let engine, self.engine === engine else { return }
                self.handle(state: state)
            }
            .store(in: &subscriptions)

        engine.$playbackPhase
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.log("[AetherPhase] phase=\(String(describing: phase)) t=\(self?.positionMs ?? 0)ms")
            }
            .store(in: &subscriptions)

        engine.$audioTracks
            .combineLatest(engine.$subtitleTracks)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.onTracksChanged?() }
            .store(in: &subscriptions)

        engine.$activeAudioTrackIndex
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.onTracksChanged?() }
            .store(in: &subscriptions)

        engine.$subtitleCues
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cues in
                guard let self else { return }
                self.latestCues = cues
                self.renderSubtitles()
            }
            .store(in: &subscriptions)

        engine.clock.$currentTime
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.renderSubtitles() }
            .store(in: &subscriptions)

        engine.$sourceVideoWidth
            .combineLatest(engine.$sourceVideoHeight)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.applyCropLayout() }
            .store(in: &subscriptions)

        engine.$softwarePiPSource
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.preparePictureInPicture() }
            .store(in: &subscriptions)
    }

    private func handle(state: PlaybackState) {
        switch state {
        case .ended:
            guard endedHandledForIndex != currentIndex else { return }
            endedHandledForIndex = currentIndex
            let endedKey = currentRatingKey
            log("[AetherHost] action=ended rk=\(endedKey) index=\(currentIndex)/\(queue.count)")
            if currentIndex < queue.count - 1 {
                currentIndex += 1
                startCurrent(startPositionMs: 0)
            } else {
                progressTimer?.invalidate()
                progressTimer = nil
                onEnded?(endedKey)
            }
        case .error(let message):
            progressTimer?.invalidate()
            progressTimer = nil
            log("[AetherHost] action=error rk=\(currentRatingKey) message=\(message)")
            onError?(currentRatingKey, message)
        default:
            break
        }
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                self.onProgress?(self.currentRatingKey, self.positionMs, self.durationMs, self.isPlaying)
                self.tick += 1
                self.applyPendingAudioSwitchIfReady(engine)
                if self.tick % 2 == 0 {
                    self.log("[AetherStats] rk=\(self.currentRatingKey) tMs=\(self.positionMs) "
                             + "state=\(String(describing: engine.state)) "
                             + "phase=\(String(describing: engine.playbackPhase)) "
                             + "bufferedS=\(String(format: "%.1f", engine.clock.bufferedPosition)) "
                             + "audio=\(engine.activeAudioTrackIndex.map(String.init) ?? "-") "
                             + "pip=\(self.pipController?.isPictureInPictureActive == true ? 1 : 0)")
                }
            }
        }
    }

    // MARK: - State

    var currentRatingKey: String { currentIndex < queue.count ? queue[currentIndex].ratingKey : "" }
    var isPlaying: Bool { engine?.state == .playing }
    var positionMs: Int { Int(((engine?.currentTime ?? 0) * 1000).rounded()) }
    var durationMs: Int {
        let seconds = engine?.duration ?? 0
        return seconds.isFinite ? Int((seconds * 1000).rounded()) : 0
    }

    // MARK: - Transport

    func pause() { engine?.pause() }
    func resume() { engine?.play() }

    func seek(toMs ms: Int) {
        guard let engine else { return }
        let target = max(0, Double(ms) / 1000)
        log("[AetherHost] action=seek from=\(positionMs)ms to=\(ms)ms")
        Task { @MainActor in await engine.seek(to: target) }
    }

    func seekBy(deltaMs: Int) { seek(toMs: max(0, positionMs + deltaMs)) }
    func setRate(_ rate: Float) { engine?.setRate(rate) }
    func setVolume(_ volume: Float) { engine?.volume = max(0, min(1, volume)) }

    func next() {
        guard currentIndex < queue.count - 1 else { return }
        currentIndex += 1
        startCurrent(startPositionMs: 0)
    }

    func previousRestart() { seek(toMs: 0) }

    // MARK: - Tracks

    func trackList() -> [[String: Any]] {
        guard let engine else { return [] }
        var rows: [[String: Any]] = []
        for track in engine.audioTracks {
            rows.append(["type": "audio", "groupIndex": 0, "trackIndex": track.id,
                         "language": track.language ?? "", "label": audioLabel(track),
                         "selected": track.id == engine.activeAudioTrackIndex])
        }
        for track in engine.subtitleTracks {
            rows.append(["type": "text", "groupIndex": 1, "trackIndex": track.id,
                         "language": track.language ?? "",
                         "label": track.name.isEmpty ? "Subtitle" : track.name,
                         "selected": track.id == engine.activeSubtitleTrackIndex])
        }
        return rows
    }

    private func audioLabel(_ track: TrackInfo) -> String {
        let base = track.name.isEmpty ? "Audio" : track.name
        return track.isAtmos && !base.localizedCaseInsensitiveContains("atmos") ? "\(base) (Atmos)" : base
    }

    func selectAudioTrack(id: Int) {
        guard let engine, engine.audioTracks.contains(where: { $0.id == id }) else {
            log("[AetherTracks] audio select REJECTED id=\(id)")
            return
        }
        log("[AetherTracks] audio select id=\(id)")
        engine.selectAudioTrack(index: id)
    }

    func selectTextTrack(id: Int?) {
        guard let engine else { return }
        guard let id else {
            engine.clearSubtitle()
            log("[AetherTracks] subtitle off")
            return
        }
        guard engine.subtitleTracks.contains(where: { $0.id == id }) else {
            log("[AetherTracks] subtitle select REJECTED id=\(id)")
            return
        }
        log("[AetherTracks] subtitle select id=\(id)")
        engine.selectSubtitleTrack(index: id)
    }

    // MARK: - Subtitles (host overlay; the engine publishes cues on the source axis)

    private func renderSubtitles() {
        guard let engine, !isAudioSession else { return }
        let now = engine.sourceTime
        let active = latestCues.filter { now >= $0.startTime && now < $0.endTime }
        var texts: [String] = []
        var image: SubtitleImage?
        for cue in active {
            switch cue.body {
            case .text(let text): texts.append(text)
            case .richText(let runs): texts.append(runs.map(\.text).joined())
            case .image(let img): image = img
            }
        }
        let text = texts.joined(separator: "\n")
        subtitleLabel.text = text
        subtitleLabel.isHidden = text.isEmpty
        if let image {
            subtitleImageView.image = UIImage(cgImage: image.cgImage)
            subtitleImageView.frame = frameForBitmap(image)
            subtitleImageView.isHidden = false
        } else {
            subtitleImageView.isHidden = true
            subtitleImageView.image = nil
        }
        layoutSubtitleLabel()
    }

    private func layoutSubtitleLabel() {
        guard let container, !subtitleLabel.isHidden else { return }
        let rect = videoRect(in: container.bounds)
        let maxWidth = rect.width * 0.88
        let size = subtitleLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        subtitleLabel.frame = CGRect(x: rect.midX - size.width / 2,
                                     y: rect.maxY - size.height - max(24, rect.height * 0.06),
                                     width: size.width, height: size.height)
    }

    /// Bitmap cue position is expressed on its canvas (the video's coded frame); map it onto the
    /// on-screen video rect.
    private func frameForBitmap(_ image: SubtitleImage) -> CGRect {
        guard let container else { return .zero }
        let rect = videoRect(in: container.bounds)
        let canvas = image.canvasSize.width > 0 && image.canvasSize.height > 0
            ? image.canvasSize
            : CGSize(width: CGFloat(max(1, engine?.sourceVideoWidth ?? 1)),
                     height: CGFloat(max(1, engine?.sourceVideoHeight ?? 1)))
        let sx = rect.width / canvas.width
        let sy = rect.height / canvas.height
        return CGRect(x: rect.minX + image.position.minX * sx,
                      y: rect.minY + image.position.minY * sy,
                      width: image.position.width * sx,
                      height: image.position.height * sy)
    }

    // MARK: - Geometry / crop

    /// The on-screen rect of the fitted (or cropped) picture inside the container.
    private func videoRect(in bounds: CGRect) -> CGRect {
        guard let engine, engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 else { return bounds }
        let aspect = CGFloat(Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio)
            / CGFloat(engine.sourceVideoHeight)
        if cropRatio > 0 { return cropHostView.frame }
        let fitW = min(bounds.width, bounds.height * aspect)
        let fitH = fitW / aspect
        return CGRect(x: bounds.midX - fitW / 2, y: bounds.midY - fitH / 2, width: fitW, height: fitH)
    }

    func setCropRatio(_ ratio: Double) {
        cropRatio = ratio
        applyCropLayout()
    }

    func relayout() { applyCropLayout() }

    /// Same geometry as the VLC lane: the host view clips to the target display aspect, and the
    /// surface inside it is sized to the video's aspect so the fitted picture covers the crop box.
    private func applyCropLayout() {
        guard let container else { return }
        let bounds = container.bounds
        guard cropRatio > 0, let engine, engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 else {
            cropHostView.frame = bounds
            surface.frame = cropHostView.bounds
            layoutSubtitleLabel()
            return
        }
        let boxW = min(bounds.width, bounds.height * CGFloat(cropRatio))
        let boxH = boxW / CGFloat(cropRatio)
        cropHostView.frame = CGRect(x: bounds.midX - boxW / 2, y: bounds.midY - boxH / 2, width: boxW, height: boxH)
        let aspect = CGFloat(Double(engine.sourceVideoWidth) * engine.sourceVideoPixelAspectRatio)
            / CGFloat(engine.sourceVideoHeight)
        var fw = boxW
        var fh = fw / aspect
        if fh < boxH { fh = boxH; fw = fh * aspect }
        surface.frame = CGRect(x: (boxW - fw) / 2, y: (boxH - fh) / 2, width: fw, height: fh)
        layoutSubtitleLabel()
    }

    // MARK: - Picture in Picture

    private func preparePictureInPicture() {
        guard let engine, !isAudioSession, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        if pipController != nil { return }
        if let layer = engine.nativePlayerLayer {
            pipController = AVPictureInPictureController(playerLayer: layer)
            log("[AetherPiP] prepared source=native-player-layer")
        } else if let source = engine.softwarePiPSource {
            let delegate = SoftwarePiPPlaybackDelegate(source: source)
            pipPlaybackDelegate = delegate
            let content = AVPictureInPictureController.ContentSource(
                sampleBufferDisplayLayer: source.layer, playbackDelegate: delegate)
            pipController = AVPictureInPictureController(contentSource: content)
            log("[AetherPiP] prepared source=software-sample-buffer")
        } else {
            return
        }
        pipController?.delegate = self
        pipController?.canStartPictureInPictureAutomaticallyFromInline = true
    }

    private func teardownPictureInPicture() {
        if pipController?.isPictureInPictureActive == true { pipController?.stopPictureInPicture() }
        pipController?.delegate = nil
        pipController = nil
        pipPlaybackDelegate = nil
        engine?.pictureInPictureActive = false
    }

    func requestPictureInPicture() -> Bool {
        if pipController == nil { preparePictureInPicture() }
        guard let controller = pipController else { return false }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
            return true
        }
        guard controller.isPictureInPicturePossible else { return false }
        controller.startPictureInPicture()
        return true
    }

    func stopPictureInPicture() {
        if pipController?.isPictureInPictureActive == true { pipController?.stopPictureInPicture() }
    }

    // MARK: - Logging

    private func log(_ message: String) {
        onLog?(message)
    }

    private func forwardEngineLog(_ line: String) {
        let now = CACurrentMediaTime()
        if now - logWindowStart >= 1 {
            if logDropped > 0 { onLog?("[AetherEngine] (rate limit dropped \(logDropped) lines)") }
            logWindowStart = now
            logWindowCount = 0
            logDropped = 0
        }
        guard logWindowCount < Self.maxEngineLogLinesPerSecond else {
            logDropped += 1
            return
        }
        logWindowCount += 1
        onLog?("[AetherEngine] \(line)")
    }
}

extension AetherVideoEngine: @preconcurrency FlexVideoEngine {
    var engineName: String { "aether" }
}

extension AetherVideoEngine: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            engine?.pictureInPictureActive = true
            log("[AetherPiP] action=start")
            onPictureInPictureStateChanged?(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            engine?.pictureInPictureActive = false
            log("[AetherPiP] action=stop")
            onPictureInPictureStateChanged?(false)
        }
    }
}

/// Transport answers for sample-buffer PiP on the software path, delegated to the engine's
/// `SoftwarePiPSource` (which knows the enqueued frames' time axis).
@MainActor
private final class SoftwarePiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let source: SoftwarePiPSource

    init(source: SoftwarePiPSource) { self.source = source }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated { source.setPlaying(playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated { source.timeRange() }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { source.isPaused }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { source.skip(by: skipInterval.seconds) }
        completionHandler()
    }
}
