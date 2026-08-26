import SwiftUI

@MainActor
struct PostsRootView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
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
                    NavigationLink(value: FeatureRoute.feed(.home)) {
                        Label("Home", systemImage: "house.fill")
                    }
                    NavigationLink(value: FeatureRoute.feed(.popular)) {
                        Label("Popular", systemImage: "flame.fill")
                    }
                    NavigationLink(value: FeatureRoute.feed(.all)) {
                        Label("All", systemImage: "globe")
                    }
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
            case .quickCommunitySearch: QuickCommunitySearchView(store: store, router: router)
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
        NavigationLink(value: FeatureRoute.community(community.name)) {
            OctonautCommunityRow(
                community: community,
                onFavorite: { store.toggleFavorite(communityID: community.id) },
                onSubscribe: { store.toggleSubscribe(communityID: community.id) }
            )
        }
        // Keep the system disclosure indicator on the same trailing line as
        // the section controls while the row content still spans the width.
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 14))
    }
}

@MainActor
struct FeedView: View {
    let descriptor: FeedDescriptorModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingLogin = false
    @State private var selectedMediaPost: PostCardModel?
    @State private var selectedMediaPage = 0
    @State private var browserDestination: OctonautBrowserDestination?

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
                                    OctonautCompactPostRow(post: post, thumbnailOnRight: thumbnailOnRight, showsFlair: dependencies.settings.showPostFlair, onVote: { value in performVote(postID: post.id, value: value) }, onSave: { performSave(postID: post.id) }, onOpen: { router.push(.post(post)) }, onCommunityOpen: { router.push(.post(post)) })
                                } else {
                                    OctonautPostRow(
                                        post: post,
                                        showsFlair: dependencies.settings.showPostFlair,
                                        onVote: { value in
                                            performVote(postID: post.id, value: value)
                                        },
                                        onSave: { performSave(postID: post.id) },
                                        onSeen: { store.markSeen(postID: post.id) },
                                        onMedia: { page in
                                            selectedMediaPage = page
                                            selectedMediaPost = post
                                        },
                                        onOpen: { router.push(.post(post)) },
                                        onComments: { router.push(.post(post)) },
                                        onCommunityOpen: { router.push(.post(post)) },
                                        onCrosspost: {
                                            browserDestination = OctonautBrowserDestination(url: post.crosspostURL)
                                        }
                                    )
                                }
                            }
                            .listRowInsets(EdgeInsets())
                            .listRowSeparator(.hidden)
                            .id(post.id)
                            .onAppear {
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
        .sheet(isPresented: $showingLogin) {
            RedditLoginView(accounts: dependencies.accounts)
        }
        .sheet(item: $browserDestination) { destination in
            OctonautBrowserView(url: destination.url)
                .ignoresSafeArea()
        }
        .fullScreenCover(item: $selectedMediaPost) { post in
            OctonautMediaViewer(
                post: post,
                initialPage: selectedMediaPage,
                onSave: { performSave(postID: post.id) },
                onOpenPost: { router.push(.post(post)) }
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

    private var community: CommunityCardModel? { store.communities.first { $0.name.caseInsensitiveCompare(name) == .orderedSame } }

    var body: some View {
        FeedView(descriptor: FeedDescriptorModel(kind: .community, name: name), store: store, router: router)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if let community {
                        Button { store.toggleSubscribe(communityID: community.id) } label: {
                            Label(community.isSubscribed ? "Joined" : "Join", systemImage: community.isSubscribed ? "checkmark" : "person.badge.plus")
                        }
                    }
                }
            }
    }
}

@MainActor
struct QuickCommunitySearchView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    var body: some View {
        NavigationStack {
            List(store.communities.filter { query.isEmpty || $0.name.localizedStandardContains(query) }) { community in
                Button {
                    dismiss()
                    router.push(.community(community.name))
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
