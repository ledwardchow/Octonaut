import AVKit
import Foundation
import Network
import Observation
import Photos
import SwiftUI
import UIKit
import WebKit

private struct OctonautExportableMedia: Identifiable {
    let id = UUID()
    let url: URL
}

private struct OctonautFileExporter: UIViewControllerRepresentable {
    let fileURL: URL
    let onSaved: () -> Void
    var onDismiss: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator {
        Coordinator(onSaved: onSaved, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onSaved: () -> Void
        let onDismiss: (() -> Void)?

        init(onSaved: @escaping () -> Void, onDismiss: (() -> Void)? = nil) {
            self.onSaved = onSaved
            self.onDismiss = onDismiss
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard !urls.isEmpty else { return }
            onSaved()
            onDismiss?()
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDismiss?()
        }
    }
}

private actor OctonautMediaSaveCoordinator {
    enum SaveError: LocalizedError {
        case downloadFailed
        case photoAccessDenied

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "The media could not be downloaded."
            case .photoAccessDenied: return "Allow Octonaut to add media to Photos in Settings, then try again."
            }
        }
    }

    private let fileManager = FileManager.default

    func downloadImage(from sourceURL: URL) async throws -> URL {
        let (temporaryURL, response) = try await URLSession.shared.download(from: sourceURL)
        if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            throw SaveError.downloadFailed
        }

        let fileExtension = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension
        let outputURL = fileManager.temporaryDirectory
            .appending(path: "OctonautImage-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try fileManager.moveItem(at: temporaryURL, to: outputURL)
        return outputURL
    }

    func saveToPhotos(fileURL: URL, isVideo: Bool) async throws {
        try await saveToPhotos(fileURLs: [fileURL], isVideo: isVideo)
    }

    func saveToPhotos(fileURLs: [URL], isVideo: Bool) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw SaveError.photoAccessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            for fileURL in fileURLs {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isVideo ? .video : .photo, fileURL: fileURL, options: nil)
            }
        }
    }
}

/// Why a player does or does not carry its post's audio.
///
/// Reddit serves DASH video and audio as separate files, and every step of
/// merging them can fail in a way that still produces a playable asset -- just
/// a silent one. Recording the outcome makes a failed mux distinguishable from
/// a video that genuinely has no sound.
enum OctonautMuxOutcome: Equatable, Sendable {
    /// No separate audio to merge: a GIF, or a self-contained file.
    case notApplicable
    case merged
    case videoOnly(reason: String)

    var failureReason: String? {
        if case .videoOnly(let reason) = self { return reason }
        return nil
    }
}

/// The default `soloAmbient` category interrupts other audio even when a feed
/// player is muted. Playback with mixing keeps other apps audible while feed
/// videos run and lets full screen video audio work with the silent switch on.
/// Every `AVAudioSession` call is a synchronous XPC round trip to
/// mediaserverd. Making those from the main thread on each viewer open and
/// close does not merely stall the UI -- under the churn of scrolling, opening
/// and dismissing repeatedly it takes the media server down with it, and once
/// that happens every AVPlayer in the process is dead and playback cannot
/// recover without relaunching:
///
///   AVAudioSession_iOS.mm:990  Invalid XPC connection, probably media server died
///   PlayerRemoteXPC signalled err=-12860 (repeatedly, thereafter)
///
/// So the work happens on a private serial queue, the category is set once
/// rather than per playback, activations are counted instead of toggled, and a
/// deactivation is allowed to settle first -- a quick dismiss-then-reopen never
/// reaches the session at all.
final class OctonautAudioSession: @unchecked Sendable {
    static let shared = OctonautAudioSession()

    /// All mutable state below is confined to this queue, which is what makes
    /// the unchecked `Sendable` conformance sound.
    private let queue = DispatchQueue(label: "com.octonaut.audio-session", qos: .userInitiated)
    private var isCategoryConfigured = false
    private var activations = 0
    private var pendingDeactivation: DispatchWorkItem?

    private init() {}

    static func prepareForMutedFeedPlayback() async {
        await withCheckedContinuation { continuation in
            shared.queue.async {
                shared.configureCategoryIfNeeded()
                continuation.resume()
            }
        }
    }

    static func activatePlayback() { shared.begin() }
    static func deactivate() { shared.end() }

    private func configureCategoryIfNeeded() {
        guard !isCategoryConfigured else { return }
        // A muted AVPlayer can still activate the app's audio session. Mix
        // with other apps so scrolling past a feed video leaves their audio on.
        do {
            try AVAudioSession.sharedInstance().setCategory(
                .playback,
                mode: .moviePlayback,
                options: [.mixWithOthers]
            )
            isCategoryConfigured = true
        } catch {
            // Retry on the next activation if mediaserverd is temporarily down.
        }
    }

    private func begin() {
        queue.async { [self] in
            pendingDeactivation?.cancel()
            pendingDeactivation = nil

            configureCategoryIfNeeded()

            activations += 1
            guard activations == 1 else { return }
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }

    private func end() {
        queue.async { [self] in
            activations = max(0, activations - 1)
            guard activations == 0 else { return }

            pendingDeactivation?.cancel()
            let work = DispatchWorkItem { [self] in
                guard activations == 0 else { return }
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: [.notifyOthersOnDeactivation])
                pendingDeactivation = nil
            }
            pendingDeactivation = work
            queue.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }
}

@MainActor
private enum OctonautAVPlayerFactory {
    fileprivate struct Playback {
        let player: AVPlayer
        let aspectRatio: CGFloat
        var muxOutcome: OctonautMuxOutcome = .notApplicable
    }

