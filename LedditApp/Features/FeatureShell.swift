import SwiftUI
import UIKit
import Observation

@MainActor
@Observable
final class LedditFeatureRouter {
    var path: [FeatureRoute]
    var presentedSheet: FeatureSheet?

    init(path: [FeatureRoute] = []) {
        self.path = path
    }

    func push(_ route: FeatureRoute) { path.append(route) }
    func popToRoot() { path.removeAll() }
    func pop() { if !path.isEmpty { path.removeLast() } }
}

/// The app shell keeps a separate router for each tab. The App target can use
/// this view directly, or use the individual tab roots when it owns its own
/// dependency container.
@MainActor
struct LedditTabsView: View {
    /// The app dependency container supplies the live transport. Keeping this
    /// optional preserves the fixture-backed preview and isolated feature tests.
    let reddit: (any RedditClient)?
    @Environment(AppDependencies.self) private var dependencies
    @State private var selectedTab: AppTab = .posts
    @State private var postsRouter = LedditFeatureRouter(path: [.feed(.home)])
    @State private var inboxRouter = LedditFeatureRouter()
    @State private var accountRouter = LedditFeatureRouter()
    @State private var searchRouter = LedditFeatureRouter()
    @State private var settingsRouter = LedditFeatureRouter()
    @State private var store: LedditFeatureStore

    init(store: LedditFeatureStore = .preview, reddit: (any RedditClient)? = nil) {
        _store = State(initialValue: store)
        self.reddit = reddit
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $postsRouter.path) {
                PostsRootView(store: store, router: postsRouter)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        LedditDestinationView(route: route, store: store, router: postsRouter)
                    }
            }
            .tabItem { Label("Posts", systemImage: "rectangle.stack") }
            .tag(AppTab.posts)

            NavigationStack(path: $inboxRouter.path) {
                InboxRootView(store: store, router: inboxRouter)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        LedditDestinationView(route: route, store: store, router: inboxRouter)
                    }
            }
            .tabItem { Label("Inbox", systemImage: "envelope") }
            .badge(store.unreadCount)
            .tag(AppTab.inbox)

            NavigationStack(path: $accountRouter.path) {
                AccountRootView(store: store, router: accountRouter)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        LedditDestinationView(route: route, store: store, router: accountRouter)
                    }
            }
            .tabItem { Label(dependencies.accounts.selectedAccount?.username ?? "Accounts", systemImage: "person.crop.circle") }
            .tag(AppTab.account)

            NavigationStack(path: $searchRouter.path) {
                SearchRootView(store: store, router: searchRouter, reddit: reddit)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        LedditDestinationView(route: route, store: store, router: searchRouter)
                    }
            }
            .tabItem { Label("Search", systemImage: "magnifyingglass") }
            .tag(AppTab.search)

            NavigationStack(path: $settingsRouter.path) {
                SettingsRootView(store: store, router: settingsRouter)
                    .navigationDestination(for: FeatureRoute.self) { route in
                        LedditDestinationView(route: route, store: store, router: settingsRouter)
                    }
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
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
        .onOpenURL { url in
            handleIncomingURL(url)
        }
    }

    private var accountStateKey: String {
        let accountKey = dependencies.accounts.accounts.map {
            "\($0.id.description):\($0.health.rawValue)"
        }.joined(separator: ",")
        return "\(dependencies.accounts.selectedAccountID?.description ?? "anonymous"):\(dependencies.accounts.selectionGeneration):\(accountKey)"
    }

    private func handleIncomingURL(_ url: URL) {
        guard let route = LedditFeatureURLRouter.route(url) else { return }
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
            postsRouter.push(route)
        }
    }
}

@MainActor
struct LedditDestinationView: View {
    let route: FeatureRoute
    let store: LedditFeatureStore
    let router: LedditFeatureRouter

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
    LedditTabsView(store: LedditFeatureStore())
        .environment(AppDependencies.preview())
}
