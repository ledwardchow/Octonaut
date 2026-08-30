import AppKit
import SwiftUI

@MainActor
struct MacRootView: View {
    let dependencies: AppDependencies

    @State private var store: OctonautFeatureStore
    @State private var search: SearchFeatureModel
    @State private var sidebarSelection: MacSidebarSelection? = .feed(.home)
    @State private var selectedPost: PostCardModel?
    @AppStorage("layout.mainSidebarWidth") private var sidebarWidth = 220.0
    @AppStorage("layout.mainContentWidth") private var contentWidth = 520.0

    init(dependencies: AppDependencies) {
        self.dependencies = dependencies
        _store = State(
            initialValue: OctonautFeatureStore(
                reddit: dependencies.reddit,
                authenticated: dependencies.authenticated,
                intelligence: dependencies.intelligence,
                settings: dependencies.settings,
                persistence: dependencies.persistence
            )
        )
        _search = State(initialValue: SearchFeatureModel(reddit: dependencies.reddit))
    }

    var body: some View {
        NavigationSplitView {
            MacSidebarView(
                selection: $sidebarSelection,
                communities: store.communities,
                accountName: dependencies.accounts.selectedAccount?.username
            )
            .navigationSplitViewColumnWidth(
                min: 190,
                ideal: CGFloat(sidebarWidth),
                max: 280
            )
        } content: {
            contentColumn
                .navigationSplitViewColumnWidth(
                    min: 320,
                    ideal: CGFloat(contentWidth),
                    max: .infinity
                )
        } detail: {
            MacPostDetailView(
                post: selectedPost,
                store: store,
                accounts: dependencies.accounts
            )
        }
        .tint(.orange)
        .background {
            MacWindowTitleAccessory(title: "Octonaut")
            MacSplitViewPersistenceView(
                sidebarWidth: $sidebarWidth,
                contentWidth: $contentWidth
            )
        }
        .task {
            await dependencies.accounts.load()
            synchronizeAccount()
            await store.refreshCommunities()
            await refreshSelection(force: false)
        }
        .onChange(of: dependencies.accounts.selectionGeneration) { _, _ in
            synchronizeAccount()
            selectedPost = nil
            Task {
                await store.refreshCommunities()
                await refreshSelection(force: true)
            }
        }
        .onChange(of: sidebarSelection) { _, _ in
            selectedPost = nil
            Task { await refreshSelection(force: false) }
        }
        .onChange(of: selectedPost) { _, post in
            guard let post else { return }
            Task {
                await store.loadPostDetail(for: post)
                await store.recordPostViewed()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .octonautMacRefresh)) { _ in
            Task { await refreshSelection(force: true) }
        }
        .onReceive(NotificationCenter.default.publisher(for: .octonautMacShowSearch)) { _ in
            sidebarSelection = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .octonautMacSelectFeed)) { notification in
            guard let descriptor = notification.object as? FeedDescriptorModel else { return }
            sidebarSelection = .feed(descriptor)
        }
        .onOpenURL { url in
            handle(url)
        }
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch sidebarSelection {
        case .feed(let descriptor):
            MacFeedListView(
                descriptor: descriptor,
                store: store,
                selectedPost: $selectedPost
            )
        case .search:
            MacSearchView(model: search, selectedPost: $selectedPost) { community in
                sidebarSelection = .feed(
                    FeedDescriptorModel(kind: .community, name: community)
                )
            }
        case .inbox:
            MacInboxView(
                service: dependencies.authenticated,
                accounts: dependencies.accounts
            )
        case .accounts:
            MacAccountsView(accounts: dependencies.accounts)
        case nil:
            ContentUnavailableView(
                "Choose a section",
                systemImage: "sidebar.left",
                description: Text("Select a feed or tool from the sidebar.")
            )
        }
    }

    private func synchronizeAccount() {
        store.synchronizeAccount(
            id: dependencies.accounts.selectedAccountID,
            generation: dependencies.accounts.selectionGeneration,
            accounts: dependencies.accounts.accounts
        )
    }

    private func refreshSelection(force: Bool) async {
        switch sidebarSelection {
        case .feed(let descriptor):
            await store.refreshPosts(for: descriptor, forceRefresh: force)
        case .inbox:
            await store.refreshInbox()
        case .search, .accounts, nil:
            break
        }
    }

    private func handle(_ url: URL) {
        guard let route = OctonautFeatureURLRouter.route(url) else { return }
        switch route {
        case .feed(let descriptor):
            sidebarSelection = .feed(descriptor)
        case .community(let name):
            sidebarSelection = .feed(FeedDescriptorModel(kind: .community, name: name))
        case .post(let post):
            selectedPost = post
        case .postURL(let url):
            selectedPost = PostCardModel(deepLinkURL: url)
        case .search(let query):
            sidebarSelection = .search
            Task { await search.submit(query: query, scope: .posts) }
        case .mediaURL(let url), .web(let url):
            NSWorkspace.shared.open(url)
        case .account:
            sidebarSelection = .accounts
        case .settings, .conversation, .composer, .gallery:
            break
        }
    }
}