    static func makePlayer(videoURL: URL, audioURL: URL?) async -> Playback {
        let videoAsset = AVURLAsset(url: videoURL)
        let aspectRatio = await aspectRatio(for: videoAsset)
        guard let audioURL, audioURL != videoURL else {
            return Playback(
                player: localPlaybackPlayer(asset: videoAsset),
                aspectRatio: aspectRatio,
                muxOutcome: .notApplicable
            )
        }
        // Loading the two separately stops an audio failure -- the common
        // case, since the audio filename is guessed -- from being reported as
        // a video failure and from poisoning the video asset.
        let videoTracks: [AVAssetTrack]
        do {
            videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
        } catch is CancellationError {
            // A cancelled task is not a mux failure; the view is going away.
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .notApplicable
            )
        } catch {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "video track load failed: \(error.localizedDescription)")
            )
        }

        let audio = await loadAudio(preferred: audioURL, videoURL: videoURL)
        let audioAsset = audio.asset
        let audioTracks = audio.tracks
        if let failure = audio.failure {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: failure)
            )
        }
        guard let videoTrack = videoTracks.first else {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "asset has no video track")
            )
        }

        let composition = AVMutableComposition()
        guard let duration = try? await videoAsset.load(.duration) else {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "video duration unavailable")
            )
        }
        do {
            guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "could not add composition video track")
            )
            }
            try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
            compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)

            // An audio URL that yields no usable track is the quiet failure
            // worth surfacing: the video plays, just silently.
            guard let audioTrack = audioTracks.first else {
                return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "audio URL returned no audio track")
            )
            }
            guard let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "could not add composition audio track")
            )
            }
            let loadedAudioDuration = (try? await audioAsset.load(.duration)) ?? duration
            let audioDuration = CMTimeMinimum(duration, loadedAudioDuration)
            try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero)

            return Playback(
                player: localPlaybackPlayer(item: AVPlayerItem(asset: composition)),
                aspectRatio: aspectRatio,
                muxOutcome: .merged
            )
        } catch {
            return Playback(
                player: localPlaybackPlayer(url: videoURL),
                aspectRatio: aspectRatio,
                muxOutcome: .videoOnly(reason: "composition failed: \(error.localizedDescription)")
            )
        }
    }

    /// Reddit does not always publish the DASH audio filename the codec
    /// guesses from the video URL. The manifest is authoritative about which
    /// representations exist, so a miss is retried against it -- fetched only
    /// on failure, so the common case costs nothing.
    private static func loadAudio(
        preferred audioURL: URL,
        videoURL: URL
    ) async -> (asset: AVURLAsset, tracks: [AVAssetTrack], failure: String?) {
        if let hit = await audioTracks(at: audioURL) {
            return (hit.asset, hit.tracks, nil)
        }

        if let resolved = await manifestAudioURL(for: videoURL), resolved != audioURL {
            if let hit = await audioTracks(at: resolved) {
                return (hit.asset, hit.tracks, nil)
            }
            return (
                AVURLAsset(url: audioURL), [],
                "no audio at \(audioURL.lastPathComponent) or \(resolved.lastPathComponent)"
            )
        }

        return (
            AVURLAsset(url: audioURL), [],
            "no audio at \(audioURL.lastPathComponent); manifest lists none"
        )
    }

    private static func audioTracks(
        at url: URL
    ) async -> (asset: AVURLAsset, tracks: [AVAssetTrack])? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              !tracks.isEmpty else {
            return nil
        }
        return (asset, tracks)
    }

    private static func manifestAudioURL(for videoURL: URL) async -> URL? {
        guard let manifestURL = RedditDASHManifest.manifestURL(for: videoURL),
              let (data, _) = try? await URLSession.shared.data(from: manifestURL) else {
            return nil
        }
        return RedditDASHManifest.media(from: data, manifestURL: manifestURL)?.audio
    }

    /// Builds the fallback player from a fresh asset. The one whose load just
    /// failed carries that failure cached, and an item made from it can refuse
    /// to ever become ready to play -- a silent video would become no video.
    private static func localPlaybackPlayer(url: URL) -> AVPlayer {
        localPlaybackPlayer(item: AVPlayerItem(asset: AVURLAsset(url: url)))
    }

    private static func aspectRatio(for asset: AVAsset) async -> CGFloat {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let naturalSize = try? await track.load(.naturalSize),
              let preferredTransform = try? await track.load(.preferredTransform) else {
            return 16 / 9
        }
        let displaySize = naturalSize.applying(preferredTransform)
        let width = abs(displaySize.width)
        let height = abs(displaySize.height)
        guard width > 0, height > 0 else { return 16 / 9 }
        return width / height
    }

    private static func localPlaybackPlayer(asset: AVAsset) -> AVPlayer {
        localPlaybackPlayer(item: AVPlayerItem(asset: asset))
    }

    private static func localPlaybackPlayer(item: AVPlayerItem) -> AVPlayer {
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        player.audiovisualBackgroundPlaybackPolicy = .pauses
        return player
    }
}

/// Hands playback back and forth between a feed row and the full screen
/// viewer.
///
/// Two problems it solves. A feed row behind a `fullScreenCover` never gets
/// `onDisappear`, so without this it keeps playing underneath the viewer. And
/// the viewer builds its own `AVPlayer`, so without a shared playhead it would
/// always restart from zero rather than continuing from wherever the row had
/// reached.
@MainActor
@Observable
final class OctonautPlaybackCoordinator {
    static let shared = OctonautPlaybackCoordinator()

    /// While true the viewer owns playback and feed rows stay paused.
    private(set) var isFullScreenActive = false

    @ObservationIgnored private var positions: [URL: Double] = [:]
    @ObservationIgnored private let activateAudio: @MainActor () -> Void
    @ObservationIgnored private let deactivateAudio: @MainActor () -> Void

    init(
        activateAudio: @escaping @MainActor () -> Void = OctonautAudioSession.activatePlayback,
        deactivateAudio: @escaping @MainActor () -> Void = OctonautAudioSession.deactivate
    ) {
        self.activateAudio = activateAudio
        self.deactivateAudio = deactivateAudio
    }

    func position(for url: URL) -> Double? {
        positions[url]
    }

    func record(_ seconds: Double, for url: URL) {
        guard seconds.isFinite, seconds >= 0 else { return }
        positions[url] = seconds
    }

    func beginFullScreen() { isFullScreenActive = true }
    func endFullScreen() { isFullScreenActive = false }

    /// Feed rows autoplay muted unless the feed audio setting is enabled.
    /// A row claims audio while it plays so two visible rows cannot talk over
    /// each other.
    private(set) var audioOwner: URL?

    func isAudioOwner(_ url: URL) -> Bool { audioOwner == url }

    func claimAudio(for url: URL) {
        guard audioOwner != url else { return }
        if audioOwner == nil { activateAudio() }
        audioOwner = url
    }

    func releaseAudio(for url: URL) {
        guard audioOwner == url else { return }
        audioOwner = nil
        // The viewer has its own activation while it is audible.
        deactivateAudio()
    }
}

/// Warms the small media window immediately around the visible feed rows.
/// Prepared players stay paused until their row reports that it is on screen.
@MainActor
final class OctonautFeedMediaPreloader {
    private struct VideoKey: Hashable {
        let url: URL
        let audioURL: URL?
    }

    private enum MediaKey: Hashable {
        case image(URL)
        case video(VideoKey)
    }

    private let maximumMedia = 120
    private var imageTasks: [URL: Task<Void, Never>] = [:]
    private var videoTasks: [VideoKey: Task<OctonautAVPlayerFactory.Playback, Never>] = [:]
    private var mediaOrder: [MediaKey] = []

