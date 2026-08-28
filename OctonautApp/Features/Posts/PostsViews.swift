import SwiftUI

@MainActor
struct PostsRootView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onSelectFeed: ((FeedDescriptorModel) -> Void)? = nil
    var selectedFeed: FeedDescriptorModel? = nil
    @Environment(AppDependencies.self) private var dependencies
    @State private var communityQuery = ""
    @AppStorage("posts.sections.feeds.expanded") private var feedsExpanded = true
    @AppStorage("posts.sections.favorites.expanded") private var favoritesExpanded = true
    @AppStorage("posts.sections.communities.expanded") private var communitiesExpanded = true

    private var filteredCommunities: [CommunityCardModel] {
        guard !communityQuery.isEmpty else { return store.communities }
        return store.communities.filter { $0.name.localizedStandardContains(communityQuery) }
    }

    var body: some View {
        List {
            Section {
                if feedsExpanded {
                    feedLink(.home, title: "Home", systemImage: "house.fill")
                    feedLink(.popular, title: "Popular", systemImage: "flame.fill")
                    feedLink(.all, title: "All", systemImage: "globe")
                }
            } header: {
                collapsibleHeader("Feeds", count: 3, systemImage: "rectangle.stack", isExpanded: $feedsExpanded)
            }

            Section {
                if favoritesExpanded {
                    let favorites = filteredCommunities.filter(\.isFavorite)
                    if favorites.isEmpty {
                        Text(dependencies.accounts.selectedAccount == nil ? "Sign in to load account favorites." : "Tap a star beside a community to add it here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(favorites) { community in
                            communityLink(community)
                        }
                    }
                }
            } header: {
                collapsibleHeader("Favorites", count: filteredCommunities.filter(\.isFavorite).count, systemImage: "star.fill", isExpanded: $favoritesExpanded)
            }

            Section {
                if communitiesExpanded {
                    communitiesContent
                }
            } header: {
                collapsibleHeader("Communities", count: filteredCommunities.filter { !$0.isFavorite }.count, systemImage: "person.3.fill", isExpanded: $communitiesExpanded)
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Posts")
        .searchable(text: $communityQuery, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a community")
        .refreshable { await store.refreshCommunities(forceRefresh: true) }
        .task(id: store.accountContextKey) { await store.refreshCommunities() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { router.presentedSheet = .composer(.post) } label: { Label("New Post", systemImage: "square.and.pencil") }
                    Button { router.push(.gallery(.home)) } label: { Label("Gallery Mode", systemImage: "square.grid.2x2") }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add")
            }
        }
        .sheet(item: Binding(get: { router.presentedSheet }, set: { router.presentedSheet = $0 })) { sheet in
            switch sheet {
            case .composer(let kind): ComposerView(kind: kind, store: store)
            case .quickCommunitySearch: QuickCommunitySearchView(store: store, router: router, onSelectFeed: onSelectFeed)
            case .quickAccountSwitcher: QuickAccountSwitcherView(store: store)
            }
        }
    }

    @ViewBuilder
    private var communitiesContent: some View {
        switch store.communitiesState {
        case .loading where store.communities.isEmpty:
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading subscriptions…").foregroundStyle(.secondary)
            }
        case .failed(let message) where store.communities.isEmpty:
            VStack(alignment: .leading, spacing: 6) {
                Label("Communities could not be loaded", systemImage: "exclamationmark.triangle")
                Text(message).font(.caption).foregroundStyle(.secondary)
                Button("Try Again") { Task { await store.refreshCommunities() } }
            }
        default:
            let values = filteredCommunities.filter { !$0.isFavorite }
            if values.isEmpty {
                Text(dependencies.accounts.selectedAccount == nil ? "Sign in to load your Reddit subscriptions." : "No subscribed communities found.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(values) { community in
                    communityLink(community)
                }
            }
            if case .failed(let message) = store.communitiesState {
                Text(message).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private func collapsibleHeader(_ title: String, count: Int, systemImage: String, isExpanded: Binding<Bool>) -> some View {
        Button {
            withAnimation(.snappy(duration: 0.2)) {
                isExpanded.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 8) {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Image(systemName: isExpanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 20, alignment: .center)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count)")
        .accessibilityValue(isExpanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    @ViewBuilder
    private func communityLink(_ community: CommunityCardModel) -> some View {
        let row = OctonautCommunityRow(
            community: community,
            onFavorite: { store.toggleFavorite(communityID: community.id) },
            onSubscribe: { store.toggleSubscribe(communityID: community.id) }
        )
        Group {
            if let onSelectFeed {
                Button {
                    onSelectFeed(FeedDescriptorModel(kind: .community, name: community.name))
                } label: {
                    row
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: FeatureRoute.community(community.name)) {
                    row
                }
            }
        }
        .listRowBackground(isSelected(FeedDescriptorModel(kind: .community, name: community.name)) ? Color.accentColor.opacity(0.12) : Color.clear)
        // Keep the system disclosure indicator on the same trailing line as
        // the section controls while the row content still spans the width.
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 14))
    }

    @ViewBuilder
    private func feedLink(_ descriptor: FeedDescriptorModel, title: String, systemImage: String) -> some View {
        Group {
            if let onSelectFeed {
                Button {
                    onSelectFeed(descriptor)
                } label: {
                    Label(title, systemImage: systemImage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink(value: FeatureRoute.feed(descriptor)) {
                    Label(title, systemImage: systemImage)
                }
            }
        }
        .listRowBackground(isSelected(descriptor) ? Color.accentColor.opacity(0.12) : Color.clear)
    }

    private func isSelected(_ descriptor: FeedDescriptorModel) -> Bool {
        guard onSelectFeed != nil, let selectedFeed else { return false }
        return selectedFeed.kind == descriptor.kind
            && selectedFeed.name.caseInsensitiveCompare(descriptor.name) == .orderedSame
    }
}

@MainActor
struct FeedView: View {
    let descriptor: FeedDescriptorModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onSelectPost: ((PostCardModel) -> Void)? = nil
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingLogin = false
    @State private var selectedMediaPost: PostCardModel?
    @State private var selectedMediaPage = 0
    @State private var crosspostPost: PostCardModel?
    @State private var pendingScrollPoints: CGFloat = 0
    @State private var mediaPreloader = OctonautFeedMediaPreloader()

    private let mediaPreloadDistance = 20

    private var compactRows: Bool { dependencies.settings.feedLayout == .compact }
    private var thumbnailOnRight: Bool { dependencies.settings.compactThumbnailSide == .right }

    private var visiblePosts: [PostCardModel] {
        switch descriptor.kind {
        case .community:
            return store.posts.filter { $0.community.caseInsensitiveCompare(descriptor.name) == .orderedSame }
        default:
            return store.posts
        }
    }

    var body: some View {
        OctonautStateView(state: store.feedState, retry: { Task { await store.refreshPosts(for: descriptor) } }) {
            if visiblePosts.isEmpty {
                ContentUnavailableView("No posts", systemImage: "text.page.slash", description: Text("This feed is empty or your filters removed every post."))
            } else {
                ScrollViewReader { proxy in
                    List {
                        if store.filteredPostCount > 0, dependencies.settings.showFilterCount {
                            Label("\(store.filteredPostCount) posts hidden by your filters", systemImage: "line.3.horizontal.decrease.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        ForEach(Array(visiblePosts.enumerated()), id: \.element.id) { index, post in
                            Group {
                                if compactRows {
                                    OctonautCompactPostRow(post: post, thumbnailOnRight: thumbnailOnRight, showsFlair: dependencies.settings.showPostFlair, onVote: { value in performVote(postID: post.id, value: value) }, onSave: { performSave(postID: post.id) }, onOpen: { open(post) }, onCommunityOpen: { open(post) })
                                } else {
                                    OctonautPostRow(
                                        post: post,
                                        showsFlair: dependencies.settings.showPostFlair,
                                        mediaPreloader: mediaPreloader,
                                        onVote: { value in
                                            performVote(postID: post.id, value: value)
                                        },
                                        onSave: { performSave(postID: post.id) },
                                        onSeen: { store.markSeen(postID: post.id) },
                                        onMedia: { page in
                                            selectedMediaPage = page
                                            selectedMediaPost = post
                                        },
                                        onOpen: { open(post) },
                                        onComments: { open(post) },
                                        onCommunityOpen: { open(post) },
                                        onCrosspost: {
                                            beginCrosspost(post)
                                        }
                                    )
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .id(post.id)
                            .onAppear {
                                preloadMedia(after: index)
                                if dependencies.settings.autoMarkSeenWhileScrolling, !post.isSeen {
                                    store.markSeen(postID: post.id)
                                }
                                if index >= visiblePosts.count - 2 { Task { await store.loadMorePosts(for: descriptor) } }
                            }
                        }
                        if store.feedState == .loading, !visiblePosts.isEmpty {
                            HStack { Spacer(); ProgressView("Loading more…"); Spacer() }.padding()
                                .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await store.refreshPosts(for: descriptor, forceRefresh: true) }
                    .onChange(of: visiblePosts.first?.id) { _, firstID in
                        guard let firstID else { return }
                        proxy.scrollTo(firstID, anchor: .top)
                    }
                    .onScrollGeometryChange(for: CGFloat.self) { geometry in
                        geometry.contentOffset.y + geometry.contentInsets.top
                    } action: { oldOffset, newOffset in
                        pendingScrollPoints += abs(newOffset - oldOffset)
                        guard pendingScrollPoints >= 100 else { return }
                        let points = Int(pendingScrollPoints.rounded())
                        pendingScrollPoints = 0
                        Task { await store.recordFeedScroll(points: points) }
                    }
                }
            }
        }
        .navigationTitle(descriptor.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Menu {
                    ForEach(["Best", "Hot", "New", "Top", "Rising", "Controversial"], id: \.self) { sort in
                        Button {
                            store.selectedSort = sort
                            Task { await store.refreshPosts(for: descriptor, forceRefresh: true) }
                        } label: {
                            if store.selectedSort == sort { Label(sort, systemImage: "checkmark") } else { Text(sort) }
                        }
                    }
                } label: {
                    HStack(spacing: 5) { Text(descriptor.name); Image(systemName: "chevron.down") }
                        .font(.headline)
                }
                .accessibilityLabel("Sort \(store.selectedSort)")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Toggle(isOn: Binding(
                        get: { dependencies.settings.feedLayout == .compact },
                        set: { dependencies.settings.feedLayout = $0 ? .compact : .full }
                    )) { Label("Compact Rows", systemImage: "list.bullet") }
                    Button { router.push(.gallery(descriptor)) } label: { Label("Gallery Mode", systemImage: "square.grid.2x2") }
                    Button { store.posts.map(\.id).forEach { store.markSeen(postID: $0) } } label: { Label("Mark Visible Seen", systemImage: "eye") }
                    ShareLink(item: URL(string: "https://www.reddit.com")!) { Label("Share Feed", systemImage: "square.and.arrow.up") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("Feed actions")
            }
        }
        .task(id: "\(descriptor.kind.rawValue):\(descriptor.name):\(descriptor.sort):\(store.accountContextKey)") {
            await store.refreshPosts(for: descriptor)
        }
        .task(id: visiblePosts.map(\.id)) {
            mediaPreloader.preload(
                posts: visiblePosts.prefix(mediaPreloadDistance),
                compact: compactRows
            )
        }
        .sheet(isPresented: $showingLogin) {
            RedditLoginView(accounts: dependencies.accounts)
        }
        .sheet(item: $crosspostPost) { post in
            CrosspostComposerView(post: post)
        }
        .fullScreenCover(item: $selectedMediaPost) { post in
            OctonautMediaViewer(
                post: post,
                initialPage: selectedMediaPage,
                onSave: { performSave(postID: post.id) },
                onOpenPost: { open(post) }
            )
        }
    }

    private func performVote(postID: String, value: Int) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
              let accountID = dependencies.accounts.selectedAccountID else {
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

    private func open(_ post: PostCardModel) {
        if let onSelectPost {
            onSelectPost(post)
        } else {
            router.push(.post(post))
        }
    }

    private func preloadMedia(after index: Int) {
        let posts = visiblePosts
        guard posts.indices.contains(index) else { return }
        let end = min(posts.count, index + mediaPreloadDistance + 1)
        mediaPreloader.preload(posts: posts[index..<end], compact: compactRows)
    }

    private func beginCrosspost(_ post: PostCardModel) {
        guard dependencies.accounts.selectedAccount?.health == .healthy else {
            showingLogin = true
            return
        }
        crosspostPost = post
    }

    private func performSave(postID: String) {
        guard dependencies.accounts.selectedAccount?.health == .healthy,
              let accountID = dependencies.accounts.selectedAccountID else {
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
}

@MainActor
struct CommunityView: View {
    let name: String
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onSelectPost: ((PostCardModel) -> Void)? = nil

    private var community: CommunityCardModel? { store.communities.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    var body: some View {
        FeedView(
            descriptor: FeedDescriptorModel(kind: .community, name: name),
            store: store,
            router: router,
            onSelectPost: onSelectPost
        )
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let community {
                        Button { store.toggleSubscribe(communityID: community.id) } label: {
                            Label(community.isSubscribed ? "Joined" : "Join", systemImage: community.isSubscribed ? "checkmark" : "person.badge.plus")
                        }
                    }
                }
            }
            .task(id: IDNormalization.community(name)) {
                await store.recordCommunityVisit(name)
            }
    }
}

@MainActor
struct QuickCommunitySearchView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onSelectFeed: ((FeedDescriptorModel) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(store.communities.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { community in
                Button {
                    dismiss()
                    let descriptor = FeedDescriptorModel(kind: .community, name: community.name)
                    if let onSelectFeed {
                        onSelectFeed(descriptor)
                    } else {
                        router.push(.community(community.name))
                    }
                } label: {
                    OctonautCommunityRow(community: community)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Quick Community Search")
            .searchable(text: $query, prompt: "Community name")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

@MainActor
struct QuickAccountSwitcherView: View {
    let store: OctonautFeatureStore
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(dependencies.accounts.accounts) { account in
                Button {
                    Task { try? await dependencies.accounts.select(account.id) }
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: "person.crop.circle.fill").font(.title2)
                        Text(account.username)
                        Spacer()
                        if dependencies.accounts.selectedAccountID == account.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Switch Account")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }
}
