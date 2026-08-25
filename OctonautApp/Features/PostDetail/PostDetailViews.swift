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
    @Environment(\.openURL) private var openURL

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
                    post: currentPost, bodyLineLimit: nil,
                    onVote: { performVote(postID: currentPost.id, value: $0) },
                    onSave: { performSave(postID: currentPost.id) },
                    onSeen: { store.markSeen(postID: currentPost.id) },
                    onMedia: { page in
                        selectedMediaPage = page
                        isMediaViewerPresented = true
                    }
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

                if dependencies.settings.showPostSummaries {
                    SummaryCardView(
                        title: "Post Summary",
                        input: .post(
                            PostSummaryInput(id: currentPost.id, title: currentPost.title, body: currentPost.body)
                        ),
                        intelligence: dependencies.intelligence,
                        automatic: dependencies.settings.automaticVisibleSummaries,
                        eligible: postSummaryEligible,
                        useFallback: dependencies.settings.keyExcerptsFallback
                    )
                }
                    if dependencies.settings.showCommentSummaries,
                       store.detailState == .loaded,
                       SummaryEligibility.comments(summaryComments) {
                        SummaryCardView(
                        title: "Comments Summary",
                        input: .comments(
                            CommentSummaryInput(postID: currentPost.id, comments: summaryComments)),
                        intelligence: dependencies.intelligence,
                        automatic: dependencies.settings.automaticCommentSummaries,
                            eligible: true,
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
                        openURL(currentPost.shareURL)
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                    }
                    ShareLink(item: currentPost.shareURL) {
                        Label("Share Link", systemImage: "square.and.arrow.up")
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
        .fullScreenCover(isPresented: $isMediaViewerPresented) {
            OctonautMediaViewer(
                post: currentPost, initialPage: selectedMediaPage,
                onSave: { performSave(postID: currentPost.id) },
                onOpenPost: { dismissMediaViewerAndStay() })
        }
        .task(id: "\(post.id):\(commentSort):\(store.accountContextKey)") {
            await store.loadPostDetail(for: post, sort: commentSort)
        }
    }

    private var postSummaryEligible: Bool {
        SummaryEligibility.post(title: currentPost.title, body: currentPost.body)
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

    private let columns = [GridItem(.flexible(), spacing: 2), GridItem(.flexible(), spacing: 2)]
    private var mediaPosts: [PostCardModel] { store.posts.filter(\.hasMedia) }
    @State private var selectedPost: PostCardModel?
    @State private var showPager = false

    var body: some View {
        ScrollView {
            if mediaPosts.isEmpty {
                ContentUnavailableView(
                    "No media posts", systemImage: "photo.on.rectangle.angled",
                    description: Text("This feed has no displayable image or video posts.")
                )
                .padding(.top, 80)
            } else {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(mediaPosts) { post in
                        Button {
                            selectedPost = post
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                OctonautAsyncImage(url: post.thumbnailURL ?? post.mediaURL ?? post.galleryURLs.first)
                                    .aspectRatio(1, contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    .clipped()
                                Image(systemName: post.isVideo ? "play.circle.fill" : "photo")
                                    .font(.system(size: 34))
                                    .foregroundStyle(.secondary)
                                LinearGradient(
                                    colors: [.clear, .black.opacity(0.72)], startPoint: .center, endPoint: .bottom)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(post.title).font(.caption.weight(.semibold)).lineLimit(2)
                                    Text("r/\(post.community)").font(.caption2)
                                }
                                .foregroundStyle(.white)
                                .padding(8)
                                if post.isSensitive {
                                    Label("Sensitive", systemImage: "eye.slash")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .padding(6)
                                        .background(.black.opacity(0.65), in: Capsule())
                                        .padding(7)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Gallery")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if !mediaPosts.isEmpty {
                        Button {
                            showPager = true
                        } label: {
                            Label("Full Screen Gallery", systemImage: "rectangle.portrait.on.rectangle.portrait")
                        }
                    }
                    ShareLink(item: URL(string: "https://www.reddit.com")!) {
                        Label("Share Feed", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .fullScreenCover(item: $selectedPost) { post in
            OctonautMediaViewer(post: post)
        }
        .fullScreenCover(isPresented: $showPager) {
            GalleryPagerView(posts: mediaPosts, store: store)
        }
    }
}