    func preload(posts: some Sequence<PostCardModel>, compact: Bool) {
        for post in posts {
            for url in imageURLs(for: post, compact: compact) {
                prepareImage(at: url)
            }
            if !compact,
               post.mediaKind == "video" || post.mediaKind == "gif",
               let url = post.mediaURL {
                prepareVideo(at: url, audioURL: post.audioURL)
            }
        }
    }

    fileprivate func playback(videoURL: URL, audioURL: URL?) async -> OctonautAVPlayerFactory.Playback {
        let key = VideoKey(url: videoURL, audioURL: audioURL)
        if let task = videoTasks[key] {
            return await task.value
        }
        return await prepareVideo(at: videoURL, audioURL: audioURL).value
    }

    private func prepareImage(at url: URL) {
        guard imageTasks[url] == nil else { return }
        imageTasks[url] = Task { @MainActor in
            _ = try? await OctonautImageCache.image(for: url)
        }
        mediaOrder.append(.image(url))
        trimPreparedMedia()
    }

    @discardableResult
    private func prepareVideo(
        at url: URL,
        audioURL: URL?
    ) -> Task<OctonautAVPlayerFactory.Playback, Never> {
        let key = VideoKey(url: url, audioURL: audioURL)
        if let task = videoTasks[key] { return task }

        let task = Task { @MainActor in
            await OctonautAudioSession.prepareForMutedFeedPlayback()
            let playback = await OctonautAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            _ = try? await playback.player.currentItem?.asset.load(.isPlayable)
            if playback.player.status == .readyToPlay {
                _ = await playback.player.preroll(atRate: 1)
            }
            playback.player.pause()
            return playback
        }
        videoTasks[key] = task
        mediaOrder.append(.video(key))
        trimPreparedMedia()
        return task
    }

    private func trimPreparedMedia() {
        while mediaOrder.count > maximumMedia {
            switch mediaOrder.removeFirst() {
            case .image(let expiredURL):
                imageTasks.removeValue(forKey: expiredURL)?.cancel()
            case .video(let expiredKey):
                // A visible row may still own this player. Removing the cache's
                // reference is enough; the row controls its playback lifecycle.
                videoTasks.removeValue(forKey: expiredKey)
            }
        }
    }

    private func imageURLs(for post: PostCardModel, compact: Bool) -> [URL] {
        if compact {
            if let thumbnailURL = post.thumbnailURL { return [thumbnailURL] }
            if let galleryURL = post.galleryURLs.first { return [galleryURL] }
            if post.mediaKind == "image", let mediaURL = post.mediaURL { return [mediaURL] }
            return []
        }

        switch post.mediaKind {
        case "gallery":
            return Array(post.galleryURLs.prefix(2))
        case "image":
            return post.mediaURL.map { [$0] } ?? []
        case "video", "gif", "embeddedVideo", "link":
            return post.thumbnailURL.map { [$0] } ?? []
        default:
            return []
        }
    }
}

/// A cached remote image with stable loading and failure states.
struct OctonautAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var tint: Color = .secondary
    @State private var image: UIImage?
    @State private var loadFailed = false

    @ViewBuilder
    var body: some View {
        Group {
            if url != nil {
                if let displayedImage {
                    Image(uiImage: displayedImage)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else if loadFailed {
                    ZStack {
                        Color(uiColor: .tertiarySystemBackground)
                        Image(systemName: "photo.slash")
                            .font(.title2)
                            .foregroundStyle(tint)
                    }
                } else {
                    ZStack {
                        Color(uiColor: .tertiarySystemBackground)
                        ProgressView().tint(tint)
                    }
                }
            } else {
                ZStack {
                    Color(uiColor: .tertiarySystemBackground)
                    Image(systemName: "photo.slash")
                        .font(.title2)
                        .foregroundStyle(tint)
                }
            }
        }
        .accessibilityLabel(url == nil ? "No image" : "Image")
        .task(id: url) {
            image = nil
            loadFailed = false
            guard let url else { return }
            do {
                let loadedImage = try await OctonautImageCache.image(for: url)
                guard !Task.isCancelled else { return }
                image = loadedImage
            } catch is CancellationError {
                return
            } catch {
                loadFailed = true
            }
        }
    }

    private var displayedImage: UIImage? {
        image ?? url.flatMap(OctonautImageCache.cachedImage(for:))
    }
}

/// Debug-build warning that a post's audio failed to merge. Reddit's DASH
/// audio is a separate file, and when merging it falls through one of the
/// fallback paths the video still plays -- silently. Without this, that is
/// indistinguishable from a post that simply has no sound.
///
/// Release builds render nothing; the whole body is compiled out.
struct OctonautMuxWarningBadge: View {
    let outcome: OctonautMuxOutcome

    var body: some View {
#if DEBUG
        if let reason = outcome.failureReason {
            Label(reason, systemImage: "speaker.slash.fill")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.yellow.opacity(0.92), in: RoundedRectangle(cornerRadius: 7))
                .padding(7)
                .allowsHitTesting(false)
                .accessibilityLabel("Debug: audio mux failed. \(reason)")
        }
#endif
    }
}

struct OctonautInlineMediaView: View {
    @Environment(AppDependencies.self) private var dependencies
    let post: PostCardModel
    var onOpen: ((Int) -> Void)?
    var preloader: OctonautFeedMediaPreloader?
    var maximumHeight: CGFloat? = nil
    @State private var isRevealed = false
    @State private var isVisibleInFeed = false
    @State private var networkStatus = OctonautNetworkStatus.shared

    private let gallerySpacing: CGFloat = 4
    private let galleryHeight: CGFloat = 220

    private var isSensitiveMedia: Bool {
        post.isSensitive(
            blurringNSFW: dependencies.settings.blurNSFWMedia,
            blurringSpoilers: dependencies.settings.blurSpoilers
        )
    }

    private var shouldBlurMedia: Bool { isSensitiveMedia && !isRevealed }

    private var inlineGalleryURLs: [URL] {
        if !post.galleryURLs.isEmpty { return post.galleryURLs }
        if let mediaURL = post.mediaURL { return [mediaURL] }
        return []
    }

