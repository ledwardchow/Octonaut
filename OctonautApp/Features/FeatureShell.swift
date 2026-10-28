import SwiftUI
import UIKit
import Observation

private struct OctonautRootWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct OctonautRootHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct OctonautRootRegularKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var octonautRootWidth: CGFloat {
        get { self[OctonautRootWidthKey.self] }
        set { self[OctonautRootWidthKey.self] = newValue }
    }
    var octonautRootHeight: CGFloat {
        get { self[OctonautRootHeightKey.self] }
        set { self[OctonautRootHeightKey.self] = newValue }
    }
    var octonautRootIsRegular: Bool {
        get { self[OctonautRootRegularKey.self] }
        set { self[OctonautRootRegularKey.self] = newValue }
    }
}

@MainActor
struct DuoLayout {
    enum Mode: Equatable { case browsing, reading, otherDetail }
    static let minimumWidth: CGFloat = 620
    static let dividerWidth: CGFloat = 1
    static let dividerHitWidth: CGFloat = 44
    static let dividerSwipeExclusion = dividerHitWidth / 2 + 4
    static let columnHeaderHeight: CGFloat = 60

    static func isEligible(isRegular: Bool, rootWidth: CGFloat, rootHeight: CGFloat) -> Bool {
        isRegular && rootWidth.isFinite && rootHeight.isFinite
            && rootWidth >= minimumWidth && rootHeight >= 600
    }

    static func feedWidth(availableWidth: CGFloat, fraction: Double) -> CGFloat {
        guard availableWidth.isFinite else { return 280 }
        let space = max(0, availableWidth - dividerWidth)
        let minimumFeed: CGFloat = availableWidth < 700 ? 280 : 320
        let minimumDetail: CGFloat = availableWidth < 700 ? 320 : 360
        let upper = max(minimumFeed, space - minimumDetail)
        return min(upper, max(minimumFeed, space * SettingsStore.safeDuoFeedFraction(fraction)))
    }

    static func communityWidth(availableWidth: CGFloat, storedWidth: Double) -> CGFloat {
        let minimumFeed: CGFloat = availableWidth < 700 ? 280 : 320
        return min(CGFloat(SettingsStore.safeDuoCommunityWidth(storedWidth)),
                   max(220, availableWidth - dividerWidth - minimumFeed))
    }

    static func shouldClosePost(translation: CGSize, startX: CGFloat, feedWidth: CGFloat) -> Bool {
        startX < feedWidth - dividerSwipeExclusion && translation.width > 80
            && translation.width > abs(translation.height) * 1.5
    }

    static func mode(for path: [FeatureRoute]) -> Mode {
        guard let route = path.last else { return .browsing }
        switch route {
        case .post, .postURL: return .reading
        default: return .otherDetail
        }
    }

    static func savedFraction(availableWidth: CGFloat, desiredFeedWidth: CGFloat) -> Double {
        guard availableWidth.isFinite, availableWidth > dividerWidth else {
            return SettingsStore.defaultDuoFeedFraction
        }
        let clamped = feedWidth(availableWidth: availableWidth,
                                fraction: Double(desiredFeedWidth / (availableWidth - dividerWidth)))
        return Double(clamped / (availableWidth - dividerWidth))
    }
}

@MainActor
@Observable
final class OctonautFeatureRouter {
    var accounts: AccountCoordinator?
    private var routes: [FeatureRoute]
    private var sheet: FeatureSheet?

    var path: [FeatureRoute] {
        get { routes }
        set {
            let sharedCount = zip(routes, newValue).prefix { $0 == $1 }.count
            if newValue.dropFirst(sharedCount).contains(where: \.requiresLogin),
               let accounts, !accounts.requireLogin() { return }
            routes = newValue
        }
    }

    var presentedSheet: FeatureSheet? {
        get { sheet }
        set {
            if case .composer = newValue, let accounts, !accounts.requireLogin() { return }
            sheet = newValue
        }
    }

