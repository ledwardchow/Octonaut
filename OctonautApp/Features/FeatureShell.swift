import SwiftUI
import UIKit
import Observation

@MainActor
@Observable
final class OctonautFeatureRouter {
    var path: [FeatureRoute]
    var presentedSheet: FeatureSheet?

    init(path: [FeatureRoute] = []) {
        self.path = path
    }

    func push(_ route: FeatureRoute) { path.append(route) }
    func popToRoot() { path.removeAll() }
    func pop() { if !path.isEmpty { path.removeLast() } }
}

@MainActor
@Observable
final class PostsSplitState {
    var selectedFeed: FeedDescriptorModel = .home
    var sidebarCommunity: String?

    @discardableResult
    func select(_ route: FeatureRoute) -> Bool {
        switch route {
        case .feed(let descriptor):
            selectFeed(descriptor)
        case .community(let name):
            selectFeed(FeedDescriptorModel(kind: .community, name: name))
        case .post(let post):
            sidebarCommunity = post.community
            return false
        case .postURL(let url):
            let community = PostCardModel(deepLinkURL: url).community
            sidebarCommunity = community == "reddit" ? nil : community
            return false
        default:
            return false
        }
        return true
    }

    func selectFeed(_ descriptor: FeedDescriptorModel) {
        selectedFeed = descriptor
        sidebarCommunity = descriptor.kind == .community ? descriptor.name : nil
    }

    func selectPost(_ post: PostCardModel) {
        sidebarCommunity = post.community
    }

    func clearDetail() {
        sidebarCommunity = selectedFeed.kind == .community ? selectedFeed.name : nil
    }

    func updateContext(for route: FeatureRoute?) {
        switch route {
        case .post(let post):
            sidebarCommunity = post.community
        case .postURL(let url):
            let community = PostCardModel(deepLinkURL: url).community
            sidebarCommunity = community == "reddit" ? nil : community
        default:
            sidebarCommunity = selectedFeed.kind == .community ? selectedFeed.name : nil
        }
    }
}

/// The app shell keeps a separate router for each tab. The App target can use
/// this view directly, or use the individual tab roots when it owns its own
/// dependency container.
@MainActor
struct OctonautTabsView: View {
    /// The app dependency container supplies the live transport. Keeping this
    /// optional preserves the fixture-backed preview and isolated feature tests.
    let reddit: (any RedditClient)?
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedTab: AppTab = .posts
    @State private var postsRouter = OctonautFeatureRouter(path: [.feed(.home)])
    @State private var inboxRouter = OctonautFeatureRouter()
    @State private var accountRouter = OctonautFeatureRouter()
    @State private var searchRouter = OctonautFeatureRouter()
    @State private var settingsRouter = OctonautFeatureRouter()
    @State private var postsSplitState = PostsSplitState()
    @State private var store: OctonautFeatureStore

    init(store: OctonautFeatureStore = .preview, reddit: (any RedditClient)? = nil) {
        _store = State(initialValue: store)
        self.reddit = reddit
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if usesFloatingTabBar {
                persistentTabContent
                    .safeAreaPadding(.bottom, 82)

                FloatingTabBar(
                    selection: $selectedTab,
                    unreadCount: store.unreadCount,
                    accountTitle: dependencies.accounts.selectedAccount?.username ?? "Account"
                )
                .padding(.horizontal, 24)
                .padding(.bottom, 14)
            } else {
                compactTabs
            }
        }
        .tint(.orange)
        .background(Color(uiColor: .systemBackground))
        .task(id: accountStateKey) {
            store.synchronizeAccount(
                id: dependencies.accounts.selectedAccountID,
                generation: dependencies.accounts.selectionGeneration,
                accounts: dependencies.accounts.accounts
            )
        }
        .onChange(of: dependencies.accounts.selectionGeneration) { _, _ in
            postsSplitState.clearDetail()
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await dependencies.persistence.beginUsageSession() }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard dependencies.settings.openRedditLinksInOctonaut,
                  let route = OctonautFeatureURLRouter.route(url),
                  route.isRedditPost
            else {
                return .systemAction
            }