    var body: some View {
        Group {
            if post.mediaKind == "video" || post.mediaKind == "gif", let url = post.mediaURL {
                ZStack {
                    if shouldBlurMedia {
                        ZStack {
                            Color.black
                            OctonautAsyncImage(url: post.thumbnailURL, contentMode: .fit)
                                .compositingGroup()
                                .blur(radius: 18)
                                .scaleEffect(1.08)
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        sensitiveRevealButton
                    } else {
                        OctonautVideoPlayer(
                            url: url,
                            audioURL: post.audioURL,
                            playAudio: dependencies.settings.playFeedVideoAudio,
                            autoplay: dependencies.settings.autoplayVideo.shouldAutoplay(
                                isConnectedViaWiFi: networkStatus.isConnectedViaWiFi
                            ) && (preloader == nil || isVisibleInFeed),
                            loops: post.mediaKind == "gif",
                            preloader: preloader
                        )
                        .overlay { openVideoButton }
                    }
                }
            } else if post.mediaKind == "embeddedVideo", let url = post.mediaURL,
                      let embedURL = EmbeddedVideoURL.embedURL(for: url) {
                ZStack {
                    if shouldBlurMedia {
                        ZStack {
                            Color.black
                            OctonautAsyncImage(url: post.thumbnailURL, contentMode: .fit)
                                .compositingGroup()
                                .blur(radius: 18)
                                .scaleEffect(1.08)
                        }
                        .aspectRatio(16 / 9, contentMode: .fit)
                        sensitiveRevealButton
                    } else {
                        OctonautEmbeddedVideoView(url: embedURL)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .overlay { openVideoButton }
                    }
                }
            } else if post.mediaKind == "gallery" || post.galleryURLs.count > 1 {
                GeometryReader { geometry in
                    let itemWidth = inlineGalleryURLs.count > 1
                        ? max((geometry.size.width - gallerySpacing) / 2, 1)
                        : geometry.size.width

                    ScrollView(.horizontal) {
                        LazyHStack(spacing: gallerySpacing) {
                            ForEach(Array(inlineGalleryURLs.enumerated()), id: \.offset) { index, url in
                                Button { openOrReveal(at: index) } label: {
                                    OctonautAsyncImage(url: url, contentMode: .fill)
                                        .frame(width: itemWidth, height: galleryHeight)
                                        .clipped()
                                        .background(.black.opacity(0.04))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(shouldBlurMedia)
                                .accessibilityLabel("Open image \(index + 1) of \(inlineGalleryURLs.count)")
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollIndicators(.hidden)
                    .blur(radius: shouldBlurMedia ? 12 : 0)
                    .overlay {
                        if shouldBlurMedia {
                            Button { isRevealed = true } label: { sensitiveOverlay }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Sensitive media. Tap to reveal.")
                        }
                    }
                    .overlay(alignment: .bottomTrailing) {
                        Label("\(inlineGalleryURLs.count) images", systemImage: "square.stack")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.black.opacity(0.58), in: Capsule())
                            .padding(9)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: galleryHeight)
            } else if post.mediaKind == "image" || post.mediaKind == "gif", let url = post.mediaURL {
                Button { openOrReveal(at: 0) } label: {
                    ZStack {
                        OctonautAsyncImage(url: url, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .frame(height: maximumHeight)
                            .blur(radius: shouldBlurMedia ? 12 : 0)
                        if shouldBlurMedia { sensitiveOverlay }
                    }
                }
                .buttonStyle(.plain)
            } else if post.mediaKind == "link" {
                let url = post.mediaURL ?? post.shareURL
                if shouldBlurMedia {
                    Button { isRevealed = true } label: {
                        linkCard(url: url, isBlurred: true)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sensitive link preview. Tap to reveal.")
                } else {
                    Link(destination: url) {
                        linkCard(url: url, isBlurred: false)
                    }
                    .buttonStyle(.plain)
                }
            } else if post.mediaKind == "unsupported" {
                Link(destination: post.mediaURL ?? post.shareURL) {
                    HStack(spacing: 10) {
                        Image(systemName: "safari").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open unsupported media").font(.subheadline.weight(.semibold))
                            Text((post.mediaURL ?? post.shareURL).host ?? "Reddit")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
            } else {
                OctonautMediaPlaceholder(
                    title: post.mediaTitle,
                    symbol: post.isVideo ? "play.fill" : "photo",
                    isBlurred: isSensitiveMedia,
                    action: { openOrReveal(at: 0) }
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .onScrollVisibilityChange(threshold: 0.01) { isVisible in
            isVisibleInFeed = isVisible
        }
        .onDisappear {
            isVisibleInFeed = false
        }
    }

    private var sensitiveOverlay: some View {
        VStack(spacing: 6) {
            Image(systemName: "eye.slash")
            Text("Tap to reveal")
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black.opacity(0.62))
        .accessibilityHidden(true)
    }

    private var sensitiveRevealButton: some View {
        Button { isRevealed = true } label: { sensitiveOverlay }
            .buttonStyle(.plain)
            .accessibilityLabel("Sensitive media. Tap to reveal.")
    }

    private var openVideoButton: some View {
        Button { openOrReveal(at: 0) } label: {
            Color.clear
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open video full screen")
    }

    private func linkCard(url: URL, isBlurred: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let thumbnailURL = post.thumbnailURL {
                ZStack {
                    OctonautAsyncImage(url: thumbnailURL, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: galleryHeight)
                        .background(.black.opacity(0.04))
                        .blur(radius: isBlurred ? 12 : 0)
                    if isBlurred { sensitiveOverlay }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "link.circle.fill").font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(post.mediaTitle.isEmpty ? "Open link" : post.mediaTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    Text(url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: isBlurred ? "eye" : "arrow.up.right")
            }
            .padding(13)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
    }

    private func openOrReveal(at index: Int = 0) {
        if shouldBlurMedia { isRevealed = true } else { onOpen?(index) }
    }
}

private struct OctonautEmbeddedVideoView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Void) {
        webView.stopLoading()
    }
}

struct OctonautVideoPlayer: View {
    let url: URL
    var audioURL: URL?
    var playAudio = false
    var autoplay = false
    var loops = false
    var preloader: OctonautFeedMediaPreloader?
    @State private var player: AVPlayer?
    @State private var aspectRatio: CGFloat = 16 / 9
    @State private var playbackRequested = false
    @State private var looper = OctonautVideoLooper()
    @State private var positionObserver: Any?
    @State private var muxOutcome: OctonautMuxOutcome = .notApplicable
    @State private var coordinator = OctonautPlaybackCoordinator.shared

    /// The viewer takes over playback while it is open.
    private var shouldPlay: Bool { autoplay && !coordinator.isFullScreenActive }

    private var effectiveMuted: Bool { !playAudio || !coordinator.isAudioOwner(url) }

    private var playbackRequest: PlaybackRequest {
        PlaybackRequest(url: url, audioURL: audioURL)
    }

    var body: some View {
        Group {
            if let player {
                OctonautSystemIsolatedVideoPlayer(player: player, showsPlaybackControls: false)
                    .background(.black)
                    .aspectRatio(aspectRatio, contentMode: .fit)
                    .overlay(alignment: .topLeading) {
                        OctonautMuxWarningBadge(outcome: muxOutcome)
                    }
            } else {
                ZStack {
                    Color.black
                    ProgressView().tint(.white)
                }
                .aspectRatio(aspectRatio, contentMode: .fit)
            }
        }
        .task(id: playbackRequest) {
            await OctonautAudioSession.prepareForMutedFeedPlayback()
            playbackRequested = shouldPlay
            removePositionObserver()
            player?.pause()
            player = nil
            let playback: OctonautAVPlayerFactory.Playback
            if let preloader {
                playback = await preloader.playback(videoURL: url, audioURL: audioURL)
            } else {
                playback = await OctonautAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            }
            guard !Task.isCancelled else { return }
            muxOutcome = playback.muxOutcome
            aspectRatio = playback.aspectRatio
            if loops {
                looper.attach(to: playback.player)
            }
            player = playback.player
            observePosition(of: playback.player)
            updateAudioOwnership()
            playback.player.isMuted = effectiveMuted
            if playbackRequested {
                playback.player.play()
            }
        }
        .onChange(of: effectiveMuted) { _, isNowMuted in
            player?.isMuted = isNowMuted
        }
        .onChange(of: shouldPlay) { _, shouldAutoplay in
            playbackRequested = shouldAutoplay
            updateAudioOwnership()
            if shouldAutoplay {
                // Resume wherever the viewer left off rather than where this
                // row was when it handed playback over.
                if let resumeAt = coordinator.position(for: url), resumeAt > 0 {
                    player?.seek(
                        to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                        toleranceBefore: .zero,
                        toleranceAfter: .zero
                    )
                }
                player?.play()
            } else {
                if let player {
                    coordinator.record(player.currentTime().seconds, for: url)
                }
                player?.pause()
            }
        }
        .onChange(of: playAudio) { _, _ in
            updateAudioOwnership()
        }
        .onDisappear {
            playbackRequested = false
            coordinator.releaseAudio(for: url)
            if let player {
                coordinator.record(player.currentTime().seconds, for: url)
            }
            player?.pause()
            removePositionObserver()
            looper.detach()
        }
        .accessibilityLabel("Video")
    }

    private func updateAudioOwnership() {
        if playAudio && shouldPlay && player != nil {
            coordinator.claimAudio(for: url)
        } else {
            coordinator.releaseAudio(for: url)
        }
        player?.isMuted = effectiveMuted
    }

    /// Records the playhead as it moves so opening the viewer can pick up from
    /// where the row actually was, without depending on the order in which
    /// SwiftUI delivers the full screen transition.
    private func observePosition(of player: AVPlayer) {
        removePositionObserver()
        positionObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                guard !OctonautPlaybackCoordinator.shared.isFullScreenActive else { return }
                OctonautPlaybackCoordinator.shared.record(time.seconds, for: url)
            }
        }
    }

    private func removePositionObserver() {
        if let positionObserver, let player {
            player.removeTimeObserver(positionObserver)
        }
        positionObserver = nil
    }

    private struct PlaybackRequest: Hashable {
        let url: URL
        let audioURL: URL?
    }
}

struct OctonautSystemIsolatedVideoPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    var showsPlaybackControls = true

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        Self.makeViewController(player: player, showsPlaybackControls: showsPlaybackControls)
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        controller.updatesNowPlayingInfoCenter = false
        controller.allowsPictureInPicturePlayback = false
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Void) {
        controller.player = nil
    }

    static func makeViewController(
        player: AVPlayer,
        showsPlaybackControls: Bool
    ) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.showsPlaybackControls = showsPlaybackControls
        controller.updatesNowPlayingInfoCenter = false
        controller.allowsPictureInPicturePlayback = false
        return controller
    }
}

@MainActor
@Observable
private final class OctonautNetworkStatus {
    static let shared = OctonautNetworkStatus()

    private(set) var isConnectedViaWiFi = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private let queue = DispatchQueue(label: "com.octonaut.network-status")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let isConnectedViaWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                self?.isConnectedViaWiFi = isConnectedViaWiFi
            }
        }
        monitor.start(queue: queue)
    }
}

struct OctonautZoomableImage: View {
    let url: URL
    let accessibilityLabel: String
    var onZoomChange: ((Bool) -> Void)?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @State private var image: UIImage?
    @State private var loadFailed = false

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .scaleEffect(scale)
                        .offset(offset)
                        .gesture(magnification(viewportSize: geometry.size, imageSize: image.size))
                        .simultaneousGesture(
                            drag(viewportSize: geometry.size, imageSize: image.size),
                            isEnabled: scale > 1
                        )
                        .highPriorityGesture(
                            TapGesture(count: 2)
                                .onEnded {
                                    toggleZoom(viewportSize: geometry.size, imageSize: image.size)
                                }
                        )
                } else if loadFailed {
                    ContentUnavailableView("Image unavailable", systemImage: "photo.slash")
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .onChange(of: geometry.size) { _, newSize in
                clampPosition(viewportSize: newSize, imageSize: image?.size)
            }
        }
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Double tap to zoom. Pinch to zoom and drag to pan.")
        .task(id: url) {
            image = nil
            loadFailed = false
            scale = 1
            baseScale = 1
            offset = .zero
            baseOffset = .zero
            onZoomChange?(false)
            do {
                image = try await OctonautImageCache.image(for: url)
            } catch is CancellationError {
                return
            } catch {
                loadFailed = true
            }
        }
    }

    private func magnification(viewportSize: CGSize, imageSize: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let proposedScale = min(max(baseScale * value, 1), 8)
                scale = proposedScale
                offset = clampedOffset(
                    baseOffset,
                    scale: scale,
                    viewportSize: viewportSize,
                    imageSize: imageSize
                )
                onZoomChange?(scale > 1)
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1 {
                    resetPosition()
                } else {
                    baseOffset = offset
                }
                onZoomChange?(scale > 1)
            }
    }

    private func drag(viewportSize: CGSize, imageSize: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard scale > 1 else { return }
                offset = clampedOffset(
                    CGSize(
                        width: baseOffset.width + value.translation.width,
                        height: baseOffset.height + value.translation.height
                    ),
                    scale: scale,
                    viewportSize: viewportSize,
                    imageSize: imageSize
                )
            }
            .onEnded { _ in
                baseOffset = offset
            }
    }

