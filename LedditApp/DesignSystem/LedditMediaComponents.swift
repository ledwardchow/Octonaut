import AVKit
import Foundation
import Photos
import SwiftUI
import UIKit

private struct LedditExportableMedia: Identifiable {
    let id = UUID()
    let url: URL
}

private struct LedditFileExporter: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [fileURL], asCopy: true)
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
}

private actor LedditMediaSaveCoordinator {
    enum SaveError: LocalizedError {
        case downloadFailed
        case photoAccessDenied

        var errorDescription: String? {
            switch self {
            case .downloadFailed: return "The media could not be downloaded."
            case .photoAccessDenied: return "Allow Leddit to add media to Photos in Settings, then try again."
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
            .appending(path: "LedditImage-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)
        try fileManager.moveItem(at: temporaryURL, to: outputURL)
        return outputURL
    }

    func saveToPhotos(fileURL: URL, isVideo: Bool) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw SaveError.photoAccessDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            request.addResource(with: isVideo ? .video : .photo, fileURL: fileURL, options: nil)
        }
    }
}

@MainActor
private enum LedditAVPlayerFactory {
    static func makePlayer(videoURL: URL, audioURL: URL?) async -> AVPlayer {
        guard let audioURL, audioURL != videoURL else {
            return localPlaybackPlayer(url: videoURL)
        }
        let videoAsset = AVURLAsset(url: videoURL)
        let audioAsset = AVURLAsset(url: audioURL)
        let videoTracks: [AVAssetTrack]
        let audioTracks: [AVAssetTrack]
        do {
            videoTracks = try await videoAsset.loadTracks(withMediaType: .video)
            audioTracks = try await audioAsset.loadTracks(withMediaType: .audio)
        } catch {
            return localPlaybackPlayer(url: videoURL)
        }
        guard let videoTrack = videoTracks.first else { return localPlaybackPlayer(url: videoURL) }

        let composition = AVMutableComposition()
        guard let duration = try? await videoAsset.load(.duration) else {
            return localPlaybackPlayer(url: videoURL)
        }
        do {
            guard let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                return localPlaybackPlayer(url: videoURL)
            }
            try compositionVideo.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
            if let audioTrack = audioTracks.first,
               let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
                let loadedAudioDuration = (try? await audioAsset.load(.duration)) ?? duration
                let audioDuration = CMTimeMinimum(duration, loadedAudioDuration)
                try compositionAudio.insertTimeRange(CMTimeRange(start: .zero, duration: audioDuration), of: audioTrack, at: .zero)
            }
            return localPlaybackPlayer(item: AVPlayerItem(asset: composition))
        } catch {
            return localPlaybackPlayer(url: videoURL)
        }
    }

    private static func localPlaybackPlayer(url: URL) -> AVPlayer {
        localPlaybackPlayer(item: AVPlayerItem(url: url))
    }

    private static func localPlaybackPlayer(item: AVPlayerItem) -> AVPlayer {
        let player = AVPlayer(playerItem: item)
        player.allowsExternalPlayback = false
        player.usesExternalPlaybackWhileExternalScreenIsActive = false
        return player
    }
}

/// A cached remote image with stable loading and failure states.
struct LedditAsyncImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    var tint: Color = .secondary
    @State private var image: UIImage?
    @State private var loadFailed = false

    @ViewBuilder
    var body: some View {
        Group {
            if url != nil {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                        .transition(.opacity)
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
                let loadedImage = try await LedditImageCache.image(for: url)
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    image = loadedImage
                }
            } catch is CancellationError {
                return
            } catch {
                loadFailed = true
            }
        }
    }
}

struct LedditInlineMediaView: View {
    let post: PostCardModel
    var onOpen: ((Int) -> Void)?
    @State private var isRevealed = false

    private let gallerySpacing: CGFloat = 4
    private let galleryHeight: CGFloat = 220

    private var inlineGalleryURLs: [URL] {
        if !post.galleryURLs.isEmpty { return post.galleryURLs }
        if let mediaURL = post.mediaURL { return [mediaURL] }
        return []
    }

