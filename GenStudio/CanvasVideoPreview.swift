import AppKit
import AVFoundation
import Observation
import SwiftUI

/// A clip shown on a canvas card. It fills the card's preview at the clip's own
/// shape, starts from a poster frame, and plays from one clear button. The player is
/// only created on the first play, so a canvas of video cards stays cheap to draw.
/// Full transport controls stay in the expanded viewer.
struct CanvasVideoPreview: View {
    let url: URL
    @State private var playback: CanvasVideoPlayback?
    @State private var poster: CGImage?

    var body: some View {
        ZStack {
            Color.black
            if let poster {
                Image(decorative: poster, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .accessibilityHidden(true)
            }
            if let playback { CanvasPlayerLayer(player: playback.player) }
        }
        .allowsHitTesting(false)
        .overlay { if playback?.isPlaying != true { playButton } }
        .overlay(alignment: .bottomTrailing) { if playback?.isPlaying == true { pauseButton } }
        .overlay(alignment: .bottom) { if let playback, playback.progress > 0 { CanvasPlaybackProgress(playback: playback) } }
        .clipShape(RoundedRectangle(cornerRadius: NodeLayout.previewCornerRadius))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video preview: \(url.lastPathComponent)")
        .task(id: url) {
            playback?.tearDown(); playback = nil
            poster = CanvasVideoPosterCache.cached(url)
            if poster == nil { poster = await CanvasVideoPosterCache.load(url) }
            if let poster, poster.height > 0 {
                NodeLayout.videoAspectRatios.record(Double(poster.width) / Double(poster.height), for: url)
            }
        }
        .onDisappear { playback?.tearDown(); playback = nil }
    }

    private var playButton: some View {
        Button(action: play) {
            Image(systemName: "play.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .offset(x: 1.5)
                .frame(width: 46, height: 46)
                .background(.black.opacity(0.5), in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Play")
        .accessibilityLabel("Play video")
    }

    private var pauseButton: some View {
        Button { playback?.pause() } label: {
            Image(systemName: "pause.fill")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(.black.opacity(0.6), in: Circle())
                .overlay(Circle().stroke(.white.opacity(0.3), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .padding(8)
        .help("Pause")
        .accessibilityLabel("Pause video")
    }

    private func play() {
        if playback == nil { playback = CanvasVideoPlayback(url: url) }
        playback?.play()
    }
}

/// Playback state for one canvas clip. Stops at the end and rewinds, so the next
/// press replays the take instead of sitting on its last frame.
@MainActor @Observable
final class CanvasVideoPlayback {
    let player: AVPlayer
    private(set) var isPlaying = false
    private(set) var progress = 0.0
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?

    init(url: URL) {
        player = AVPlayer(url: url)
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.update(time) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rewind() }
        }
    }

    func play() { player.play(); isPlaying = true }
    func pause() { player.pause(); isPlaying = false }

    func tearDown() {
        pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil; endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    private func rewind() {
        isPlaying = false; progress = 0
        player.seek(to: .zero)
    }

    private func update(_ time: CMTime) {
        guard isPlaying, let duration = player.currentItem?.duration, duration.isNumeric, duration.seconds > 0 else { return }
        progress = min(max(time.seconds / duration.seconds, 0), 1)
    }
}

private struct CanvasPlaybackProgress: View {
    let playback: CanvasVideoPlayback
    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.18))
                Rectangle().fill(.white.opacity(0.9)).frame(width: proxy.size.width * playback.progress)
            }
        }
        .frame(height: 3)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// `AVPlayerLayer` without AVKit's control bar, which is too dense for a canvas card
/// and competes with card selection and dragging. It never takes clicks itself.
private struct CanvasPlayerLayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> CanvasPlayerLayerView {
        let view = CanvasPlayerLayerView()
        view.playerLayer.player = player
        return view
    }
    func updateNSView(_ view: CanvasPlayerLayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
    static func dismantleNSView(_ view: CanvasPlayerLayerView, coordinator: ()) { view.playerLayer.player = nil }
}

private final class CanvasPlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        playerLayer.videoGravity = .resizeAspect
        // Clear until the first frame arrives, so the poster underneath shows through.
        playerLayer.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// First frames of canvas clips. Generated takes are immutable files, so a small cache
/// keyed by path means a redraw or a scroll back never re-decodes a poster.
@MainActor
enum CanvasVideoPosterCache {
    private static var posters: [String: CGImage] = [:]
    private static var order: [String] = []

    static func cached(_ url: URL) -> CGImage? { posters[url.standardizedFileURL.path] }

    static func load(_ url: URL) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        guard let image = try? await generator.image(at: .zero).image else { return nil }
        let key = url.standardizedFileURL.path
        if posters[key] == nil { order.append(key) }
        posters[key] = image
        if order.count > 32 { posters.removeValue(forKey: order.removeFirst()) }
        return image
    }
}