            handleIncomingURL(url)
            return .handled
        })
    }

    private var accountStateKey: String {
        let accountKey = dependencies.accounts.accounts.map {
            "\($0.id.description):\($0.health.rawValue)"
        }.joined(separator: ",")
        return "\(dependencies.accounts.selectedAccountID?.description ?? "anonymous"):\(dependencies.accounts.selectionGeneration):\(accountKey)"
    }

    private func handleIncomingURL(_ url: URL) {
        guard let route = OctonautFeatureURLRouter.route(url) else { return }
        switch route {
        case .account:
            selectedTab = .account
            accountRouter.push(route)
        case .settings:
            selectedTab = .settings
            settingsRouter.push(route)
        case .search:
            selectedTab = .search
            searchRouter.push(route)
        default:
            selectedTab = .posts
            if shouldUsePostsSplitView, postsSplitState.select(route) {
                postsRouter.popToRoot()
                return
            }
            postsRouter.push(route)
        }
    }

    private var shouldUsePostsSplitView: Bool {
        horizontalSizeClass == .regular && dependencies.settings.useSplitViewOnIPad
    }

    private var usesFloatingTabBar: Bool {
        horizontalSizeClass == .regular
    }

    private var persistentTabContent: some View {
        ZStack {
            ForEach(AppTab.allCases) { tab in
                tabContent(for: tab)
                    .opacity(selectedTab == tab ? 1 : 0)
                    .allowsHitTesting(selectedTab == tab)
                    .accessibilityHidden(selectedTab != tab)
                    .zIndex(selectedTab == tab ? 1 : 0)
            }
        }
    }

    private var compactTabs: some View {
        TabView(selection: $selectedTab) {
            tabContent(for: .posts)
                .tabItem { Label("Posts", systemImage: "rectangle.stack") }
                .tag(AppTab.posts)
            tabContent(for: .inbox)
                .tabItem { Label("Inbox", systemImage: "envelope") }
                .badge(store.unreadCount)
                .tag(AppTab.inbox)
            tabContent(for: .account)
                .tabItem { Label(dependencies.accounts.selectedAccount?.username ?? "Accounts", systemImage: "person.crop.circle") }
                .tag(AppTab.account)
            tabContent(for: .search)
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(AppTab.search)
            tabContent(for: .settings)
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(AppTab.settings)
        }
    }

    @ViewBuilder
    private func tabContent(for tab: AppTab) -> some View {
        switch tab {
        case .posts:
            AdaptivePostsTabView(
                store: store,
                router: postsRouter,
                splitState: postsSplitState
            )
        case .inbox:
            NavigationStack(path: $inboxRouter.path) {
                InboxRootView(store: store, router: inboxRouter)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        OctonautDestinationView(route: route, store: store, router: inboxRouter)
                    }
            }
        case .account:
            NavigationStack(path: $accountRouter.path) {
                AccountRootView(store: store, router: accountRouter)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        OctonautDestinationView(route: route, store: store, router: accountRouter)
                    }
            }
        case .search:
            NavigationStack(path: $searchRouter.path) {
                SearchRootView(store: store, router: searchRouter, reddit: reddit)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        OctonautDestinationView(route: route, store: store, router: searchRouter)
                    }
            }
        case .settings:
            AdaptiveSettingsTabView(store: store, router: settingsRouter)
        }
    }
}

private extension FeatureRoute {
    var isRedditPost: Bool {
        if case .postURL = self { return true }
        return false
    }
}

