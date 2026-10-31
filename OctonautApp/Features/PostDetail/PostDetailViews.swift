import SwiftUI
import UIKit

private struct OctonautDuoPostDetailKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var octonautDuoPostDetail: Bool {
        get { self[OctonautDuoPostDetailKey.self] }
        set { self[OctonautDuoPostDetailKey.self] = newValue }
    }
}

enum OctonautPostDetailSpace: Hashable {
    case viewport
}

@MainActor
struct PostDetailView: View {
    let post: PostCardModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.octonautDuoPostDetail) private var usesDuoPostDetail
    @State private var titleHasScrolledPast = false
    @State private var commentSort = "Best"
    @State private var composerTarget: CommentComposerTarget?
    @State private var isMediaViewerPresented = false
    @State private var selectedMediaPage = 0
    @State private var showingLogin = false
    @State private var reportTarget: RedditReportTarget?
    @State private var crosspostPost: PostCardModel?

    private var currentPost: PostCardModel {
        guard let detailPost = store.detailPost, detailPost.id == post.id else { return post }
        return detailPost
    }

    private var flattenedComments: [CommentCardModel] {
        func flatten(_ comments: [CommentCardModel]) -> [CommentCardModel] {
            comments.flatMap { comment in
                guard !comment.isCollapsed else { return [comment] }
                return [comment] + flatten(comment.children)
            }
        }
        return flatten(store.comments)
    }

    private var summaryComments: [CommentSummaryInput.Comment] {
        func flatten(_ values: [CommentCardModel]) -> [CommentSummaryInput.Comment] {
            values.flatMap { value in
                let current =
                    value.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? [] : [CommentSummaryInput.Comment(id: value.id, text: value.body)]
                return current + flatten(value.children)
            }
        }
        return flatten(store.comments)
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                OctonautPostRow(
                    post: currentPost,
                    onUserOpen: { router.push($0) },
                    bodyLineLimit: nil,
                    showsFlair: dependencies.settings.showPostFlair,
                    onVote: { performVote(postID: currentPost.id, value: $0) },
                    onSave: { performSave(postID: currentPost.id) },
                    onSeen: { store.markSeen(postID: currentPost.id) },
                    onMedia: { page in
                        selectedMediaPage = page
                        isMediaViewerPresented = true
                    },
                    onCommunityOpen: { router.push(.community(currentPost.community)) },
                    communityOpenAccessibilityHint: "Opens the subreddit",
                    onTitleBottomChange: usesDuoPostDetail ? { titleHasScrolledPast = $0 <= DuoLayout.columnHeaderHeight } : nil
                )
                .padding(.top, 4)

                if store.detailState == .loading {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Loading comments…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.top, 8)
                } else if case .loginRequired = store.detailState {
                    RedditLoginRequiredView()
                } else if case .failed(let message) = store.detailState {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Comments could not be loaded").font(.subheadline.weight(.semibold))
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            Button("Retry") {
                                Task { await store.loadPostDetail(for: currentPost, sort: commentSort, forceRefresh: true) }
                            }
                            .font(.caption.weight(.semibold))
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(
                        Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10)
                    )
                    .padding(.horizontal)
                    .padding(.top, 8)
                }

                if dependencies.settings.showPostSummaries, postSummaryEligible {
                    SummaryCardView(
                        title: "Post Summary",
                        input: .post(
                            PostSummaryInput(id: currentPost.id, title: currentPost.title, body: currentPost.body)
                        ),
                        intelligence: dependencies.intelligence,
                        cache: dependencies.summaryCache,
                        modelFamily: dependencies.summaryCacheModelFamily,
                        automatic: dependencies.settings.automaticVisibleSummaries,
                        useFallback: dependencies.settings.keyExcerptsFallback
                    )
                }
                if dependencies.settings.showCommentSummaries,
                   store.detailState == .loaded {
                    let comments = summaryComments
                    if SummaryEligibility.comments(comments) {
                        SummaryCardView(
                            title: "Comments Summary",
                            input: .comments(
                                CommentSummaryInput(postID: currentPost.id, comments: comments)
                            ),
                            intelligence: dependencies.intelligence,
                            cache: dependencies.summaryCache,
                            modelFamily: dependencies.summaryCacheModelFamily,
                            automatic: dependencies.settings.automaticCommentSummaries,
                            useFallback: dependencies.settings.keyExcerptsFallback
                        )
                    }
                }

                HStack {
                    Text("Comments")
                        .font(.title3.weight(.bold))
                    Spacer()
                    Button("Comment", systemImage: "square.and.pencil") {
                        beginReply(to: currentPost.fullname)
                    }
                    .font(.caption.weight(.semibold))
                    Menu {
                        ForEach(["Best", "New", "Top", "Controversial", "Old"], id: \.self) { value in
                            Button {
                                commentSort = value
                            } label: {
                                if value == commentSort {
                                    Label(value, systemImage: "checkmark")
                                } else {
                                    Text(value)
                                }
                            }
                        }
                    } label: {
                        Label(commentSort, systemImage: "arrow.up.arrow.down")
                            .font(.caption.weight(.semibold))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 16)
                .padding(.bottom, 4)

                let comments = flattenedComments
                ForEach(comments) { comment in
                    if comment.isMoreNode {
                        moreCommentsRow(comment)
                    } else {
                        OctonautCommentRow(
                            onReport: { if dependencies.accounts.requireLogin() { reportTarget = RedditReportTarget(commentID: comment.id, post: currentPost) } },
                            comment: comment,
                            postAuthor: currentPost.author,
                            onCollapse: {
                                withAnimation(.snappy(duration: 0.2)) {
                                    store.toggleComment(id: comment.id)
                                }
                            }, onVote: { performCommentVote(commentID: comment.id, value: $0) },
                            onReply: {
                                beginReply(to: IDNormalization.fullname(comment.id, kind: "t1"))
                            })
                    }
                }
                if comments.isEmpty {
                    VStack(spacing: 12) {
                        ContentUnavailableView(
                            "No comments", systemImage: "bubble.left.and.bubble.right",
                            description: Text("There are no comments to show.")
                        )
                        Button("Add the first comment") {
                            beginReply(to: currentPost.fullname)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 40)
                }
            }
        }
        .id(post.id)
        .coordinateSpace(name: OctonautPostDetailSpace.viewport)
        .safeAreaInset(edge: .top, spacing: 0) {
            if usesDuoPostDetail && !store.isBlockedAuthor(currentPost.author) {
                Text(titleHasScrolledPast ? currentPost.title : "Post")
                    .font(.headline)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: DuoLayout.columnHeaderHeight)
                    .background(.regularMaterial)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("duo-post-header")
                    .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.container, edges: usesDuoPostDetail ? .top : [])
        .onChange(of: post.id) { _, _ in titleHasScrolledPast = false }
        .opacity(store.isBlockedAuthor(currentPost.author) ? 0 : 1)
        .allowsHitTesting(!store.isBlockedAuthor(currentPost.author))
        .accessibilityHidden(store.isBlockedAuthor(currentPost.author))
        .overlay {
            if store.isBlockedAuthor(currentPost.author) {
                ContentUnavailableView("Post hidden", systemImage: "person.crop.circle.badge.xmark")
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle(usesDuoPostDetail ? "" : "Post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !store.isBlockedAuthor(currentPost.author) {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Report", systemImage: "flag") { if dependencies.accounts.requireLogin() { reportTarget = RedditReportTarget(post: currentPost) } }
                        Button {
                            store.markSeen(postID: currentPost.id)
                        } label: {
                            Label(currentPost.isSeen ? "Mark Unseen" : "Mark Seen", systemImage: "eye")
                        }
                        if currentPost.hasMedia {
                            Button {
                                isMediaViewerPresented = true
                            } label: {
                                Label("Open Media", systemImage: "photo")
                            }
                        }
                        Button {
                            UIApplication.shared.open(currentPost.shareURL)
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                        }
                        ShareLink(item: currentPost.shareURL) {
                            Label("Share Link", systemImage: "square.and.arrow.up")
                        }
                        Button {
                            beginCrosspost()
                        } label: {
                            Label("Crosspost", systemImage: "arrow.triangle.branch")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .sheet(item: $reportTarget) { ReportContentView(target: $0) }
        .sheet(item: $composerTarget) { target in
            ComposerView(kind: .comment, store: store, targetID: target.id) {
                Task {
                    await store.loadPostDetail(for: target.post, sort: commentSort, forceRefresh: true)
                }
            }
        }
        .loginRequiredModal(isPresented: $showingLogin)
        .sheet(item: $crosspostPost) { post in
            CrosspostComposerView(post: post)
        }
        .fullScreenCover(isPresented: $isMediaViewerPresented) {
            OctonautMediaViewer(
                post: currentPost, initialPage: selectedMediaPage,
                onSave: { performSave(postID: currentPost.id) },
                onOpenPost: { dismissMediaViewerAndStay() })
        }
        .task(id: "\(post.id):\(commentSort):\(store.accountContextKey)") {
            await store.loadPostDetail(for: post, sort: commentSort)
        }
        .task(id: post.id) {
            await store.recordPostViewed()
        }
    }

    private var postSummaryEligible: Bool {
        SummaryEligibility.post(title: currentPost.title, body: currentPost.body)
    }

    private func beginCrosspost() {
        guard dependencies.accounts.selectedAccount?.health == .healthy else {
            showingLogin = true
            return
        }
        crosspostPost = currentPost
    }

    private func continueThreadURL(_ comment: CommentCardModel) -> URL? {
        guard comment.moreChildIDs.isEmpty, !comment.hasCommentPage,
              let parent = comment.moreParentFullname, parent.hasPrefix("t1_") else { return nil }
        return RedditReportTarget(commentID: parent, post: currentPost).permalink
    }

    private func moreCommentsRow(_ comment: CommentCardModel) -> some View {
        let continueURL = continueThreadURL(comment)
        return HStack(spacing: 10) {
            Image(systemName: "ellipsis.bubble")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(continueURL == nil ? "Load \(comment.moreCount ?? 0) more comments" : "Continue this thread")
                    .font(.subheadline.weight(.semibold))
                if store.moreFailedIDs.contains(comment.id) {
                    Text("The child comments could not be loaded. Try again.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            if store.moreLoadingIDs.contains(comment.id) {
                ProgressView()
            } else {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.leading, min(CGFloat(comment.depth) * 8, 48) + 12)
        .padding(.trailing)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .onTapGesture {
            if let continueURL {
                router.push(.postURL(continueURL))
            } else {
                Task { await store.loadMoreComments(comment.id, for: currentPost, sort: commentSort) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(continueURL == nil ? "Load \(comment.moreCount ?? 0) more comments" : "Continue this thread")
    }

    private func dismissMediaViewerAndStay() {
        isMediaViewerPresented = false
    }

    private func performVote(postID: String, value: Int) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
            let accountID = dependencies.accounts.selectedAccountID
        else {
            showingLogin = true
            return
        }
        let token = dependencies.accounts.token(for: accountID)
        Task {
            do {
                try await store.performVote(postID: postID, value: value, accountID: accountID)
            } catch let error as RedditClientError where error == .authenticationRequired {
                guard dependencies.accounts.isCurrent(token) else { return }
                await dependencies.accounts.markNeedsLogin(accountID)
            } catch {
                // The store has already restored the previous local value.
            }
        }
    }

    private func performSave(postID: String) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
            let accountID = dependencies.accounts.selectedAccountID
        else {
            showingLogin = true
            return
        }
        let token = dependencies.accounts.token(for: accountID)
        Task {
            do {
                try await store.performSave(postID: postID, accountID: accountID)
            } catch let error as RedditClientError where error == .authenticationRequired {
                guard dependencies.accounts.isCurrent(token) else { return }
                await dependencies.accounts.markNeedsLogin(accountID)
            } catch {
                // The store has already restored the previous local value.
            }
        }
    }

    private func beginReply(to targetID: String) {
        guard dependencies.accounts.selectedAccount?.health == .healthy else {
            showingLogin = true
            return
        }
        composerTarget = CommentComposerTarget(id: targetID, post: currentPost)
    }

    private func performCommentVote(commentID: String, value: Int) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
            let accountID = dependencies.accounts.selectedAccountID
        else {
            showingLogin = true
            return
        }
        let token = dependencies.accounts.token(for: accountID)
        Task {
            do {
                try await store.performCommentVote(id: commentID, value: value, accountID: accountID)
            } catch let error as RedditClientError where error == .authenticationRequired {
                guard dependencies.accounts.isCurrent(token) else { return }
                await dependencies.accounts.markNeedsLogin(accountID)
            } catch {}
        }
    }

}

private struct CommentComposerTarget: Identifiable {
    let id: String
    let post: PostCardModel
}

@MainActor
private final class GalleryScrollViewport {
    var rect: CGRect = .zero
    var anchorID: String?
    var anchorTopOffset: CGFloat?
    var pendingTargetY: CGFloat?
    var pendingContentHeight: CGFloat = 0
    weak var scrollView: UIScrollView?
    var contentSizeObservation: NSKeyValueObservation?

    func attach(to scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        self.scrollView = scrollView
        contentSizeObservation = scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.applyPendingOffset() }
        }
    }

    func applyPendingOffset() {
        guard let requestedY = pendingTargetY else { return }
        guard let scrollView else { return }
        guard !scrollView.isDragging, !scrollView.isTracking else {
            pendingTargetY = nil
            anchorID = nil
            anchorTopOffset = nil
            return
        }
        scrollView.layoutIfNeeded()
        let maximumY = scrollView.contentSize.height - scrollView.bounds.height
            + scrollView.adjustedContentInset.bottom
        guard scrollView.contentSize.height >= pendingContentHeight - 1 else { return }
        let targetY = min(requestedY, max(-scrollView.adjustedContentInset.top, maximumY))
        pendingTargetY = nil
        rect.origin.y = targetY
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: targetY), animated: false)
        anchorID = nil
        anchorTopOffset = nil
    }
}