    private func toggleZoom(viewportSize: CGSize, imageSize: CGSize) {
        if scale > 1 {
            resetPosition()
        } else {
            let targetScale = min(max(
                fillScale(imageSize: imageSize, viewportSize: viewportSize),
                2
            ), 8)
            scale = targetScale
            baseScale = targetScale
            onZoomChange?(true)
        }
    }

    private func fillScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        let fittedSize = aspectFitSize(imageSize: imageSize, viewportSize: viewportSize)
        return max(
            viewportSize.width / max(fittedSize.width, 1),
            viewportSize.height / max(fittedSize.height, 1)
        )
    }

    private func clampPosition(viewportSize: CGSize, imageSize: CGSize?) {
        guard let imageSize else { return }
        let clamped = clampedOffset(
            offset,
            scale: scale,
            viewportSize: viewportSize,
            imageSize: imageSize
        )
        withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
            offset = clamped
            baseOffset = clamped
        }
    }

    private func clampedOffset(
        _ proposed: CGSize,
        scale: CGFloat,
        viewportSize: CGSize,
        imageSize: CGSize
    ) -> CGSize {
        let fittedSize = aspectFitSize(imageSize: imageSize, viewportSize: viewportSize)
        let maximumX = max((fittedSize.width * scale - viewportSize.width) / 2, 0)
        let maximumY = max((fittedSize.height * scale - viewportSize.height) / 2, 0)
        return CGSize(
            width: min(max(proposed.width, -maximumX), maximumX),
            height: min(max(proposed.height, -maximumY), maximumY)
        )
    }

    private func aspectFitSize(imageSize: CGSize, viewportSize: CGSize) -> CGSize {
        guard imageSize.width > 0,
              imageSize.height > 0,
              viewportSize.width > 0,
              viewportSize.height > 0 else { return .zero }
        let fitScale = min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
        return CGSize(width: imageSize.width * fitScale, height: imageSize.height * fitScale)
    }

    private func resetPosition() {
        withAnimation(.easeOut(duration: 0.2)) {
            scale = 1
            baseScale = 1
            offset = .zero
            baseOffset = .zero
        }
        onZoomChange?(false)
    }
}