private struct MacSplitViewPersistenceView: NSViewRepresentable {
    @Binding var sidebarWidth: Double
    @Binding var contentWidth: Double

    func makeCoordinator() -> Coordinator {
        Coordinator(sidebarWidth: $sidebarWidth, contentWidth: $contentWidth)
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChange = { window in
            context.coordinator.install(in: window)
        }
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        context.coordinator.update(
            sidebarWidth: sidebarWidth,
            contentWidth: contentWidth
        )
        view.onWindowChange = { window in
            context.coordinator.install(in: window)
        }
        context.coordinator.install(in: view.window)
    }

    static func dismantleNSView(_ view: WindowReaderView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.remove()
    }

    @MainActor
    final class Coordinator: NSObject {
        @Binding private var sidebarWidth: Double
        @Binding private var contentWidth: Double
        private weak var window: NSWindow?
        private weak var splitView: NSSplitView?
        private var isApplyingSavedWidths = false
        private var restoreGeneration = 0

        init(sidebarWidth: Binding<Double>, contentWidth: Binding<Double>) {
            _sidebarWidth = sidebarWidth
            _contentWidth = contentWidth
        }

        func update(sidebarWidth: Double, contentWidth: Double) {
            self.sidebarWidth = sidebarWidth
            self.contentWidth = contentWidth
        }

        func install(in window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                remove()
                self.window = window
            }

            resolveSplitView(in: window)
        }

        func remove() {
            NotificationCenter.default.removeObserver(self)
            restoreGeneration += 1
            splitView = nil
            window = nil
        }

        @objc private func splitViewDidResize(_ notification: Notification) {
            guard !isApplyingSavedWidths,
                  let splitView = notification.object as? NSSplitView,
                  splitView === self.splitView,
                  splitView.subviews.count >= 3,
                  NSEvent.pressedMouseButtons & 1 != 0,
                  !splitView.inLiveResize else {
                return
            }

            let newSidebarWidth = splitView.subviews[0].frame.width
            let newContentWidth = splitView.subviews[1].frame.width
            guard newSidebarWidth >= 190,
                  newSidebarWidth <= 280,
                  newContentWidth >= 320 else {
                return
            }

            sidebarWidth = Double(newSidebarWidth)
            contentWidth = Double(newContentWidth)
            UserDefaults.standard.synchronize()
        }

        private func resolveSplitView(in window: NSWindow) {
            guard let contentView = window.contentView else { return }
            let candidate = allSplitViews(in: contentView)
                .filter { $0.isVertical && $0.subviews.count >= 3 }
                .max { $0.bounds.width < $1.bounds.width }

            guard let candidate else {
                DispatchQueue.main.async { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.resolveSplitView(in: window)
                }
                return
            }
            guard splitView !== candidate else { return }

            NotificationCenter.default.removeObserver(self)
            splitView = candidate
            candidate.autosaveName = nil
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(splitViewDidResize(_:)),
                name: NSSplitView.didResizeSubviewsNotification,
                object: candidate
            )