@MainActor
private struct GalleryScrollAnchorBridge: UIViewRepresentable {
    let viewport: GalleryScrollViewport
    let revision: Int

    func makeUIView(context: Context) -> AnchorView {
        AnchorView(viewport: viewport)
    }

    func updateUIView(_ view: AnchorView, context: Context) {
        view.viewport = viewport
        view.findScrollView()
        DispatchQueue.main.async { [weak view] in view?.viewport.applyPendingOffset() }
    }

    final class AnchorView: UIView {
        var viewport: GalleryScrollViewport

        init(viewport: GalleryScrollViewport) {
            self.viewport = viewport
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { return nil }

        override func didMoveToSuperview() {
            super.didMoveToSuperview()
            findScrollView()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            findScrollView()
        }

        func findScrollView() {
            var ancestor = superview
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    viewport.attach(to: scrollView)
                    break
                }
                ancestor = view.superview
            }
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            findScrollView()
            DispatchQueue.main.async { [weak self] in self?.viewport.applyPendingOffset() }
        }
    }
}

@MainActor
struct GalleryView: View {
    let descriptor: FeedDescriptorModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var columnCount = 2
    var onClose: (() -> Void)?

    @Environment(AppDependencies.self) private var dependencies
    @State private var selectedItem: GalleryMediaItem?
    @State private var imageRatios: [URL: CGFloat] = [:]
    @State private var scrollViewport = GalleryScrollViewport()
    @State private var visibleBand = 0
    @State private var viewportHeight: CGFloat = 0
    @State private var layoutRevision = 0
    @State private var lastRequestedCursor: String?
    /// A per-visit override of the blur preferences, so the toolbar button can
    /// unblur this grid without changing the saved setting.
    @State private var revealsSensitiveMedia = false