    init(path: [FeatureRoute] = []) {
        self.routes = path
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

    func consumeSelectionRoutes(in router: OctonautFeatureRouter) {
        while let route = router.path.last, select(route) {
            router.path.removeLast()
        }
        if case .feed(let descriptor)? = router.path.first {
            selectFeed(descriptor)
            router.path.removeFirst()
        }
        updateContext(for: router.path.last)
    }

    func restoreCompactFeedOrigin(in router: OctonautFeatureRouter) {
        guard !router.path.contains(where: { if case .feed = $0 { return true }; return false }) else { return }
        router.path.insert(.feed(selectedFeed), at: 0)
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
    @Environment(\.colorScheme) private var colorScheme
    @State private var rootSize: CGSize = .zero
    @State private var selectedTab: AppTab
    @State private var postsRouter: OctonautFeatureRouter
    @State private var inboxRouter = OctonautFeatureRouter()
    @State private var accountRouter = OctonautFeatureRouter()
    @State private var searchRouter = OctonautFeatureRouter()
    @State private var settingsRouter: OctonautFeatureRouter
    @State private var postsSplitState = PostsSplitState()
    @State private var store: OctonautFeatureStore

    init(store: OctonautFeatureStore = .preview, reddit: (any RedditClient)? = nil) {
        _store = State(initialValue: store)
        self.reddit = reddit
#if DEBUG
        let screenshot = ProcessInfo.processInfo.environment["OCTONAUT_SCREENSHOT"]
        _selectedTab = State(initialValue: ["settings", "theme", "blocked-users"].contains(screenshot) ? .settings : .posts)
        let path: [FeatureRoute]
        switch screenshot {
        case "feeds": path = []
        case "detail": path = [.feed(.home), .post(.screenshotCoast)]
        default: path = [.feed(.home)]
        }
        _postsRouter = State(initialValue: OctonautFeatureRouter(path: path))
        _settingsRouter = State(initialValue: OctonautFeatureRouter(path: screenshot == "theme" ? [.settings(.theme)] : (screenshot == "blocked-users" ? [.settings(.blockedUsers)] : [])))
#else
        _selectedTab = State(initialValue: .posts)
        _postsRouter = State(initialValue: OctonautFeatureRouter(path: [.feed(.home)]))
        _settingsRouter = State(initialValue: OctonautFeatureRouter())
#endif
    }

    var body: some View {
        chrome
        .loginRequiredModal(isPresented: Binding(
            get: { dependencies.accounts.showingLoginRequired },
            set: { dependencies.accounts.showingLoginRequired = $0 }
        ))
        .onAppear {
            for router in [postsRouter, inboxRouter, accountRouter, searchRouter, settingsRouter] {
                router.accounts = dependencies.accounts
            }
        }
        .task(id: accountStateKey) {
            store.synchronizeAccount(
                id: dependencies.accounts.selectedAccountID,
                generation: dependencies.accounts.selectionGeneration,
                accounts: dependencies.accounts.accounts
            )
            await store.refreshUnreadCount()
        }
        .onChange(of: dependencies.accounts.selectionGeneration) { _, _ in
            postsSplitState.clearDetail()
            store.userProfilePosts.removeAll()
        }
        .onOpenURL { url in
            handleIncomingURL(url)
        }
        .onChange(of: dependencies.settings.customFeeds) { _, feeds in
            syncCustomFeeds(feeds)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await dependencies.persistence.beginUsageSession() }
            Task { await store.refreshUnreadCount() }
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

    private var chrome: some View {
        tabRoot
            .tabBarMinimizeBehavior(.onScrollDown)
            .tint(appliedTheme.accent)
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { rootSize = geometry.size }
                        .onChange(of: geometry.size) { _, size in rootSize = size }
                }
                .ignoresSafeArea(.keyboard)
            }
            .environment(\.octonautRootWidth, rootSize.width)
            .environment(\.octonautRootHeight, rootSize.height)
            .environment(\.octonautRootIsRegular, OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: horizontalSizeClass))
            .octonautTheme(appliedTheme)
            .preferredColorScheme(OctonautTheme.preferredScheme(dependencies.settings.theme))
            .background(appliedTheme.background)
    }

    @ViewBuilder
    private var tabRoot: some View {
        if usesSidebarTabBar {
            compactTabs.tabViewStyle(.sidebarAdaptable)
        } else {
            compactTabs
        }
    }

    /// The signed-in username doubles as the Account tab's label, so it is
    /// suppressed when the user has turned that off.
    private func accountTabTitle(whenSignedOut fallback: String) -> String {
        guard dependencies.settings.showUsernameInAccountTab,
              let username = dependencies.accounts.selectedAccount?.username else { return fallback }
        return username
    }

    private var accountStateKey: String {
        let accountKey = dependencies.accounts.accounts.map {
            "\($0.id.description):\($0.health.rawValue)"
        }.joined(separator: ",")
        return "\(dependencies.accounts.selectedAccountID?.description ?? "anonymous"):\(dependencies.accounts.selectionGeneration):\(accountKey)"
    }

