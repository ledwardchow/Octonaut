import SwiftUI
import UIKit

@MainActor
struct PostDetailView: View {
    let post: PostCardModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @State private var commentSort = "Best"
    @State private var composer: ComposerKind?
    @State private var isMediaViewerPresented = false
    @State private var selectedMediaPage = 0
    @State private var showingLogin = false
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
            VStack(alignment: .leading, spacing: 0) {
                OctonautPostRow(
                    post: currentPost,
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
                    communityOpenAccessibilityHint: "Opens the subreddit"
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
                } else if case .failed(let message) = store.detailState {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Comments could not be loaded").font(.subheadline.weight(.semibold))
                            Text(message).font(.caption).foregroundStyle(.secondary)
                            Button("Retry") {
                                Task { await store.loadPostDetail(for: currentPost, sort: commentSort) }
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
                        automatic: dependencies.settings.automaticVisibleSummaries,
                        useFallback: dependencies.settings.keyExcerptsFallback
                    )
                }
                if dependencies.settings.showCommentSummaries,
                   store.detailState == .loaded,
                   SummaryEligibility.comments(summaryComments) {
                    SummaryCardView(
                        title: "Comments Summary",
                        input: .comments(
                            CommentSummaryInput(postID: currentPost.id, comments: summaryComments)
                        ),
                        intelligence: dependencies.intelligence,
                        automatic: dependencies.settings.automaticCommentSummaries,
                        useFallback: dependencies.settings.keyExcerptsFallback
                    )
                }

                HStack {
                    Text("Comments")
                        .font(.title3.weight(.bold))
                    Spacer()
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

                ForEach(flattenedComments) { comment in
                    if comment.isMoreNode {
                        moreCommentsRow(comment)
                    } else {
                        OctonautCommentRow(
                            comment: comment,
                            postAuthor: currentPost.author,
                            onCollapse: {
                                withAnimation(.snappy(duration: 0.2)) {
                                    store.toggleComment(id: comment.id)
                                }
                            }, onVote: { performCommentVote(commentID: comment.id, value: $0) },
                            onReply: { beginReply() })
                    }
                }
                if flattenedComments.isEmpty {
                    ContentUnavailableView(
                        "No comments", systemImage: "bubble.left.and.bubble.right",
                        description: Text("There are no comments to show.")
                    )
                    .padding(.top, 40)
                }
            }
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("Post")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
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
        .sheet(item: $composer) { kind in
            ComposerView(kind: kind, store: store)
        }
        .sheet(isPresented: $showingLogin) {
            RedditLoginView(accounts: dependencies.accounts)
        }
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

    @ViewBuilder
    private func moreCommentsRow(_ comment: CommentCardModel) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "ellipsis.bubble")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("Load \(comment.moreCount ?? 0) more comments")
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
            Task { await store.loadMoreComments(comment.id, for: currentPost, sort: commentSort) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Load \(comment.moreCount ?? 0) more comments")
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

    private func beginReply() {
        guard dependencies.accounts.selectedAccount?.health == .healthy else {
            showingLogin = true
            return
        }
        composer = .comment
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

@MainActor
struct GalleryView: View {
    let descriptor: FeedDescriptorModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter

    @State private var selectedItem: GalleryMediaItem?
    @State private var blurNSFW = true

    private var items: [GalleryMediaItem] {
        GalleryMediaItem.items(from: store.posts.filter {
            descriptor.kind != .community || $0.community.caseInsensitiveCompare(descriptor.name) == .orderedSame
        })
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    ForEach(0..<2) { column in
                        LazyVStack(spacing: 4) {
                            ForEach(Array(items.enumerated()).filter { $0.offset % 2 == column }.map(\.element)) { item in
                                GalleryMediaTile(item: item, blurNSFW: blurNSFW) { selectedItem = item }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 4)

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
                } else if store.galleryPageCursor(for: descriptor) != nil {
                    ProgressView("Loading more")
                        .padding()
                        .task(id: store.galleryPageCursor(for: descriptor)) {
                            await store.loadMorePosts(for: descriptor)
                        }
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
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    blurNSFW.toggle()
                } label: {
                    Label("NSFW blur", systemImage: blurNSFW ? "eye.slash" : "eye")
                }
                .accessibilityLabel("NSFW blur")
                .accessibilityValue(blurNSFW ? "On" : "Off")
                .accessibilityHint(blurNSFW ? "Show NSFW images" : "Blur NSFW images")
            }
        }
        .task { await store.refreshPosts(for: descriptor) }
        .refreshable { await store.refreshPosts(for: descriptor, forceRefresh: true) }
        .fullScreenCover(item: $selectedItem) { item in
            OctonautMediaViewer(post: item.post, initialPage: item.page, onOpenPost: {
                selectedItem = nil
                router.push(.post(item.post))
            })
        }
    }
}