    private var blursSensitiveMedia: Bool {
        dependencies.settings.blurNSFWMedia || dependencies.settings.blurSpoilers
    }

    private var items: [GalleryMediaItem] {
        GalleryMediaItem.items(from: store.visibleFeedPosts.filter {
            descriptor.kind != .community || $0.community.caseInsensitiveCompare(descriptor.name) == .orderedSame
        })
    }

    private func loadNextPageIfNeeded(contentHeight: CGFloat, visibleRect: CGRect) {
        guard visibleRect.height > 0,
              visibleRect.maxY >= contentHeight - visibleRect.height / 2,
              !items.isEmpty,
              store.feedState == .loaded,
              store.nextPageError == nil,
              let cursor = store.galleryPageCursor(for: descriptor),
              cursor != lastRequestedCursor else { return }
        lastRequestedCursor = cursor
        Task { await store.loadMorePosts(for: descriptor) }
    }

    var body: some View {
        GeometryReader { geometry in
            let galleryItems = items
            let layout = GalleryMasonryLayout(
                items: galleryItems,
                columns: columnCount,
                width: geometry.size.width,
                ratios: imageRatios
            )
            let bandHeight = max(viewportHeight, geometry.size.height) / 2
            let preloadDistance = max(viewportHeight, geometry.size.height) * 1.5
            let nearby = CGRect(
                x: 0,
                y: max(0, CGFloat(visibleBand) * bandHeight - preloadDistance),
                width: geometry.size.width,
                height: max(viewportHeight, geometry.size.height) + bandHeight + 2 * preloadDistance
            )
            ScrollView {
                VStack(spacing: 0) {
                    ZStack(alignment: .topLeading) {
                        Color.clear.frame(width: geometry.size.width, height: layout.height)
                        ForEach(layout.placements.filter { $0.frame.intersects(nearby) }) { placement in
                            GalleryMediaTile(
                                item: placement.item,
                                blursNSFW: dependencies.settings.blurNSFWMedia && !revealsSensitiveMedia,
                                blursSpoilers: dependencies.settings.blurSpoilers && !revealsSensitiveMedia,
                                onOpen: { selectedItem = placement.item },
                                onAspectRatio: { ratio in
                                    guard let url = placement.item.previewURL,
                                          ratio.isFinite, ratio > 0,
                                          imageRatios[url] != ratio else { return }
                                    if scrollViewport.scrollView?.isDragging != true,
                                       scrollViewport.anchorID == nil,
                                       let anchor = layout.placements
                                        .filter({ $0.frame.maxY > scrollViewport.rect.minY &&
                                            $0.frame.minY < scrollViewport.rect.maxY })
                                        .min(by: { abs($0.frame.minY - scrollViewport.rect.minY) <
                                            abs($1.frame.minY - scrollViewport.rect.minY) }) {
                                        scrollViewport.anchorID = anchor.id
                                        scrollViewport.anchorTopOffset = anchor.frame.minY - scrollViewport.rect.minY
                                    }
                                    imageRatios[url] = ratio
                                    layoutRevision += 1
                                },
                                frameRatio: placement.frame.width / placement.frame.height
                            )
                            .frame(width: placement.frame.width, height: placement.frame.height)
                            .position(x: placement.frame.midX, y: placement.frame.midY)
                        }
                    }
                    .frame(width: geometry.size.width, height: layout.height)
                    .background(GalleryScrollAnchorBridge(viewport: scrollViewport, revision: layoutRevision))

                    if case .failed(let message) = store.feedState {
                        VStack(spacing: 12) {
                            Text(message).font(.callout).foregroundStyle(.secondary)
                            Button("Try again") {
                                Task { await store.refreshPosts(for: descriptor, forceRefresh: true) }
                            }
                        }
                        .padding()
                    } else if store.feedState == .loading || store.feedState == .idle {
                        ProgressView("Loading gallery").padding()
                    } else if store.nextPageError != nil, store.galleryPageCursor(for: descriptor) != nil {
                        Button("Couldn't load more. Retry") { Task { await store.loadMorePosts(for: descriptor) } }
                            .buttonStyle(.bordered)
                            .padding()
                    } else if store.galleryPageCursor(for: descriptor) != nil {
                        ProgressView("Loading more")
                            .padding()
                    } else if items.isEmpty {
                        ContentUnavailableView("No media posts", systemImage: "photo.on.rectangle.angled",
                            description: Text("This feed has no displayable images or videos."))
                            .padding(.top, 60)
                    } else {
                        Text("You've reached the end.")
                            .font(.footnote).foregroundStyle(.secondary).padding()
                    }
                }
            }
            .onScrollGeometryChange(for: CGRect.self) { $0.visibleRect } action: { _, newRect in
                if scrollViewport.scrollView?.isDragging == true {
                    scrollViewport.anchorID = nil
                    scrollViewport.anchorTopOffset = nil
                    scrollViewport.pendingTargetY = nil
                }
                scrollViewport.rect = newRect
                let newHeight = max(1, newRect.height)
                if abs(viewportHeight - newHeight) > 1 { viewportHeight = newHeight }
                let newBand = max(0, Int(floor(newRect.minY / (newHeight / 2))))
                if visibleBand != newBand { visibleBand = newBand }
                loadNextPageIfNeeded(contentHeight: layout.height, visibleRect: newRect)
            }
            .onChange(of: layout.height) { _, newHeight in
                loadNextPageIfNeeded(contentHeight: newHeight, visibleRect: scrollViewport.rect)
            }
            .onChange(of: layoutRevision) { _, _ in
                if let anchorID = scrollViewport.anchorID,
                   let topOffset = scrollViewport.anchorTopOffset,
                   let anchor = layout.placements.first(where: { $0.id == anchorID }) {
                    scrollViewport.pendingContentHeight = layout.height
                    scrollViewport.pendingTargetY = max(0, anchor.frame.minY - topOffset)
                }
                scrollViewport.applyPendingOffset()
            }
            .onChange(of: store.galleryPageCursor(for: descriptor)) { _, _ in
                loadNextPageIfNeeded(contentHeight: layout.height, visibleRect: scrollViewport.rect)
            }
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(onClose != nil)
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Back to feed", systemImage: "chevron.left", action: onClose)
                        .labelStyle(.iconOnly)
                        .accessibilityIdentifier("duo-gallery-back")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if blursSensitiveMedia {
                    Button {
                        revealsSensitiveMedia.toggle()
                    } label: {
                        Label("Sensitive media blur", systemImage: revealsSensitiveMedia ? "eye" : "eye.slash")
                    }
                    .accessibilityLabel("Sensitive media blur")
                    .accessibilityValue(revealsSensitiveMedia ? "Off" : "On")
                    .accessibilityHint(revealsSensitiveMedia ? "Blur sensitive images" : "Show sensitive images")
                }
            }
        }
        .task { await store.refreshPosts(for: descriptor) }
        .refreshable { await store.refreshPosts(for: descriptor, forceRefresh: true) }
        .fullScreenCover(item: $selectedItem) { item in
            OctonautMediaViewer(post: item.post, initialPage: item.page, initiallyRevealed: revealsSensitiveMedia, onOpenPost: {
                selectedItem = nil
                router.push(.post(item.post))
            })
        }
    }
}