@MainActor
private struct FloatingTabBar: View {
    @Binding var selection: AppTab
    let unreadCount: Int
    let accountTitle: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: systemImage(for: tab))
                            .font(.system(size: 18, weight: .semibold))
                            .frame(height: 20)
                            .overlay(alignment: .topTrailing) {
                                if tab == .inbox, unreadCount > 0 {
                                    Text(unreadCount > 99 ? "99+" : unreadCount.formatted())
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .frame(minWidth: 18, minHeight: 18)
                                        .background(.red, in: Capsule())
                                        .offset(x: 14, y: -9)
                                }
                            }
                        Text(title(for: tab))
                            .font(.caption2.weight(selection == tab ? .semibold : .regular))
                            .lineLimit(1)
                    }
                    .foregroundStyle(selection == tab ? Color.accentColor : Color.secondary)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .padding(.horizontal, 6)
                    .background {
                        if selection == tab {
                            Capsule()
                                .fill(Color.accentColor.opacity(0.13))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(title(for: tab))
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
        }
        .padding(6)
        .frame(maxWidth: 520)
        .background(.regularMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.primary.opacity(0.09), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
    }

    private func title(for tab: AppTab) -> String {
        switch tab {
        case .account: accountTitle
        default: tab.title
        }
    }

    private func systemImage(for tab: AppTab) -> String {
        switch tab {
        case .posts: "rectangle.stack"
        case .inbox: "envelope"
        case .account: "person.crop.circle"
        case .search: "magnifyingglass"
        case .settings: "gearshape"
        }
    }
}

@MainActor
private struct AdaptivePostsTabView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    let splitState: PostsSplitState
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var router = router

        if horizontalSizeClass == .regular && dependencies.settings.useSplitViewOnIPad {
            PostsSplitView(store: store, router: router, state: splitState)
                .onAppear(perform: consumeSelectionRoutes)
                .onChange(of: router.path) { _, _ in consumeSelectionRoutes() }
        } else {
            NavigationStack(path: $router.path) {
                PostsRootView(store: store, router: router)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        OctonautDestinationView(route: route, store: store, router: router)
                    }
            }
        }
    }

    private func consumeSelectionRoutes() {
        while let route = router.path.last, splitState.select(route) {
            router.path.removeLast()
        }
        splitState.updateContext(for: router.path.last)
    }
}

@MainActor
private struct PostsSplitView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    let state: PostsSplitState

    var body: some View {
        @Bindable var router = router

        HStack(spacing: 0) {
            NavigationStack {
                PostsRootView(
                    store: store,
                    router: router,
                    onSelectFeed: selectFeed,
                    selectedFeed: state.selectedFeed
                )
            }
            .frame(width: 290)

            Divider()

            NavigationStack(path: $router.path) {
                selectedFeedView
                    .navigationDestination(for: FeatureRoute.self) { route in
                        OctonautDestinationView(route: route, store: store, router: router)
                    }
            }
            .frame(maxWidth: .infinity)

            if let community = state.sidebarCommunity {
                Divider()
                SubredditSidebarView(
                    name: community,
                    store: store,
                    router: router,
                    onOpenCommunity: {
                        selectFeed(FeedDescriptorModel(kind: .community, name: community))
                    }
                )
                    .frame(width: 310)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.24), value: state.sidebarCommunity)
    }

    @ViewBuilder
    private var selectedFeedView: some View {
        if state.selectedFeed.kind == .community {
            CommunityView(
                name: state.selectedFeed.name,
                store: store,
                router: router,
                onSelectPost: selectPost
            )
        } else {
            FeedView(
                descriptor: state.selectedFeed,
                store: store,
                router: router,
                onSelectPost: selectPost
            )
        }
    }

    private func selectFeed(_ descriptor: FeedDescriptorModel) {
        router.popToRoot()
        state.selectFeed(descriptor)
    }

    private func selectPost(_ post: PostCardModel) {
        state.selectPost(post)
        router.push(.post(post))
    }
}

@MainActor
private struct SubredditSidebarView: View {
    let name: String
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    let onOpenCommunity: () -> Void
    @Environment(\.openURL) private var openURL