    private func handleIncomingURL(_ url: URL) {
        guard let route = OctonautFeatureURLRouter.route(url) else { return }
        if route.requiresLogin, !dependencies.accounts.requireLogin() { return }
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

    private func syncCustomFeeds(_ feeds: [CustomFeed]) {
        if let id = postsSplitState.selectedFeed.customFeedID {
            let updated = feeds.first { $0.id == id }?.descriptor ?? .home
            if updated != postsSplitState.selectedFeed {
                store.clearVisibleFeed()
                postsRouter.popToRoot()
                postsSplitState.selectFeed(updated)
            }
        }
        for (index, route) in postsRouter.path.enumerated() {
            guard case .feed(let descriptor) = route, let id = descriptor.customFeedID else { continue }
            guard let updated = feeds.first(where: { $0.id == id })?.descriptor else {
                store.clearVisibleFeed(isLoading: false)
                postsRouter.path = Array(postsRouter.path.prefix(index))
                break
            }
            if updated != descriptor {
                store.clearVisibleFeed()
                postsRouter.path = Array(postsRouter.path.prefix(index)) + [.feed(updated)]
                break
            }
        }
    }

    private var shouldUsePostsSplitView: Bool {
        OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: horizontalSizeClass)
            && dependencies.settings.useSplitViewOnIPad
    }

    private var appliedTheme: OctonautTheme {
        OctonautTheme.resolved(
            dependencies.settings.theme,
            colorScheme: colorScheme,
            pureBlack: dependencies.settings.pureBlackBackground
        )
    }

    private var usesSidebarTabBar: Bool {
        OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: horizontalSizeClass)
            && !dependencies.settings.showBottomNavigationOnLargeScreens
    }

    private var tabSelection: Binding<AppTab> {
        Binding(get: { selectedTab }, set: { tab in
            selectedTab = tab
        })
    }

    private var compactTabs: some View {
        TabView(selection: tabSelection) {
            Tab("Posts", systemImage: "rectangle.stack", value: AppTab.posts) {
                tabContent(for: .posts)
            }
            Tab("Inbox", systemImage: "envelope", value: AppTab.inbox) {
                tabContent(for: .inbox)
            }
                .badge(store.unreadCount)
            Tab(accountTabTitle(whenSignedOut: "Accounts"), systemImage: "person.crop.circle", value: AppTab.account) {
                tabContent(for: .account)
            }
            Tab(value: AppTab.search, role: .search) {
                tabContent(for: .search)
            } label: {
                Label("Search", systemImage: "magnifyingglass")
            }
            Tab("Settings", systemImage: "gearshape", value: AppTab.settings) {
                tabContent(for: .settings)
            }
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
private struct AdaptivePostsTabView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    let splitState: PostsSplitState
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.octonautRootWidth) private var rootWidth
    @Environment(\.octonautRootHeight) private var rootHeight
    @Environment(\.octonautRootIsRegular) private var rootIsRegular

    private var usesDuoLayout: Bool {
        dependencies.settings.useSplitViewOnIPad
            && dependencies.settings.feedOnLeftWhenViewingPosts
            && DuoLayout.isEligible(
                isRegular: rootIsRegular,
                rootWidth: rootWidth, rootHeight: rootHeight
            )
    }

    @State private var splitWasShown = false

    var body: some View {
        @Bindable var router = router

        if usesDuoLayout {
            DuoPostsView(store: store, router: router, state: splitState)
                .onAppear { splitWasShown = true; consumeSelectionRoutes() }
                .onChange(of: router.path) { _, _ in consumeSelectionRoutes() }
        } else if OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: horizontalSizeClass)
            && dependencies.settings.useSplitViewOnIPad {
            PostsSplitView(store: store, router: router, state: splitState)
                .onAppear { splitWasShown = true; consumeSelectionRoutes() }
                .onChange(of: router.path) { _, _ in consumeSelectionRoutes() }
        } else {
            NavigationStack(path: $router.path) {
                PostsRootView(store: store, router: router)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        OctonautDestinationView(route: route, store: store, router: router)
                    }
            }
            .onAppear(perform: restoreCompactFeedOrigin)
        }
    }

    private func consumeSelectionRoutes() {
        splitState.consumeSelectionRoutes(in: router)
    }

    private func restoreCompactFeedOrigin() {
        guard splitWasShown else { return }
        splitWasShown = false
        splitState.restoreCompactFeedOrigin(in: router)
    }
}