@MainActor
struct OctonautMediaViewer: View {
    let post: PostCardModel
    var onSave: (() -> Void)?
    var onOpenPost: (() -> Void)?
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var showOverlay = true
    @State private var isRevealed = false
    @State private var fileToExport: OctonautExportableMedia?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveConfirmation: String?
    @State private var isZoomed = false
    @State private var dismissOffset: CGFloat = 0
    @State private var dismissalAxis: DismissalAxis?
    @State private var isDismissing = false
    @State private var activePlayer: AVPlayer?
    @State private var isPlayerMuted = false
    @State private var chromeHideTask: Task<Void, Never>?

    private let saveCoordinator = OctonautMediaSaveCoordinator()

    private var shouldBlurMedia: Bool {
        guard !isRevealed else { return false }
        return post.isSensitive(
            blurringNSFW: dependencies.settings.blurNSFWMedia,
            blurringSpoilers: dependencies.settings.blurSpoilers
        )
    }

    init(
        post: PostCardModel,
        initialPage: Int = 0,
        initiallyRevealed: Bool = false,
        onSave: (() -> Void)? = nil,
        onOpenPost: (() -> Void)? = nil
    ) {
        self.post = post
        self.onSave = onSave
        self.onOpenPost = onOpenPost
        _page = State(initialValue: max(initialPage, 0))
        _isRevealed = State(initialValue: initiallyRevealed)
    }

    private var mediaURLs: [URL] {
        if post.galleryURLs.isEmpty, let mediaURL = post.mediaURL { return [mediaURL] }
        return post.galleryURLs
    }