    private var community: CommunityCardModel? {
        store.communities.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if let memberCount = community?.memberCount {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(memberCount.formatted(.number.notation(.compactName)))
                            .font(.title3.weight(.bold))
                        Text("Members")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }

                Text("Posts and discussions from r/\(name).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                actionButtons

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Community")
                        .font(.headline)
                    Button(action: onOpenCommunity) {
                        Label("Open r/\(name)", systemImage: "rectangle.stack")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button {
                        router.presentedSheet = .composer(.post)
                    } label: {
                        Label("Create a post", systemImage: "square.and.pencil")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let redditURL {
                        Button {
                            openURL(redditURL)
                        } label: {
                            Label("Open on Reddit", systemImage: "safari")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ShareLink(item: redditURL) {
                            Label("Share community", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .navigationTitle("r/\(name)")
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                if let iconURL = community?.iconURL {
                    OctonautAsyncImage(url: iconURL)
                } else {
                    Circle()
                        .fill(Color.orange.gradient)
                        .overlay {
                            Text(String(name.prefix(1)).uppercased())
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text("r/\(name)")
                    .font(.headline)
                Text("Community")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        if let community {
            HStack(spacing: 10) {
                Button {
                    store.toggleSubscribe(communityID: community.id)
                } label: {
                    Text(community.isSubscribed ? "Joined" : "Join")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                Button {
                    store.toggleFavorite(communityID: community.id)
                } label: {
                    Image(systemName: community.isFavorite ? "star.fill" : "star")
                        .frame(width: 24)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(community.isFavorite ? "Remove favorite" : "Add favorite")
            }
        }
    }

    private var redditURL: URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.reddit.com"
        components.path = "/r/\(name)"
        return components.url
    }
}

@MainActor
private struct AdaptiveSettingsTabView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        @Bindable var router = router

        if horizontalSizeClass == .regular {
            SettingsSplitView(store: store, router: router)
        } else {
            NavigationStack(path: $router.path) {
                SettingsRootView(store: store, router: router)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        OctonautDestinationView(route: route, store: store, router: router)
                    }
            }
        }
    }
}

@MainActor
private struct SettingsSplitView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @State private var selection: SettingsDestination? = .general

    var body: some View {
        @Bindable var router = router

        NavigationSplitView {
            List(SettingsDestination.allCases, selection: $selection) { destination in
                Label(destination.title, systemImage: destination.systemImage)
                    .tag(destination)
            }
            .navigationTitle("Settings")
            .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 380)
        } detail: {
            NavigationStack(path: $router.path) {
                if let selection {
                    SettingsDetailView(destination: selection, store: store, router: router)
                        .navigationDestination(for: FeatureRoute.self) { route in
                            OctonautDestinationView(route: route, store: store, router: router)
                        }
                } else {
                    ContentUnavailableView("Choose a setting", systemImage: "gearshape")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

private extension SettingsDestination {
    var systemImage: String {
        switch self {
        case .general: "slider.horizontal.3"
        case .theme: "paintpalette"
        case .appearance: "rectangle.3.group"
        case .intelligence: "sparkles"
        case .account: "person.crop.circle"
        case .dataUse: "antenna.radiowaves.left.and.right"
        case .statistics: "chart.bar"
        case .advanced: "wrench.and.screwdriver"
        case .about: "info.circle"
        }
    }
}

@MainActor
struct OctonautDestinationView: View {
    let route: FeatureRoute
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter

    var body: some View {
        switch route {
        case .feed(let descriptor):
            FeedView(descriptor: descriptor, store: store, router: router)
        case .post(let post):
            PostDetailView(post: post, store: store, router: router)
        case .postURL(let url):
            PostDetailView(post: PostCardModel(deepLinkURL: url), store: store, router: router)
        case .community(let name):
            CommunityView(name: name, store: store, router: router)
        case .search:
            SearchRootView(store: store, router: router)
        case .conversation(let id):
            ConversationView(itemID: id, store: store, router: router)
        case .account(let username):
            UserProfileView(username: username, store: store, router: router)
        case .settings(let destination):
            SettingsDetailView(destination: destination, store: store, router: router)
        case .composer(let kind):
            ComposerView(kind: kind, store: store)
        case .gallery(let descriptor):
            GalleryView(descriptor: descriptor, store: store, router: router)
        case .mediaURL(let url):
            MediaURLView(url: url)
        case .web(let url):
            ExternalURLView(url: url)
        }
    }
}

#Preview {
    OctonautTabsView(store: OctonautFeatureStore())
        .environment(AppDependencies.preview())
}

#Preview("iPad Posts", traits: .landscapeLeft) {
    OctonautTabsView(store: OctonautFeatureStore())
        .environment(AppDependencies.preview())
        .environment(\.horizontalSizeClass, .regular)
}