@MainActor
private struct DuoPostsView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    let state: PostsSplitState
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var resizeGestureActive = false
    @State private var resizeStartWidth: CGFloat?
    @State private var proposedColumnWidth: CGFloat?

    var body: some View {
        @Bindable var router = router
        let mode = DuoLayout.mode(for: router.path)

        GeometryReader { geometry in
            let width = geometry.size.width
            let hasDetail = mode != .browsing
            let divider: CGFloat = hasDetail ? DuoLayout.dividerWidth : 1
            let storedWidth = DuoLayout.feedWidth(
                availableWidth: width,
                fraction: dependencies.settings.duoFeedFraction
            )
            let minimumFeed: CGFloat = width < 700 ? 280 : 320
            let communityWidth = DuoLayout.communityWidth(availableWidth: width, storedWidth:
                !hasDetail ? Double(proposedColumnWidth ?? CGFloat(dependencies.settings.duoCommunityWidth)) : dependencies.settings.duoCommunityWidth)
            let feedWidth = hasDetail
                ? DuoLayout.feedWidth(availableWidth: width, fraction: Double((proposedColumnWidth ?? storedWidth) / (width - divider)))
                : max(minimumFeed, width - communityWidth - divider)

            if width < DuoLayout.minimumWidth {
                PostsSplitView(store: store, router: router, state: state)
            } else {
                HStack(spacing: 0) {
                    NavigationStack {
                        PostsRootView(
                            store: store,
                            router: router,
                            onSelectFeed: selectFeed,
                            selectedFeed: state.selectedFeed,
                            usesDuoSidebar: true
                        )
                        .ignoresSafeArea(.container, edges: .horizontal)
                    }
                    .frame(width: hasDetail ? 0 : communityWidth)
                    .clipped()
                    .accessibilityHidden(hasDetail)

                    if !hasDetail {
                        dividerHandle(width: width, displayedWidth: communityWidth, isReading: false)
                    }

                    NavigationStack {
                        selectedFeedView
                            .ignoresSafeArea(.container, edges: hasDetail ? .horizontal : [])
                    }
                    .frame(width: feedWidth)
                    .gesture(DuoFeedCloseGesture(isEnabled: mode == .reading && resizeStartWidth == nil,
                                                 feedWidth: feedWidth) { router.popToRoot() })

                    if hasDetail {
                        dividerHandle(width: width, displayedWidth: feedWidth, isReading: true)
                    }

                    NavigationStack(path: $router.path) {
                        Color.clear
                            .navigationDestination(for: FeatureRoute.self) { route in
                                OctonautDestinationView(route: route, store: store, router: router)
                                    .environment(\.octonautDuoPostDetail, true)
                            }
                    }
                    .frame(width: hasDetail ? max(0, width - feedWidth - divider) : 0)
                    .clipped()
                    .accessibilityHidden(!hasDetail)
                }
                .frame(width: width, alignment: .leading)
                .coordinateSpace(name: "duo-columns")
                .onChange(of: resizeGestureActive) { _, active in
                    if !active {
                        Task { @MainActor in
                            await Task.yield()
                            if !resizeGestureActive {
                                resizeStartWidth = nil
                                proposedColumnWidth = nil
                            }
                        }
                    }
                }
                .onChange(of: mode) { _, _ in
                    resizeStartWidth = nil
                    proposedColumnWidth = nil
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: mode)
            }
        }
        .ignoresSafeArea(.container, edges: .bottom)
    }

    @ViewBuilder
    private var selectedFeedView: some View {
        if state.selectedFeed.kind == .community {
            CommunityView(
                name: state.selectedFeed.name,
                store: store,
                router: router,
                onSelectPost: selectPost,
                onShowCommunities: DuoLayout.mode(for: router.path) == .browsing ? nil : { router.popToRoot() }
            )
        } else {
            FeedView(
                descriptor: state.selectedFeed,
                store: store,
                router: router,
                onSelectPost: selectPost,
                onShowCommunities: DuoLayout.mode(for: router.path) == .browsing ? nil : { router.popToRoot() }
            )
        }
    }

    private func dividerHandle(width: CGFloat, displayedWidth: CGFloat, isReading: Bool) -> some View {
        Rectangle()
            .fill(Color(uiColor: .separator))
            .frame(width: DuoLayout.dividerWidth)
            .overlay {
                Rectangle()
                    .fill(.clear)
                    .frame(width: DuoLayout.dividerHitWidth)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 2, coordinateSpace: .named("duo-columns"))
                            .updating($resizeGestureActive) { _, active, _ in active = true }
                            .onChanged { value in
                                if resizeStartWidth == nil { resizeStartWidth = displayedWidth }
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    proposedColumnWidth = (resizeStartWidth ?? displayedWidth) + value.translation.width
                                }
                            }
                            .onEnded { value in
                                var transaction = Transaction()
                                transaction.disablesAnimations = true
                                withTransaction(transaction) {
                                    saveColumnWidth((resizeStartWidth ?? displayedWidth) + value.translation.width,
                                                    availableWidth: width, isReading: isReading)
                                    proposedColumnWidth = nil
                                    resizeStartWidth = nil
                                }
                            }
                    )
                    .accessibilityElement()
                    .accessibilityLabel(isReading ? "Feed column width" : "Community column width")
                    .accessibilityValue("\(Int(displayedWidth.rounded())) points")
                    .accessibilityAdjustableAction { direction in
                        saveColumnWidth(displayedWidth + (direction == .increment ? 20 : -20),
                                        availableWidth: width, isReading: isReading)
                    }
            }
            .zIndex(1)
    }

    private func saveColumnWidth(_ desiredWidth: CGFloat, availableWidth: CGFloat, isReading: Bool) {
        if isReading {
            dependencies.settings.duoFeedFraction = DuoLayout.savedFraction(
                availableWidth: availableWidth, desiredFeedWidth: desiredWidth)
        } else {
            dependencies.settings.duoCommunityWidth = Double(DuoLayout.communityWidth(
                availableWidth: availableWidth, storedWidth: Double(desiredWidth)))
        }
    }

    private func selectFeed(_ descriptor: FeedDescriptorModel) {
        if state.selectedFeed != descriptor { store.clearVisibleFeed() }
        else { store.clearPostDetail() }
        router.popToRoot()
        state.selectFeed(descriptor)
    }

    private func selectPost(_ post: PostCardModel) {
        state.selectPost(post)
        router.path = [.post(post)]
    }
}