    private var pagePosition: Binding<Int?> {
        Binding(
            get: { page },
            set: { newPage in
                if let newPage { page = newPage }
            }
        )
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - dismissalProgress)
                .ignoresSafeArea()
            Group {
                if mediaURLs.isEmpty {
                    ContentUnavailableView("Media unavailable", systemImage: "photo.slash")
                        .foregroundStyle(.white)
                } else {
                    GeometryReader { viewport in
                        ScrollView(.horizontal) {
                            HStack(spacing: 0) {
                                ForEach(Array(mediaURLs.enumerated()), id: \.offset) { index, url in
                                    Group {
                                        if post.mediaKind == "video" || post.mediaKind == "gif" {
                                            OctonautVideoDetailView(
                                                url: url,
                                                audioURL: post.audioURL,
                                                loops: post.mediaKind == "gif",
                                                startsMuted: post.mediaKind == "gif",
                                                onPlayerChange: { activePlayer = $0 }
                                            )
                                        } else if post.mediaKind == "embeddedVideo",
                                                  let embedURL = EmbeddedVideoURL.embedURL(for: url) {
                                            ZStack {
                                                OctonautEmbeddedVideoView(url: embedURL)
                                                    .aspectRatio(16 / 9, contentMode: .fit)
                                                    .blur(radius: shouldBlurMedia ? 24 : 0)
                                                if shouldBlurMedia {
                                                    Button { isRevealed = true } label: {
                                                        VStack(spacing: 7) {
                                                            Image(systemName: "eye.slash")
                                                            Text("Tap to reveal")
                                                                .font(.caption.weight(.semibold))
                                                        }
                                                        .foregroundStyle(.white)
                                                        .padding(18)
                                                        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        } else {
                                            ZStack {
                                                OctonautZoomableImage(
                                                    url: url,
                                                    accessibilityLabel: "Image \(index + 1) of \(mediaURLs.count)",
                                                    onZoomChange: { isZoomed = $0 }
                                                )
                                                .blur(radius: shouldBlurMedia ? 24 : 0)
                                                if shouldBlurMedia {
                                                    Button { isRevealed = true } label: {
                                                        VStack(spacing: 7) {
                                                            Image(systemName: "eye.slash")
                                                            Text("Tap to reveal")
                                                                .font(.caption.weight(.semibold))
                                                        }
                                                        .foregroundStyle(.white)
                                                        .padding(18)
                                                        .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 12))
                                                    }
                                                    .buttonStyle(.plain)
                                                }
                                            }
                                        }
                                    }
                                    .frame(width: viewport.size.width, height: viewport.size.height)
                                    .id(index)
                                }
                            }
                            .scrollTargetLayout()
                        }
                        .scrollTargetBehavior(.paging)
                        .scrollPosition(id: pagePosition)
                        .scrollDisabled(isZoomed)
                        .scrollIndicators(.hidden)
                    }
                    .ignoresSafeArea(.container, edges: .all)
                }

                chromeOverlay
            }
            .offset(y: dismissOffset)
            .scaleEffect(1 - (dismissalProgress * 0.08))
            .opacity(1 - (dismissalProgress * 0.2))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dismissalGesture, isEnabled: !isZoomed && !isDismissing)
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showOverlay.toggle() } }
        .onChange(of: page) { _, _ in isZoomed = false }
        .onChange(of: activePlayer == nil) { _, hasNoPlayer in
            if hasNoPlayer {
                cancelChromeHide()
            } else {
                scheduleChromeHide()
            }
        }
        .onChange(of: showOverlay) { _, isVisible in
            // A tap that brings the chrome back restarts the countdown;
            // hiding it manually stops the timer from fighting the user.
            if isVisible && activePlayer != nil {
                scheduleChromeHide()
            } else if !isVisible {
                cancelChromeHide()
            }
        }
        .onDisappear { cancelChromeHide() }
        .onChange(of: saveConfirmation) { _, confirmation in
            if confirmation != nil {
                showOverlay = true
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
        .statusBarHidden(!showOverlay)
        .presentationBackground(.clear)
        .sheet(item: $fileToExport) { media in
            OctonautFileExporter(fileURL: media.url) {
                saveConfirmation = "The media was saved to Files."
            } onDismiss: {
                if !isVideo {
                    try? FileManager.default.removeItem(at: media.url)
                }
            }
        }
        .alert("Could not save media", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "The media could not be saved.")
        }
    }

    /// Extracted from `body`: inlined, the viewer's chrome pushed the whole
    /// expression past what the type-checker will solve in reasonable time.
    @ViewBuilder
    private var chromeOverlay: some View {
        if showOverlay {
            VStack(spacing: 0) {
                HStack {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .accessibilityLabel("Close media viewer")
                Spacer()
                Text("\(min(page + 1, max(mediaURLs.count, 1))) / \(max(mediaURLs.count, 1))")
                    .font(.caption.weight(.semibold).monospacedDigit())
                Spacer()
                if let mediaURL = mediaURLs[safe: page] ?? post.mediaURL {
                    Menu {
                        Button { saveMedia(mediaURL, destination: .photos) } label: {
                            Label("Save to Photos", systemImage: "photo.badge.arrow.down")
                        }
                        if mediaURLs.count > 1 {
                            Button { saveAllMediaToPhotos() } label: {
                                Label("Save All Media to Photos", systemImage: "photo.stack")
                            }
                        }
                        Button { saveMedia(mediaURL, destination: .files) } label: {
                            Label("Save to Files", systemImage: "folder.badge.plus")
                        }
                    } label: {
                        Image(systemName: "arrow.down.circle")
                            .font(.title3)
                    }
                    .disabled(isSaving)
                    .opacity(isSaving || saveConfirmation != nil ? 0 : 1)
                    .overlay {
                        // Keep live feedback outside the native menu's label.
                        Group {
                            if isSaving {
                                ProgressView()
                                    .tint(.white)
                            } else if saveConfirmation != nil {
                                Image(systemName: "checkmark.circle")
                                    .font(.title3)
                                    .foregroundStyle(.white)
                            }
                        }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                    .accessibilityLabel("Save media")
                    .accessibilityValue(isSaving ? "Saving media" : saveConfirmation ?? "")
                }
                Menu {
                    if let onSave {
                        Button { onSave() } label: { Label(post.isSaved ? "Unsave" : "Save", systemImage: "bookmark") }
                    }
                    ShareLink(item: mediaURLs[safe: page] ?? post.shareURL) { Label("Share", systemImage: "square.and.arrow.up") }
                    Button { onOpenPost?(); dismiss() } label: { Label("Open Post", systemImage: "doc.text") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                }
                .accessibilityLabel("Media actions")
                }
                .padding(.horizontal)
                .padding(.top, 10)
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [.black.opacity(0.72), .clear], startPoint: .top, endPoint: .bottom))
                Spacer()
                if mediaURLs.count > 1 {
                HStack(spacing: 6) {
                    ForEach(mediaURLs.indices, id: \.self) { index in
                        Circle()
                            .fill(index == page ? .white : .white.opacity(0.38))
                            .frame(
                                width: index == page ? 7 : 6,
                                height: index == page ? 7 : 6
                            )
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(.black.opacity(0.45), in: Capsule())
                .padding(.bottom, post.title.isEmpty ? 16 : 4)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Image \(page + 1) of \(mediaURLs.count)")
                }
                if let activePlayer {
                OctonautPlayerControls(
                    player: activePlayer,
                    isMuted: $isPlayerMuted,
                    onInteraction: scheduleChromeHide
                )
                .padding(.horizontal, 10)
                .padding(.bottom, post.title.isEmpty ? 10 : 4)
                }
                if post.title != "" {
                VStack(alignment: .leading, spacing: 5) {
                    Text(post.title).font(.headline).lineLimit(3)
                    Text("r/\(post.community) • \(post.score.formatted()) points")
                        .font(.caption).foregroundStyle(.white.opacity(0.78))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .foregroundStyle(.white)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.82)], startPoint: .top, endPoint: .bottom))
                }
            }
            .transition(.opacity)
        }
    }

    private enum DismissalAxis {
        case horizontal
        case vertical
    }

    private var dismissalProgress: CGFloat {
        min(abs(dismissOffset) / 280, 1)
    }

    private var dismissalGesture: some Gesture {
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .onChanged { value in
                if dismissalAxis == nil {
                    dismissalAxis = abs(value.translation.height) > abs(value.translation.width)
                        ? .vertical : .horizontal
                }
                guard dismissalAxis == .vertical else { return }
                dismissOffset = value.translation.height
            }
            .onEnded { value in
                let wasVertical = dismissalAxis == .vertical
                dismissalAxis = nil
                guard wasVertical else { return }

                let projectedDistance = value.predictedEndTranslation.height
                if abs(value.translation.height) > 110 || abs(projectedDistance) > 220 {
                    let direction: CGFloat = projectedDistance == 0
                        ? (value.translation.height < 0 ? -1 : 1)
                        : (projectedDistance < 0 ? -1 : 1)
                    finishInteractiveDismissal(direction: direction)
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        dismissOffset = 0
                    }
                }
            }
    }

    /// Video chrome gets out of the way on its own, the way a player is
    /// expected to behave. Images keep their chrome until tapped.
    private func scheduleChromeHide() {
        chromeHideTask?.cancel()
        if !showOverlay {
            withAnimation(.easeOut(duration: 0.2)) { showOverlay = true }
        }
        chromeHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { showOverlay = false }
        }
    }

    private func cancelChromeHide() {
        chromeHideTask?.cancel()
        chromeHideTask = nil
    }

    private func finishInteractiveDismissal(direction: CGFloat) {
        isDismissing = true
        withAnimation(.easeOut(duration: 0.18)) {
            dismissOffset = direction * 1_200
        }
        Task {
            try? await Task.sleep(for: .milliseconds(180))
            dismiss()
        }
    }

    private enum SaveDestination {
        case photos
        case files
    }

    private var isVideo: Bool {
        post.mediaKind == "video" || post.mediaKind == "gif"
    }

    private func saveMedia(_ sourceURL: URL, destination: SaveDestination) {
        guard !isSaving else { return }
        isSaving = true
        saveConfirmation = nil
        saveError = nil
        showOverlay = true
        Task {
            defer { isSaving = false }
            var temporaryDownloadedURL: URL?
            do {
                let localURL = try await prepareMediaForSaving(sourceURL)
                if !isVideo {
                    temporaryDownloadedURL = localURL
                }
                guard !Task.isCancelled else {
                    if let temporaryDownloadedURL {
                        try? FileManager.default.removeItem(at: temporaryDownloadedURL)
                    }
                    return
                }

                switch destination {
                case .photos:
                    try await saveCoordinator.saveToPhotos(fileURL: localURL, isVideo: isVideo)
                    saveConfirmation = isVideo ? "The video was added to Photos." : "The image was added to Photos."
                    if let temporaryDownloadedURL {
                        try? FileManager.default.removeItem(at: temporaryDownloadedURL)
                    }
                case .files:
                    fileToExport = OctonautExportableMedia(url: localURL)
                }
            } catch is CancellationError {
                if let temporaryDownloadedURL {
                    try? FileManager.default.removeItem(at: temporaryDownloadedURL)
                }
                return
            } catch {
                if destination == .photos, let temporaryDownloadedURL {
                    try? FileManager.default.removeItem(at: temporaryDownloadedURL)
                }
                saveError = error.localizedDescription
            }
        }
    }

    private func saveAllMediaToPhotos() {
        guard !isSaving, mediaURLs.count > 1 else { return }
        isSaving = true
        saveConfirmation = nil
        saveError = nil
        showOverlay = true
        Task {
            defer { isSaving = false }
            var downloadedURLs: [URL] = []
            do {
                var localURLs: [URL] = []
                localURLs.reserveCapacity(mediaURLs.count)
                for sourceURL in mediaURLs {
                    let local = try await prepareMediaForSaving(sourceURL)
                    localURLs.append(local)
                    if !isVideo {
                        downloadedURLs.append(local)
                    }
                }
                guard !Task.isCancelled else {
                    for url in downloadedURLs { try? FileManager.default.removeItem(at: url) }
                    return
                }

                try await saveCoordinator.saveToPhotos(fileURLs: localURLs, isVideo: isVideo)
                let mediaType = isVideo ? "videos" : "images"
                saveConfirmation = "All \(localURLs.count) \(mediaType) were added to Photos."
                for url in downloadedURLs {
                    try? FileManager.default.removeItem(at: url)
                }
            } catch is CancellationError {
                for url in downloadedURLs { try? FileManager.default.removeItem(at: url) }
                return
            } catch {
                for url in downloadedURLs { try? FileManager.default.removeItem(at: url) }
                saveError = error.localizedDescription
            }
        }
    }

    private func prepareMediaForSaving(_ sourceURL: URL) async throws -> URL {
        if isVideo {
            let job = try await dependencies.media.exportVideo(
                source: sourceURL,
                audio: post.audioURL,
                cleanupDate: .now.addingTimeInterval(24 * 60 * 60)
            )
            guard let outputURL = job.outputURL else {
                throw OctonautMediaSaveCoordinator.SaveError.downloadFailed
            }
            return outputURL
        }
        return try await saveCoordinator.downloadImage(from: sourceURL)
    }
}