    var body: some View {
        Group {
            if post.mediaKind == "video" || post.mediaKind == "gif", let url = post.mediaURL {
                ZStack(alignment: .topTrailing) {
                    LedditVideoPlayer(url: url, audioURL: post.audioURL, muted: true)
                    if post.isSensitive && !isRevealed { sensitiveRevealButton }
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
                                    LedditAsyncImage(url: url, contentMode: .fit)
                                        .frame(width: itemWidth, height: galleryHeight)
                                        .background(.black.opacity(0.04))
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .disabled(post.isSensitive && !isRevealed)
                                .accessibilityLabel("Open image \(index + 1) of \(inlineGalleryURLs.count)")
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned(limitBehavior: .alwaysByOne))
                    .scrollIndicators(.hidden)
                    .blur(radius: post.isSensitive && !isRevealed ? 12 : 0)
                    .overlay {
                        if post.isSensitive && !isRevealed {
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
                        LedditAsyncImage(url: url, contentMode: .fit)
                            .frame(maxWidth: .infinity)
                            .blur(radius: post.isSensitive && !isRevealed ? 12 : 0)
                        if post.isSensitive && !isRevealed { sensitiveOverlay }
                    }
                }
                .buttonStyle(.plain)
            } else if post.mediaKind == "link" {
                let url = post.mediaURL ?? post.shareURL
                Link(destination: url) {
                    HStack(spacing: 10) {
                        Image(systemName: "link.circle.fill").font(.title2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(post.mediaTitle.isEmpty ? "Open link" : post.mediaTitle).font(.subheadline.weight(.semibold)).lineLimit(2)
                            Text(url.host ?? url.absoluteString).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                    }
                    .padding(13)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
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
                LedditMediaPlaceholder(
                    title: post.mediaTitle,
                    symbol: post.isVideo ? "play.fill" : "photo",
                    isBlurred: post.isSensitive,
                    action: { openOrReveal(at: 0) }
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
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

    private func openOrReveal(at index: Int = 0) {
        if post.isSensitive && !isRevealed { isRevealed = true } else { onOpen?(index) }
    }
}

struct LedditVideoPlayer: View {
    let url: URL
    var audioURL: URL?
    var muted = true
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .background(.black)
                    .aspectRatio(16 / 9, contentMode: .fit)
            } else {
                ZStack {
                    Color.black
                    ProgressView().tint(.white)
                }
                .aspectRatio(16 / 9, contentMode: .fit)
            }
        }
        .task(id: url) {
            let loadedPlayer = await LedditAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            loadedPlayer.isMuted = muted
            player = loadedPlayer
        }
        .onDisappear {
            player?.pause()
        }
        .accessibilityLabel("Video")
    }
}

struct LedditZoomableImage: View {
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
                image = try await LedditImageCache.image(for: url)
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
                let minimumZoomScale = fillScale(
                    imageSize: imageSize,
                    viewportSize: viewportSize
                )
                if baseScale > 1, proposedScale < minimumZoomScale * 0.85 {
                    scale = 1
                } else if proposedScale > 1 {
                    scale = max(proposedScale, minimumZoomScale)
                } else {
                    scale = 1
                }
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
struct LedditMediaViewer: View {
    let post: PostCardModel
    var onSave: (() -> Void)?
    var onOpenPost: (() -> Void)?
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var page = 0
    @State private var showOverlay = true
    @State private var isRevealed = false
    @State private var fileToExport: LedditExportableMedia?
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveConfirmation: String?
    @State private var isZoomed = false
    @State private var dismissOffset: CGFloat = 0
    @State private var dismissalAxis: DismissalAxis?
    @State private var isDismissing = false

    private let saveCoordinator = LedditMediaSaveCoordinator()

    init(
        post: PostCardModel,
        initialPage: Int = 0,
        onSave: (() -> Void)? = nil,
        onOpenPost: (() -> Void)? = nil
    ) {
        self.post = post
        self.onSave = onSave
        self.onOpenPost = onOpenPost
        _page = State(initialValue: max(initialPage, 0))
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
                                            LedditVideoDetailView(url: url, audioURL: post.audioURL)
                                        } else {
                                            ZStack {
                                                LedditZoomableImage(
                                                    url: url,
                                                    accessibilityLabel: "Image \(index + 1) of \(mediaURLs.count)",
                                                    onZoomChange: { isZoomed = $0 }
                                                )
                                                if post.isSensitive && !isRevealed {
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
                                Button { saveMedia(mediaURL, destination: .files) } label: {
                                    Label("Save to Files", systemImage: "folder.badge.plus")
                                }
                            } label: {
                                Image(systemName: isSaving ? "arrow.down.circle.dotted" : "arrow.down.circle")
                                    .font(.title3)
                            }
                            .disabled(isSaving)
                            .accessibilityLabel(isSaving ? "Saving media" : "Save media")
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
            .offset(y: dismissOffset)
            .scaleEffect(1 - (dismissalProgress * 0.08))
            .opacity(1 - (dismissalProgress * 0.2))
        }
        .contentShape(Rectangle())
        .simultaneousGesture(dismissalGesture, isEnabled: !isZoomed && !isDismissing)
        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { showOverlay.toggle() } }
        .onChange(of: page) { _, _ in isZoomed = false }
        .statusBarHidden(!showOverlay)
        .presentationBackground(.clear)
        .sheet(item: $fileToExport) { media in
            LedditFileExporter(fileURL: media.url)
        }
        .alert("Could not save media", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("OK", role: .cancel) { saveError = nil }
        } message: {
            Text(saveError ?? "The media could not be saved.")
        }
        .alert("Saved", isPresented: Binding(get: { saveConfirmation != nil }, set: { if !$0 { saveConfirmation = nil } })) {
            Button("OK", role: .cancel) { saveConfirmation = nil }
        } message: {
            Text(saveConfirmation ?? "The media was saved.")
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
        Task {
            do {
                let localURL: URL
                if isVideo {
                    let job = try await dependencies.media.exportVideo(
                        source: sourceURL,
                        audio: post.audioURL,
                        cleanupDate: .now.addingTimeInterval(24 * 60 * 60)
                    )
                    guard let outputURL = job.outputURL else {
                        throw LedditMediaSaveCoordinator.SaveError.downloadFailed
                    }
                    localURL = outputURL
                } else {
                    localURL = try await saveCoordinator.downloadImage(from: sourceURL)
                }
                guard !Task.isCancelled else { return }

                switch destination {
                case .photos:
                    try await saveCoordinator.saveToPhotos(fileURL: localURL, isVideo: isVideo)
                    saveConfirmation = isVideo ? "The video was added to Photos." : "The image was added to Photos."
                case .files:
                    fileToExport = LedditExportableMedia(url: localURL)
                }
            } catch is CancellationError {
                return
            } catch {
                saveError = error.localizedDescription
            }
            isSaving = false
        }
    }
}

@MainActor
struct LedditVideoDetailView: View {
    let url: URL
    var audioURL: URL?
    @State private var player: AVPlayer?
    @State private var currentTime: Double = 0
    @State private var duration: Double = 1
    @State private var isMuted = true
    @State private var isPlaying = false
    @State private var speed = 1.0

    var body: some View {
        VStack(spacing: 12) {
            if let player {
                VideoPlayer(player: player)
                    .background(.black)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .onTapGesture { togglePlayback() }
            } else {
                ProgressView().tint(.white).frame(maxWidth: .infinity).aspectRatio(16 / 9, contentMode: .fit)
            }
            VStack(spacing: 8) {
                Slider(value: Binding(get: { currentTime }, set: { value in
                    currentTime = value
                    player?.seek(to: CMTime(seconds: value, preferredTimescale: 600))
                }), in: 0...max(duration, 1))
                HStack {
                    Text(formatTime(currentTime))
                    Spacer()
                    Text("-\(formatTime(max(duration - currentTime, 0)))")
                }
                .font(.caption.monospacedDigit())
                HStack(spacing: 22) {
                    Button { seek(by: -10) } label: { Image(systemName: "gobackward.10") }
                    Button { togglePlayback() } label: { Image(systemName: isPlaying ? "pause.fill" : "play.fill") }
                        .font(.title2)
                    Button { seek(by: 10) } label: { Image(systemName: "goforward.10") }
                    Button { isMuted.toggle(); player?.isMuted = isMuted } label: { Image(systemName: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill") }
                    Menu {
                        ForEach([0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                            Button { speed = value; player?.rate = isPlaying ? Float(value) : 0 } label: {
                                if speed == value { Label("\(value, specifier: "%g")×", systemImage: "checkmark") } else { Text("\(value, specifier: "%g")×") }
                            }
                        }
                    } label: { Text("\(speed, specifier: "%g")×").font(.caption.weight(.semibold)) }
                }
                .font(.title3)
            }
            .foregroundStyle(.white)
            .padding(.horizontal)
        }
        .task(id: url) {
            let loadedPlayer = await LedditAVPlayerFactory.makePlayer(videoURL: url, audioURL: audioURL)
            loadedPlayer.isMuted = isMuted
            player = loadedPlayer
            if let asset = loadedPlayer.currentItem?.asset,
               let loadedDuration = try? await asset.load(.duration).seconds,
               loadedDuration.isFinite,
               loadedDuration > 0 {
                duration = loadedDuration
            }
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            guard let player else { return }
            let seconds = player.currentTime().seconds
            if seconds.isFinite { currentTime = seconds }
            if let itemDuration = player.currentItem?.duration.seconds, itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
            isPlaying = player.timeControlStatus == .playing
        }
        .onDisappear { player?.pause() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Video player")
    }

    private func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing { player.pause() } else { player.rate = Float(speed); player.play() }
        isPlaying = player.timeControlStatus == .playing
    }

    private func seek(by seconds: Double) {
        let target = min(max(currentTime + seconds, 0), max(duration, 1))
        currentTime = target
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func formatTime(_ time: Double) -> String {
        guard time.isFinite else { return "0:00" }
        let total = max(Int(time), 0)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