            restoreGeneration += 1
            let generation = restoreGeneration
            applySavedWidths(to: candidate)
            DispatchQueue.main.async { [weak self, weak candidate] in
                guard let self, let candidate,
                      self.restoreGeneration == generation else { return }
                self.applySavedWidths(to: candidate)
            }
        }

        private func applySavedWidths(to splitView: NSSplitView) {
            guard splitView.bounds.width > 0, splitView.subviews.count >= 3 else { return }
            isApplyingSavedWidths = true
            splitView.setPosition(CGFloat(sidebarWidth), ofDividerAt: 0)
            splitView.setPosition(
                CGFloat(sidebarWidth + contentWidth) + splitView.dividerThickness,
                ofDividerAt: 1
            )
            isApplyingSavedWidths = false
        }

        private func allSplitViews(in view: NSView) -> [NSSplitView] {
            var result = view is NSSplitView ? [view as! NSSplitView] : []
            for subview in view.subviews {
                result.append(contentsOf: allSplitViews(in: subview))
            }
            return result
        }
    }
}

private struct MacWindowTitleAccessory: NSViewRepresentable {
    let title: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WindowReaderView {
        let view = WindowReaderView()
        view.onWindowChange = { window in
            context.coordinator.install(title: title, in: window)
        }
        return view
    }

    func updateNSView(_ view: WindowReaderView, context: Context) {
        view.onWindowChange = { window in
            context.coordinator.install(title: title, in: window)
        }
        context.coordinator.update(title: title)
    }

    static func dismantleNSView(_ view: WindowReaderView, coordinator: Coordinator) {
        view.onWindowChange = nil
        coordinator.remove()
    }

    @MainActor
    final class Coordinator {
        private weak var window: NSWindow?
        private var accessory: NSTitlebarAccessoryViewController?

        func install(title: String, in window: NSWindow?) {
            guard let window else { return }
            guard self.window !== window else {
                update(title: title)
                return
            }

            remove()

            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .left
            accessory.view = makeTitleView(title)
            window.addTitlebarAccessoryViewController(accessory)

            self.window = window
            self.accessory = accessory
        }

        func update(title: String) {
            guard let accessory else { return }
            accessory.view = makeTitleView(title)
        }

        func remove() {
            guard let window, let accessory else { return }
            if let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            self.window = nil
            self.accessory = nil
        }

        private func makeTitleView(_ title: String) -> NSView {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            label.textColor = .secondaryLabelColor
            label.setContentHuggingPriority(.required, for: .horizontal)

            let container = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 6),
                label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            container.frame.size = NSSize(width: label.intrinsicContentSize.width + 14, height: 28)
            return container
        }
    }
}

@MainActor
private final class WindowReaderView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}

private struct MacSidebarView: View {
    @Binding var selection: MacSidebarSelection?
    let communities: [CommunityCardModel]
    let accountName: String?

    var body: some View {
        List(selection: $selection) {
            Section("Feeds") {
                sidebarRow("Home", systemImage: "house", value: .feed(.home))
                sidebarRow("Popular", systemImage: "flame", value: .feed(.popular))
                sidebarRow("All", systemImage: "globe", value: .feed(.all))
            }

            if !communities.isEmpty {
                Section("Communities") {
                    ForEach(communities) { community in
                        HStack(spacing: 8) {
                            MacCommunityIcon(community: community)
                            Text("r/\(community.name)")
                                .lineLimit(1)
                        }
                        .tag(
                            MacSidebarSelection.feed(
                                FeedDescriptorModel(kind: .community, name: community.name)
                            )
                        )
                    }
                }
            }

            Section("Octonaut") {
                sidebarRow("Search", systemImage: "magnifyingglass", value: .search)
                sidebarRow("Inbox", systemImage: "tray", value: .inbox)
                sidebarRow(accountName.map { "u/\($0)" } ?? "Accounts", systemImage: "person.crop.circle", value: .accounts)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Octonaut")
    }

    private func sidebarRow(
        _ title: String,
        systemImage: String,
        value: MacSidebarSelection
    ) -> some View {
        Label(title, systemImage: systemImage)
            .tag(value)
    }
}

private struct MacCommunityIcon: View {
    let community: CommunityCardModel

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AsyncImage(url: community.iconURL) { phase in
                if case .success(let image) = phase {
                    image
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "person.3.fill")
                        .resizable()
                        .scaledToFit()
                        .padding(4)
                        .foregroundStyle(.secondary)
                        .background(.quaternary)
                }
            }
            .frame(width: 22, height: 22)
            .clipShape(Circle())

            if community.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.yellow)
                    .padding(1.5)
                    .background(.background, in: Circle())
                    .offset(x: 2, y: 2)
            }
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}
