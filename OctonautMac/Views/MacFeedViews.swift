import AppKit
import AVKit
import Photos
import SwiftUI

@MainActor
struct MacFeedListView: View {
    let descriptor: FeedDescriptorModel
    let store: OctonautFeatureStore
    @Binding var selectedPost: PostCardModel?
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        Group {
            switch store.feedState {
            case .idle where store.posts.isEmpty, .loading where store.posts.isEmpty:
                ProgressView("Loading \(descriptor.macTitle)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message) where store.posts.isEmpty:
                ContentUnavailableView(
                    "Feed unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            case .empty:
                ContentUnavailableView(
                    "No posts",
                    systemImage: "text.page.slash",
                    description: Text("This feed is empty or its posts were filtered.")
                )
            default:
                List(selection: $selectedPost) {
                    if store.filteredPostCount > 0 {
                        Label(
                            "\(store.filteredPostCount) posts hidden by filters",
                            systemImage: "line.3.horizontal.decrease.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    ForEach(store.posts) { post in
                        Group {
                            if dependencies.settings.feedLayout == .full {
                                MacPostMediaCard(post: post)
                            } else {
                                MacPostRow(post: post)
                            }
                        }
                            .contentShape(Rectangle())
                            .tag(post)
                            .simultaneousGesture(
                                TapGesture().onEnded {
                                    selectedPost = post
                                }
                            )
                            .listRowInsets(
                                dependencies.settings.feedLayout == .full
                                    ? EdgeInsets(top: 3, leading: 4, bottom: 3, trailing: 4)
                                    : EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
                            )
                            .listRowSeparator(.visible)
                            .listRowSeparatorTint(.secondary.opacity(0.22))
                            .contextMenu {
                                Button("Open in Browser") { NSWorkspace.shared.open(post.shareURL) }
                                Button("Copy Link") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(
                                        post.shareURL.absoluteString,
                                        forType: .string
                                    )
                                }
                            }
                    }

                    if !store.posts.isEmpty {
                        Button("Load More") {
                            Task { await store.loadMorePosts(for: descriptor) }
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                }
                .listStyle(.plain)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .safeAreaInset(edge: .top, spacing: 0) {
                    HStack(spacing: 12) {
                        Text(descriptor.macTitle)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer(minLength: 12)
                        feedLayoutPicker
                        Button {
                            Task {
                                await store.refreshPosts(for: descriptor, forceRefresh: true)
                            }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
        }
    }

    private var feedLayoutPicker: some View {
        Picker("Feed layout", selection: Binding(
            get: { dependencies.settings.feedLayout },
            set: { dependencies.settings.feedLayout = $0 }
        )) {
            Label("Media Cards", systemImage: "rectangle.on.rectangle")
                .labelStyle(.titleAndIcon)
                .tag(FeedLayout.full)
            Label("Compact Rows", systemImage: "list.bullet")
                .labelStyle(.titleAndIcon)
                .tag(FeedLayout.compact)
        }
        .pickerStyle(.menu)
        .fixedSize()
    }
}

private struct MacPostMediaCard: View {
    let post: PostCardModel
    @Environment(AppDependencies.self) private var dependencies
    @State private var revealsSensitiveMedia = false

    private var shouldBlurMedia: Bool {
        guard !revealsSensitiveMedia else { return false }
        return (post.isNSFW && dependencies.settings.blurNSFWMedia)
            || (post.isSpoiler && dependencies.settings.blurSpoilers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(systemName: "person.crop.circle.fill")
                    .foregroundStyle(.tertiary)
                Text("r/\(post.community)")
                    .fontWeight(.semibold)
                    .foregroundStyle(.primary)
                Text("•")
                Text(post.age)
                Spacer(minLength: 8)
                if post.isSticky {
                    Label("Pinned", systemImage: "pin.fill")
                        .foregroundStyle(.green)
                }
                if post.isNSFW {
                    Text("18+")
                        .foregroundStyle(.red)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Text(post.title)
                .font(.headline)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if dependencies.settings.showPostFlair, let flair = post.flair {
                Text(flair.text)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }

            if !post.body.isEmpty {
                RedditMarkdownView(source: post.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .tint(.accentColor)
                    .lineLimit(post.hasMedia ? 3 : 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if post.hasMedia {
                media
            }

            HStack(spacing: 14) {
                Label(post.score.formatted(), systemImage: "arrow.up")
                    .foregroundStyle(post.vote > 0 ? .orange : .secondary)
                Label(post.comments.formatted(), systemImage: "bubble.left")
                if post.isSaved {
                    Label("Saved", systemImage: "bookmark.fill")
                        .foregroundStyle(.orange)
                }
                Spacer()
                if !post.author.isEmpty {
                    Text("u/\(post.author)")
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .opacity(post.isSeen ? 0.68 : 1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "r/\(post.community), \(post.title), \(post.score) points, \(post.comments) comments"
        )
    }

    @ViewBuilder
    private var media: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(.black.opacity(0.9))

            if let previewURL {
                AsyncImage(url: previewURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFit()
                    case .failure:
                        mediaPlaceholder
                    case .empty:
                        ProgressView()
                            .controlSize(.small)
                    @unknown default:
                        mediaPlaceholder
                    }
                }
                .blur(radius: shouldBlurMedia ? 24 : 0)
            } else {
                mediaPlaceholder
            }

            if post.isVideo && !shouldBlurMedia {
                Image(systemName: "play.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.62), in: Circle())
            }

            if post.galleryURLs.count > 1 && !shouldBlurMedia {
                Text("1 / \(post.galleryURLs.count)")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.62), in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
            }

            if shouldBlurMedia {
                Button {
                    revealsSensitiveMedia = true
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "eye.slash")
                            .font(.title2)
                        Text(post.isNSFW ? "Sensitive media" : "Spoiler")
                            .font(.caption.weight(.semibold))
                        Text("Click to reveal")
                            .font(.caption2)
                    }
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 180, idealHeight: 280, maxHeight: 420)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("\(post.mediaTitle) for \(post.title)")
    }

    private var mediaPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: post.isVideo ? "play.rectangle" : "photo")
                .font(.largeTitle)
            Text(post.mediaTitle)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.white.opacity(0.72))
    }

    private var previewURL: URL? {
        switch post.mediaKind {
        case "image":
            return post.mediaURL ?? post.thumbnailURL
        case "gallery":
            return post.galleryURLs.first ?? post.thumbnailURL
        case "video", "embeddedVideo":
            return post.thumbnailURL
        case "gif":
            return post.thumbnailURL ?? post.mediaURL
        case "link":
            return post.thumbnailURL
        default:
            return nil
        }
    }
}

private struct MacPostRow: View {
    let post: PostCardModel

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                Text(post.score.formatted())
                    .font(.caption.monospacedDigit().weight(.semibold))
                Image(systemName: "arrow.up")
                    .font(.caption)
                    .foregroundStyle(post.vote > 0 ? .orange : .secondary)
            }
            .frame(width: 42)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("r/\(post.community)")
                        .font(.caption.weight(.semibold))
                    Text("•")
                    Text(post.age)
                    if !post.author.isEmpty {
                        Text("• u/\(post.author)")
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)

                Text(post.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(3)

                HStack(spacing: 12) {
                    Label(post.comments.formatted(), systemImage: "bubble.left")
                    if post.isSaved {
                        Label("Saved", systemImage: "bookmark.fill")
                    }
                    if post.isNSFW {
                        Text("NSFW").foregroundStyle(.red)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let thumbnailURL = post.thumbnailURL {
                AsyncImage(url: thumbnailURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.12)
                }
                .frame(width: 72, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

@MainActor
struct MacPostDetailView: View {
    let post: PostCardModel?
    let store: OctonautFeatureStore
    let accounts: AccountCoordinator
    @Environment(AppDependencies.self) private var dependencies
    @State private var actionError: String?
    @State private var isMediaFillingPane = false
    @State private var selectedMediaPage = 0
    @State private var embeddedMediaHeight: CGFloat = 620
    @GestureState private var embeddedMediaHeightDrag: CGFloat = 0

    private var displayedPost: PostCardModel? {
        guard let post else { return nil }
        return store.detailPost?.id == post.id ? store.detailPost : post
    }

    var body: some View {
        if let displayedPost {
            Group {
                if displayedPost.prefersMediaFirstPresentation && isMediaFillingPane {
                    MacMediaLightboxView(
                        post: displayedPost,
                        page: $selectedMediaPage,
                        fillsPane: true,
                        onTogglePaneFill: toggleMediaPaneFill
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    postContent(displayedPost)
                }
            }
            .navigationTitle("r/\(displayedPost.community)")
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        vote(displayedPost, value: displayedPost.vote == 1 ? 0 : 1)
                    } label: {
                        Label("Upvote", systemImage: "arrow.up")
                    }
                    .disabled(currentAccountID == nil)

                    Button {
                        save(displayedPost)
                    } label: {
                        Label(
                            displayedPost.isSaved ? "Unsave" : "Save",
                            systemImage: displayedPost.isSaved ? "bookmark.fill" : "bookmark"
                        )
                    }
                    .disabled(currentAccountID == nil)

                    ShareLink(item: displayedPost.shareURL)

                    Button {
                        NSWorkspace.shared.open(displayedPost.shareURL)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                }
            }
            .alert(
                "Reddit action failed",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(actionError ?? "Unknown error")
            }
            .onChange(of: displayedPost.id) { _, _ in
                isMediaFillingPane = false
                selectedMediaPage = 0
                embeddedMediaHeight = 620
            }
        } else {
            ContentUnavailableView(
                "Select a post",
                systemImage: "text.bubble",
                description: Text("Choose a post from the middle column to read it here.")
            )
        }
    }

    private func postContent(_ post: PostCardModel) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if post.prefersMediaFirstPresentation {
                    VStack(spacing: 0) {
                        MacMediaLightboxView(
                            post: post,
                            page: $selectedMediaPage,
                            fillsPane: false,
                            onTogglePaneFill: toggleMediaPaneFill
                        )
                        .frame(height: effectiveEmbeddedMediaHeight)

                        mediaResizeHandle
                    }
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    postHeader(post)
                }

                if case .loading = store.detailState {
                    ProgressView("Loading comments…")
                }

                if case .failed(let message) = store.detailState {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }

                if !store.comments.isEmpty {
                    Divider()
                    Text("Comments")
                        .font(.title2.weight(.semibold))

                    ForEach(flattenedComments(store.comments)) { comment in
                        MacCommentRow(comment: comment, postAuthor: post.author)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var effectiveEmbeddedMediaHeight: CGFloat {
        max(320, embeddedMediaHeight + embeddedMediaHeightDrag)
    }

    private var mediaResizeHandle: some View {
        Capsule()
            .fill(.white.opacity(0.48))
            .frame(width: 44, height: 4)
            .frame(maxWidth: .infinity)
            .frame(height: 18)
            .background(.black)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .updating($embeddedMediaHeightDrag) { value, state, _ in
                        state = value.translation.height
                    }
                    .onEnded { value in
                        embeddedMediaHeight = max(
                            320,
                            embeddedMediaHeight + value.translation.height
                        )
                    }
            )
            .accessibilityElement()
            .accessibilityLabel("Resize media lightbox")
            .accessibilityValue("\(Int(effectiveEmbeddedMediaHeight)) points high")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    embeddedMediaHeight += 80
                case .decrement:
                    embeddedMediaHeight = max(320, embeddedMediaHeight - 80)
                @unknown default:
                    break
                }
            }
    }

    private func toggleMediaPaneFill() {
        withAnimation(.easeInOut(duration: 0.18)) {
            isMediaFillingPane.toggle()
        }
    }

    @ViewBuilder
    private func postHeader(_ post: PostCardModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("r/\(post.community) • u/\(post.author) • \(post.age)")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(post.title)
                .font(.largeTitle.weight(.bold))
                .textSelection(.enabled)

            if !post.body.isEmpty {
                RedditMarkdownView(source: post.body)
                    .font(.body)
                    .tint(.accentColor)
                    .textSelection(.enabled)
            }

            if post.mediaKind == "image", let mediaURL = post.mediaURL {
                AsyncImage(url: mediaURL) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 180)
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .modifier(MacMediaDownloadContextMenu(post: post))
            } else if let mediaURL = post.mediaURL {
                Link(destination: mediaURL) {
                    Label("Open \(post.mediaTitle.lowercased())", systemImage: "play.rectangle")
                }
                .modifier(MacMediaDownloadContextMenu(post: post))
            }

            HStack(spacing: 16) {
                Label(post.score.formatted(), systemImage: "arrow.up.arrow.down")
                Label(post.comments.formatted(), systemImage: "bubble.left")
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var currentAccountID: AccountID? {
        accounts.selectedAccountID
    }

    private func vote(_ post: PostCardModel, value: Int) {
        guard let currentAccountID else { return }
        Task {
            do {
                try await store.performVote(
                    postID: post.id,
                    value: value,
                    accountID: currentAccountID
                )
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func save(_ post: PostCardModel) {
        guard let currentAccountID else { return }
        Task {
            do {
                try await store.performSave(postID: post.id, accountID: currentAccountID)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    private func flattenedComments(_ comments: [CommentCardModel]) -> [CommentCardModel] {
        comments.flatMap { comment in
            [comment] + flattenedComments(comment.children)
        }
    }
}

@MainActor
private struct MacMediaLightboxView: View {
    let post: PostCardModel
    @Binding var page: Int
    let fillsPane: Bool
    let onTogglePaneFill: () -> Void
    @Environment(AppDependencies.self) private var dependencies
    @State private var isRevealed = false
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveError: String?
    @State private var player: AVPlayer?

    private let saver = MacMediaSaver()

    private var mediaURLs: [URL] {
        post.galleryURLs.isEmpty ? post.mediaURL.map { [$0] } ?? [] : post.galleryURLs
    }

    private var currentURL: URL? {
        mediaURLs.indices.contains(page) ? mediaURLs[page] : mediaURLs.first
    }

    private var isVideo: Bool {
        post.mediaKind == "video" || post.mediaKind == "gif"
    }

    var body: some View {
        ZStack {
            Color.black

            if let currentURL {
                mediaView(for: currentURL)
                    .id(currentURL)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .accessibilityAction(named: fillsPane ? "Fit media in post" : "Fill detail pane") {
                        onTogglePaneFill()
                    }
                    .padding(.vertical, fillsPane ? 0 : 52)
                    .padding(.horizontal, fillsPane ? 0 : 12)
            } else {
                ContentUnavailableView("Media unavailable", systemImage: "photo.slash")
                    .foregroundStyle(.white)
            }

            if post.isSensitive && !isRevealed {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .environment(\.colorScheme, .dark)
                Button {
                    isRevealed = true
                } label: {
                    Label("Show sensitive media", systemImage: "eye.slash")
                        .padding(12)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
            }

            VStack(spacing: 0) {
                lightboxHeader
                Spacer()
                lightboxFooter
            }
        }
        .foregroundStyle(.white)
        .onChange(of: currentURL, initial: true) { _, newURL in
            guard isVideo, let newURL else {
                player = nil
                return
            }
            player = AVPlayer(url: newURL)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
        .alert("Saved", isPresented: messageBinding($saveMessage)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveMessage ?? "The media was saved.")
        }
        .alert("Could not save media", isPresented: messageBinding($saveError)) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(saveError ?? "The media could not be saved.")
        }
    }

    @ViewBuilder
    private func mediaView(for url: URL) -> some View {
        if isVideo, let player {
            MacAVPlayerView(
                player: player,
                fillsPane: fillsPane,
                onDoubleClick: onTogglePaneFill
            )
        } else if post.mediaKind == "embeddedVideo" {
            VStack(spacing: 14) {
                if let thumbnailURL = post.thumbnailURL {
                    AsyncImage(url: thumbnailURL) { image in
                        if fillsPane {
                            image.resizable().scaledToFill()
                        } else {
                            image.resizable().scaledToFit()
                        }
                    } placeholder: {
                        ProgressView().tint(.white)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
                Button("Open video", systemImage: "play.fill") {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onTogglePaneFill)
        } else {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView().tint(.white)
                case .success(let image):
                    if fillsPane {
                        image.resizable().scaledToFill()
                    } else {
                        image.resizable().scaledToFit()
                    }
                case .failure:
                    ContentUnavailableView("Image unavailable", systemImage: "photo.slash")
                        .foregroundStyle(.white)
                @unknown default:
                    EmptyView()
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: onTogglePaneFill)
        }
    }

    private var lightboxHeader: some View {
        HStack(spacing: 12) {
            Text("r/\(post.community)")
                .font(.subheadline.weight(.semibold))
            Spacer()
            if mediaURLs.count > 1 {
                Text("\(page + 1) / \(mediaURLs.count)")
                    .font(.caption.monospacedDigit())
            }
            Menu {
                Button("Save all to Photos", systemImage: "photo.stack") {
                    saveAll(to: .photos)
                }
                Button("Save all to Downloads", systemImage: "arrow.down.circle") {
                    saveAll(to: .downloads)
                }
                Button("Save all to...", systemImage: "folder") {
                    chooseFolderAndSave()
                }
            } label: {
                Label(isSaving ? "Saving" : "Save media", systemImage: isSaving ? "arrow.down.circle.dotted" : "arrow.down.circle")
            }
            .disabled(isSaving || mediaURLs.isEmpty || post.mediaKind == "embeddedVideo")
            .menuIndicator(.hidden)
        }
        .padding(14)
        .background(LinearGradient(colors: [.black.opacity(0.78), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var lightboxFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            if mediaURLs.count > 1 {
                HStack(spacing: 8) {
                    Button("Previous", systemImage: "chevron.left") {
                        page = max(page - 1, 0)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(page == 0)

                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            ForEach(Array(mediaURLs.enumerated()), id: \.offset) { index, url in
                                Button {
                                    page = index
                                } label: {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Color.white.opacity(0.12)
                                    }
                                    .frame(width: 58, height: 42)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(index == page ? Color.white : .clear, lineWidth: 2)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)

                    Button("Next", systemImage: "chevron.right") {
                        page = min(page + 1, mediaURLs.count - 1)
                    }
                    .labelStyle(.iconOnly)
                    .disabled(page == mediaURLs.count - 1)
                }
            }

            Text(post.title)
                .font(.headline)
                .lineLimit(2)
            if !post.body.isEmpty {
                RedditMarkdownView(source: post.body)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.78))
                    .tint(.accentColor)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.84)], startPoint: .top, endPoint: .bottom))
    }

    private func chooseFolderAndSave() {
        Task {
            guard let folder = await MacFolderPicker.chooseFolder() else { return }
            saveAll(to: .folder(folder))
        }
    }

    private func saveAll(to destination: MacMediaSaveDestination) {
        guard !isSaving, !mediaURLs.isEmpty else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                saveMessage = try await MacMediaSaveOperation.run(
                    post: post,
                    destination: destination,
                    mediaService: dependencies.media,
                    saver: saver
                )
            } catch is CancellationError {
                return
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func messageBinding(_ value: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }
}

private enum MacMediaSaveDestination {
    case photos
    case downloads
    case folder(URL)
}

@MainActor
private enum MacMediaSaveOperation {
    static func run(
        post: PostCardModel,
        destination: MacMediaSaveDestination,
        mediaService: any MediaService,
        saver: MacMediaSaver
    ) async throws -> String {
        let mediaURLs = post.galleryURLs.isEmpty
            ? post.mediaURL.map { [$0] } ?? []
            : post.galleryURLs
        guard !mediaURLs.isEmpty else {
            throw MacMediaSaver.SaveError.downloadFailed
        }

        let isVideo = post.mediaKind == "video" || post.mediaKind == "gif"
        var localURLs: [URL] = []
        defer { localURLs.forEach { try? FileManager.default.removeItem(at: $0) } }

        for sourceURL in mediaURLs {
            if isVideo {
                let job = try await mediaService.exportVideo(
                    source: sourceURL,
                    audio: post.audioURL,
                    cleanupDate: .now.addingTimeInterval(24 * 60 * 60)
                )
                guard let outputURL = job.outputURL else {
                    throw MacMediaSaver.SaveError.downloadFailed
                }
                localURLs.append(outputURL)
            } else {
                localURLs.append(try await saver.download(sourceURL))
            }
        }

        let destinationName: String
        switch destination {
        case .photos:
            try await saver.addToPhotos(localURLs, isVideo: isVideo)
            destinationName = "Photos"
        case .downloads:
            let folder = try await saver.downloadsDirectory()
            try await saver.copy(localURLs, to: folder, postID: post.id)
            destinationName = "Downloads"
        case .folder(let folder):
            let hasAccess = folder.startAccessingSecurityScopedResource()
            defer { if hasAccess { folder.stopAccessingSecurityScopedResource() } }
            try await saver.copy(localURLs, to: folder, postID: post.id)
            destinationName = folder.lastPathComponent
        }

        let count = localURLs.count
        return "Saved \(count) \(count == 1 ? "item" : "items") to \(destinationName)."
    }
}

@MainActor
private struct MacMediaDownloadContextMenu: ViewModifier {
    let post: PostCardModel
    @Environment(AppDependencies.self) private var dependencies
    @State private var isSaving = false
    @State private var saveMessage: String?
    @State private var saveError: String?

    private let saver = MacMediaSaver()

    private var canDownload: Bool {
        ["image", "gallery", "video", "gif"].contains(post.mediaKind)
            && (post.mediaURL != nil || !post.galleryURLs.isEmpty)
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        if canDownload {
            content
                .contextMenu {
                    Button("Save all to Photos", systemImage: "photo.stack") {
                        saveAll(to: .photos)
                    }
                    Button("Save all to Downloads", systemImage: "arrow.down.circle") {
                        saveAll(to: .downloads)
                    }
                    Button("Save all to...", systemImage: "folder") {
                        chooseFolderAndSave()
                    }
                }
                .alert("Saved", isPresented: messageBinding($saveMessage)) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(saveMessage ?? "The media was saved.")
                }
                .alert("Could not save media", isPresented: messageBinding($saveError)) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(saveError ?? "The media could not be saved.")
                }
        } else {
            content
        }
    }

    private func chooseFolderAndSave() {
        Task {
            guard let folder = await MacFolderPicker.chooseFolder() else { return }
            saveAll(to: .folder(folder))
        }
    }

    private func saveAll(to destination: MacMediaSaveDestination) {
        guard !isSaving, canDownload else { return }
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                saveMessage = try await MacMediaSaveOperation.run(
                    post: post,
                    destination: destination,
                    mediaService: dependencies.media,
                    saver: saver
                )
            } catch is CancellationError {
                return
            } catch {
                saveError = error.localizedDescription
            }
        }
    }

    private func messageBinding(_ value: Binding<String?>) -> Binding<Bool> {
        Binding(
            get: { value.wrappedValue != nil },
            set: { if !$0 { value.wrappedValue = nil } }
        )
    }
}

@MainActor
private struct MacAVPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let fillsPane: Bool
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> DoubleClickAVPlayerView {
        let playerView = DoubleClickAVPlayerView()
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        playerView.player = player
        playerView.onDoubleClick = onDoubleClick
        playerView.videoGravity = fillsPane ? .resizeAspectFill : .resizeAspect
        return playerView
    }

    func updateNSView(_ playerView: DoubleClickAVPlayerView, context: Context) {
        if playerView.player !== player {
            playerView.player = player
        }
        playerView.onDoubleClick = onDoubleClick
        playerView.videoGravity = fillsPane ? .resizeAspectFill : .resizeAspect
    }
}

@MainActor
private final class DoubleClickAVPlayerView: AVPlayerView {
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2 else {
            super.mouseDown(with: event)
            return
        }
        onDoubleClick?()
    }
}

@MainActor
private enum MacFolderPicker {
    static func chooseFolder() async -> URL? {
        await withCheckedContinuation { continuation in
            let panel = NSOpenPanel()
            panel.title = "Choose a folder for the media"
            panel.prompt = "Save Here"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.canCreateDirectories = true

            let completion: (NSApplication.ModalResponse) -> Void = { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
            if let window = NSApp.keyWindow {
                panel.beginSheetModal(for: window, completionHandler: completion)
            } else {
                panel.begin(completionHandler: completion)
            }
        }
    }
}

private actor MacMediaSaver {
    enum SaveError: LocalizedError {
        case downloadFailed
        case photoAccessDenied
        case downloadsUnavailable

        var errorDescription: String? {
            switch self {
            case .downloadFailed:
                return "The media could not be downloaded."
            case .photoAccessDenied:
                return "Allow Octonaut to add media to Photos in System Settings, then try again."
            case .downloadsUnavailable:
                return "The Downloads folder is unavailable."
            }
        }
    }

    func download(_ sourceURL: URL) async throws -> URL {
        let request = try MediaDownloadTransport.request(for: sourceURL)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try MediaDownloadTransport.validate(response)
        let fileExtension = MediaDownloadTransport.fileExtension(for: sourceURL, response: response)
        let outputURL = FileManager.default.temporaryDirectory
            .appending(path: "Octonaut-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension.isEmpty ? "jpg" : fileExtension)
        try FileManager.default.moveItem(at: temporaryURL, to: outputURL)
        return outputURL
    }

    func addToPhotos(_ localURLs: [URL], isVideo: Bool) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw SaveError.photoAccessDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            for localURL in localURLs {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: isVideo ? .video : .photo, fileURL: localURL, options: nil)
            }
        }
    }

    func downloadsDirectory() throws -> URL {
        guard let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else {
            throw SaveError.downloadsUnavailable
        }
        return directory
    }

    func copy(_ localURLs: [URL], to folder: URL, postID: String) throws {
        let fileManager = FileManager.default
        for (index, localURL) in localURLs.enumerated() {
            let suffix = localURLs.count > 1 ? "-\(index + 1)" : ""
            let fileExtension = localURL.pathExtension.isEmpty ? "jpg" : localURL.pathExtension
            let baseName = "Octonaut-\(postID)\(suffix)"
            var destination = folder.appending(path: baseName).appendingPathExtension(fileExtension)
            var copyNumber = 2
            while fileManager.fileExists(atPath: destination.path) {
                destination = folder.appending(path: "\(baseName)-\(copyNumber)").appendingPathExtension(fileExtension)
                copyNumber += 1
            }
            try fileManager.copyItem(at: localURL, to: destination)
        }
    }
}

private struct MacCommentRow: View {
    let comment: CommentCardModel
    let postAuthor: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if comment.depth > 0 {
                Rectangle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 2)
                    .padding(.leading, CGFloat(min(comment.depth, 6)) * 10)
            }

            VStack(alignment: .leading, spacing: 5) {
                if comment.isMoreNode {
                    Text("More comments")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 6) {
                        Text("u/\(comment.author)")
                        if comment.isOriginalPoster(postAuthor: postAuthor) {
                            Text("OP")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                        }
                        Text("• \(comment.score) points • \(comment.age)")
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(comment.isModerator ? .green : .secondary)
                }
                if !comment.isMoreNode {
                    RedditMarkdownView(source: comment.body)
                        .tint(.accentColor)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 6)
    }
}
