import SwiftUI
import AVFoundation
import Photos

/// Everything the screen shows and does. No posting anywhere: videos stay on the phone until you save or share them.
final class Studio: ObservableObject {
    @Published var songURL: URL?
    @Published var songName = ""
    @Published var cover: UIImage?
    @Published var thickness = 0.75 { didSet { rebuild() } }
    @Published var length = 0.9 { didSet { rebuild() } }
    @Published var dots = true { didSet { rebuild() } }
    @Published var maxSeconds = 30 { didSet { rebuild(); clampTime() } }
    @Published var isAnalyzing = false
    @Published var isPlaying = false
    @Published var pausedTime = 0.0
    @Published var exportProgress: Double?
    @Published var exportedURL: URL?
    @Published var status: String?
    @Published var error: String?

    private(set) var renderer: FrameRenderer
    private var analysis = Analysis.demo()
    private var centerImage: CGImage?
    private var player: AVPlayer?
    private var observer: Any?
    private let demoStart = Date()

    init() {
        let c = FrameRenderer.prepareCenter(nil)
        centerImage = c
        renderer = FrameRenderer(analysis: Analysis.demo(), look: LookParams(), center: c)
        try? AVAudioSession.sharedInstance().setCategory(.playback)
    }

    var hasSong: Bool { songURL != nil }

    /// Length of the video that will be made.
    var clip: Double {
        let full = analysis.duration
        return maxSeconds > 0 ? min(Double(maxSeconds), full) : full
    }

    var currentTime: Double {
        if !hasSong { return Date().timeIntervalSince(demoStart).truncatingRemainder(dividingBy: analysis.duration) }
        if isPlaying, let p = player {
            let s = p.currentTime().seconds
            if s.isFinite { return min(max(0, s), clip) }
        }
        return pausedTime
    }

    private func rebuild() {
        renderer = FrameRenderer(analysis: analysis,
                                 look: LookParams(thickness: thickness, length: length, dots: dots),
                                 center: centerImage)
    }

    private func clampTime() {
        if pausedTime > clip { seek(0) }
    }

    // MARK: choosing things

    func loadSong(from url: URL) {
        pause()
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.isEmpty ? "m4a" : url.pathExtension
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("song-\(UUID().uuidString).\(ext)")
            try FileManager.default.copyItem(at: url, to: dest)
            songName = url.deletingPathExtension().lastPathComponent
            exportedURL = nil
            status = nil
            isAnalyzing = true
            Task.detached { [weak self] in
                do {
                    let result = try await AudioAnalyzer.analyze(url: dest)
                    DispatchQueue.main.async { self?.songReady(url: dest, analysis: result) }
                } catch {
                    DispatchQueue.main.async {
                        self?.isAnalyzing = false
                        self?.error = error.localizedDescription
                    }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func songReady(url: URL, analysis result: Analysis) {
        analysis = result
        songURL = url
        pausedTime = 0
        isAnalyzing = false
        if let o = observer, let p = player { p.removeTimeObserver(o) }
        let p = AVPlayer(url: url)
        observer = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] time in
            guard let self = self else { return }
            if self.isPlaying && time.seconds >= self.clip {
                self.pause()
                self.seek(0)
            }
        }
        player = p
        rebuild()
    }

    func setCover(_ image: UIImage) {
        cover = image
        centerImage = FrameRenderer.prepareCenter(image)
        exportedURL = nil
        rebuild()
    }

    // MARK: playback

    func togglePlay() { isPlaying ? pause() : play() }

    func play() {
        guard let p = player else { return }
        try? AVAudioSession.sharedInstance().setActive(true)
        if pausedTime >= clip - 0.05 { seek(0) }
        p.play()
        isPlaying = true
    }

    func pause() {
        if let p = player, isPlaying {
            let s = p.currentTime().seconds
            if s.isFinite { pausedTime = min(max(0, s), clip) }
            p.pause()
        }
        isPlaying = false
    }

    func seek(_ t: Double) {
        let v = min(max(0, t), clip)
        pausedTime = v
        player?.seek(to: CMTime(seconds: v, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    // MARK: making the video (manual: nothing is uploaded or posted)

    func makeVideo() {
        guard let url = songURL, exportProgress == nil else { return }
        pause()
        exportedURL = nil
        status = nil
        exportProgress = 0
        let r = renderer
        let dur = clip
        Task.detached { [weak self] in
            do {
                let out = try await Exporter.export(renderer: r, audioURL: url, duration: dur) { p in
                    DispatchQueue.main.async { self?.exportProgress = p }
                }
                DispatchQueue.main.async {
                    self?.exportedURL = out
                    self?.exportProgress = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self?.error = error.localizedDescription
                    self?.exportProgress = nil
                }
            }
        }
    }

    func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { auth in
            guard auth == .authorized || auth == .limited else {
                DispatchQueue.main.async { self.status = "Allow Photos access in Settings to save." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, err in
                DispatchQueue.main.async {
                    self.status = ok ? "Saved to Photos." : (err?.localizedDescription ?? "Couldn't save.")
                }
            }
        }
    }
}