private struct DuoFeedCloseGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var feedWidth: CGFloat
    var closePost: () -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(converter: converter, feedWidth: feedWidth)
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delaysTouchesBegan = true
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.feedWidth = feedWidth
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        if recognizer.state == .cancelled || recognizer.state == .failed {
            context.coordinator.startLocation = nil
            return
        }
        guard recognizer.state == .ended, let start = context.coordinator.startLocation else { return }
        defer { context.coordinator.startLocation = nil }
        // Translation can reset when the recognizer begins, so retain the touch origin.
        let end = context.converter.localLocation
        if DuoLayout.shouldClosePost(translation: CGSize(width: end.x - start.x, height: end.y - start.y),
                                     startX: start.x, feedWidth: feedWidth) {
            closePost()
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let converter: CoordinateSpaceConverter
        var feedWidth: CGFloat
        var startLocation: CGPoint?

        init(converter: CoordinateSpaceConverter, feedWidth: CGFloat) {
            self.converter = converter
            self.feedWidth = feedWidth
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let velocity = converter.localVelocity, let translation = converter.localTranslation else { return false }
            let start = CGPoint(x: converter.localLocation.x - translation.x,
                                y: converter.localLocation.y - translation.y)
            let accepted = start.x < feedWidth - DuoLayout.dividerSwipeExclusion && velocity.x > 0 && velocity.x > abs(velocity.y) * 1.5
            startLocation = accepted ? start : nil
            return accepted
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}

@MainActor
private struct PostsSplitView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    let state: PostsSplitState

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 1100 {
                threeColumnLayout
            } else {
                twoColumnLayout
            }
        }
    }

    private var twoColumnLayout: some View {
        @Bindable var router = router

        return NavigationSplitView {
            PostsRootView(
                store: store,
                router: router,
                onSelectFeed: selectFeed,
                selectedFeed: state.selectedFeed
            )
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            NavigationStack(path: $router.path) {
                selectedFeedView
                    .navigationDestination(for: FeatureRoute.self) { route in
                        OctonautDestinationView(route: route, store: store, router: router)
                    }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    private var threeColumnLayout: some View {
        @Bindable var router = router

        return NavigationSplitView {
            PostsRootView(
                store: store,
                router: router,
                onSelectFeed: selectFeed,
                selectedFeed: state.selectedFeed
            )
            .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } content: {
            NavigationStack {
                selectedFeedView
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 440, max: 560)
        } detail: {
            NavigationStack(path: $router.path) {
                Group {
                    if store.feedState == .loading {
                        ProgressView("Loading feed…")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ContentUnavailableView(
                            "Select a post",
                            systemImage: "text.bubble",
                            description: Text("Choose a post to read it and its comments here.")
                        )
                    }
                }
                .navigationDestination(for: FeatureRoute.self) { route in
                    OctonautDestinationView(route: route, store: store, router: router)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
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
        if state.selectedFeed != descriptor { store.clearVisibleFeed() }
        else { store.clearPostDetail() }
        router.popToRoot()
        state.selectFeed(descriptor)
    }

    private func selectPost(_ post: PostCardModel) {
        state.selectPost(post)
        router.path = [.post(post)]
    }
}

@MainActor
private struct SubredditSidebarView: View {
    @Environment(AppDependencies.self) private var dependencies
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
                        router.presentedSheet = .composer(.post, community: name)
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
                        .fill(Color.accentColor)
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
                    if dependencies.accounts.requireLogin() { store.toggleSubscribe(communityID: community.id) }
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

        if OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: horizontalSizeClass) {
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
        case .blockedUsers: "person.crop.circle.badge.xmark"
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
    @Environment(AppDependencies.self) private var dependencies

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
        case .search(let query):
            SearchRootView(store: store, router: router, reddit: dependencies.reddit, initialQuery: query)
        case .conversation(let id):
            ConversationView(itemID: id, store: store, router: router)
        case .account(let username):
            UserProfileView(username: username, store: store, router: router)
        case .userSection(let username, let section):
            UserSectionView(router: router, username: username, section: section, store: store)
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

/// Votes and saves for rows a screen keeps itself, such as search results and
/// profile lists. The row changes straight away and is put back when Reddit
/// rejects the change, unless a later tap has already replaced it.
@MainActor
struct DetachedPostActions {
    let store: OctonautFeatureStore
    let accounts: AccountCoordinator

    func vote(postID: String, value: Int, in posts: Binding<[PostCardModel]>) {
        guard accounts.requireLogin(), let accountID = accounts.selectedAccountID,
              let index = posts.wrappedValue.firstIndex(where: { $0.id == postID }) else { return }
        let previous = posts.wrappedValue[index].vote
        guard previous != value else { return }
        guard store.beginDetachedPostAction(.vote, postID: postID, accountID: accountID) else { return }
        posts.wrappedValue[index].vote = value
        posts.wrappedValue[index].score += value - previous
        let token = accounts.token(for: accountID)
        Task {
            defer { store.endDetachedPostAction(.vote, postID: postID, accountID: accountID) }
            do {
                try await store.setVote(value, previous: previous, postID: postID, accountID: accountID)
            } catch {
                guard accounts.isCurrent(token) else { return }
                if let index = posts.wrappedValue.firstIndex(where: { $0.id == postID }),
                   posts.wrappedValue[index].vote == value {
                    posts.wrappedValue[index].vote = previous
                    posts.wrappedValue[index].score -= value - previous
                }
                await markNeedsLoginIfExpired(error, accountID: accountID)
            }
        }
    }

    func toggleSave(postID: String, in posts: Binding<[PostCardModel]>) {
        guard accounts.requireLogin(), let accountID = accounts.selectedAccountID,
              let index = posts.wrappedValue.firstIndex(where: { $0.id == postID }) else { return }
        guard store.beginDetachedPostAction(.save, postID: postID, accountID: accountID) else { return }
        let saved = !posts.wrappedValue[index].isSaved
        posts.wrappedValue[index].isSaved = saved
        let token = accounts.token(for: accountID)
        Task {
            defer { store.endDetachedPostAction(.save, postID: postID, accountID: accountID) }
            do {
                try await store.setSaved(saved, postID: postID, accountID: accountID)
            } catch {
                guard accounts.isCurrent(token) else { return }
                if let index = posts.wrappedValue.firstIndex(where: { $0.id == postID }),
                   posts.wrappedValue[index].isSaved == saved {
                    posts.wrappedValue[index].isSaved = !saved
                }
                await markNeedsLoginIfExpired(error, accountID: accountID)
            }
        }
    }

    private func markNeedsLoginIfExpired(_ error: any Error, accountID: AccountID) async {
        guard let clientError = error as? RedditClientError, clientError == .authenticationRequired else { return }
        await accounts.markNeedsLogin(accountID)
    }
}