/// Restarts a player when it reaches the end. GIFs arrive as ordinary mp4s
/// once the codec resolves their preview variant, so looping is what makes
/// them read as GIFs rather than very short videos.
@MainActor
final class OctonautVideoLooper {
    private var observer: (any NSObjectProtocol)?

    func attach(to player: AVPlayer) {
        detach()
        player.actionAtItemEnd = .none
        observer = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: player.currentItem,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                player.seek(to: .zero)
                player.play()
            }
        }
    }

    func detach() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
    }
}

@MainActor
struct OctonautVideoDetailView: View {
    let url: URL
    var audioURL: URL?
    var loops = false
    var autoplay = true
    /// AVPlayerViewController's controls cannot be inset, so they collided
    /// with the viewer's own chrome. The viewer draws `OctonautPlayerControls`
    /// in its overlay stack instead.
    var showsSystemControls = false
    /// GIFs carry no audio track; real videos should open audible.
    var startsMuted = false
    var onPlayerChange: ((AVPlayer?) -> Void)?
    @State private var player: AVPlayer?
    @State private var looper = OctonautVideoLooper()
    @State private var positionObserver: Any?
    @State private var muxOutcome: OctonautMuxOutcome = .notApplicable
    @State private var audioSessionActivated = false

    private var coordinator: OctonautPlaybackCoordinator { .shared }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                OctonautSystemIsolatedVideoPlayer(
                    player: player,
                    showsPlaybackControls: showsSystemControls
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topLeading) {
                    OctonautMuxWarningBadge(outcome: muxOutcome)
                }
            } else {
                ProgressView()
                    .tint(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            coordinator.beginFullScreen()
            let playback = await OctonautAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            guard !Task.isCancelled else { return }
            playback.player.isMuted = startsMuted
            muxOutcome = playback.muxOutcome

            // The factory builds deliberately isolated players so feed rows
            // cannot hijack a system AirPlay session. Here the viewer is front
            // and centre and the user asked for the route, so allow it.
            playback.player.allowsExternalPlayback = true

            if !startsMuted && !audioSessionActivated {
                audioSessionActivated = true
                OctonautAudioSession.activatePlayback()
            }
            if loops {
                looper.attach(to: playback.player)
            }

            // Assign the player before seeking. The async seek does not return
            // until the item is ready to play, and on an asset that never
            // becomes ready it never returns at all -- which left the viewer
            // on a spinner forever while the same media played fine in the
            // feed, where nothing seeks.
            player = playback.player
            observePosition(of: playback.player)
            onPlayerChange?(playback.player)

            // Continue from wherever the feed row had reached.
            if let resumeAt = coordinator.position(for: url), resumeAt > 0 {
                // Completion-handler form: the bare seek maps to async and
                // would reintroduce the wait this fix removes.
                playback.player.seek(
                    to: CMTime(seconds: resumeAt, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero,
                    completionHandler: { _ in }
                )
            }

            if autoplay {
                playback.player.play()
            }
        }
        .onDisappear {
            if let player {
                coordinator.record(player.currentTime().seconds, for: url)
            }
            player?.pause()
            removePositionObserver()
            looper.detach()
            onPlayerChange?(nil)
            coordinator.endFullScreen()
            if audioSessionActivated {
                audioSessionActivated = false
                OctonautAudioSession.deactivate()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video player")
    }

    /// Keeps the shared playhead current so dismissing the viewer hands the
    /// feed row back the position the user actually watched to.
    private func observePosition(of player: AVPlayer) {
        removePositionObserver()
        positionObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { time in
            MainActor.assumeIsolated {
                OctonautPlaybackCoordinator.shared.record(time.seconds, for: url)
            }
        }
    }

    private func removePositionObserver() {
        if let positionObserver, let player {
            player.removeTimeObserver(positionObserver)
        }
        positionObserver = nil
    }

}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
