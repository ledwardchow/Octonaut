import AppKit
import SwiftUI

@MainActor
struct MacRootView: View {
    let dependencies: AppDependencies

    @State private var store: OctonautFeatureStore
    @State private var search: SearchFeatureModel
    @State private var sidebarSelection: MacSidebarSelection? = .feed(.home)
    @State private var selectedPost: PostCardModel?
    @State private var composer: MacComposerContext?
    @State private var editingFeed: CustomFeed?
    @State private var submissionMessage: String?
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
        Group {
            if sidebarSelection == .accounts {
                accountsSplitView
            } else {
                postsSplitView
            }
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
                await store.refreshCommunities(forceRefresh: true)
                await refreshSelection(force: true)
            }
        }
        .onChange(of: dependencies.settings.customFeeds) { _, feeds in
            guard case .feed(let descriptor) = sidebarSelection,
                  let id = descriptor.customFeedID else { return }
            sidebarSelection = .feed(feeds.first { $0.id == id }?.descriptor ?? .home)
        }
        .onChange(of: sidebarSelection) { _, _ in
            selectedPost = nil
            switch sidebarSelection {
            case .feed: store.clearVisibleFeed()
            default: store.clearVisibleFeed(isLoading: false)
            }
        }
        .task(id: sidebarSelection) {
            await refreshSelection(force: false)
        }
        .task(id: selectedPost?.id) {
            store.clearPostDetail()
            guard let post = selectedPost else { return }
            if await store.loadPostDetail(for: post) {
                await store.recordPostViewed()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .octonautMacRefresh)) { _ in
            Task {
                await store.refreshCommunities(forceRefresh: true)
                await refreshSelection(force: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .octonautMacNewPost)) { _ in
            beginComposing(.post(defaultCommunity: selectedCommunity))
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
        .sheet(item: $editingFeed) { feed in
            MacCustomFeedEditor(feed: feed, communities: store.communities) { saved in
                if let index = dependencies.settings.customFeeds.firstIndex(where: { $0.id == saved.id }) {
                    dependencies.settings.customFeeds[index] = saved
                } else {
                    dependencies.settings.customFeeds.append(saved)
                }
                sidebarSelection = .feed(saved.descriptor)
            }
        }
        .sheet(item: $composer) { context in
            MacComposerView(context: context) { result in
                submissionMessage = result.message
                Task { await refreshAfterSubmission() }
            }
            .environment(dependencies)
        }
        .alert(
            submissionMessage ?? "Submitted",
            isPresented: Binding(
                get: { submissionMessage != nil },
                set: { if !$0 { submissionMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        }
    }

    private var postsSplitView: some View {
        NavigationSplitView {
            sidebar
        } content: {
            contentColumn
                .ignoresSafeArea(.container, edges: .top)
                .navigationSplitViewColumnWidth(
                    min: 320,
                    ideal: CGFloat(contentWidth),
                    max: .infinity
                )
        } detail: {
            MacPostDetailView(
                post: selectedPost,
                store: store,
                accounts: dependencies.accounts,
                onCompose: beginComposing
            )
            .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var accountsSplitView: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            MacAccountsView(accounts: dependencies.accounts)
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var sidebar: some View {
        MacSidebarView(
            selection: $sidebarSelection,
            communities: store.communities,
            communitiesState: store.communitiesState,
            onRefreshCommunities: {
                Task { await store.refreshCommunities(forceRefresh: true) }
            },
            accountName: dependencies.accounts.selectedAccount?.username,
            customFeeds: dependencies.settings.customFeeds,
            onCreate: { editingFeed = CustomFeed(name: "", communities: []) },
            onEdit: { editingFeed = $0 },
            onDelete: { feed in
                dependencies.settings.customFeeds.removeAll { $0.id == feed.id }
                if case .feed(let selected) = sidebarSelection, selected.customFeedID == feed.id {
                    sidebarSelection = .feed(.home)
                }
            }
        )
        .navigationSplitViewColumnWidth(
            min: 190,
            ideal: CGFloat(sidebarWidth),
            max: 280
        )
    }

    @ViewBuilder
    private var contentColumn: some View {
        switch sidebarSelection {
        case .feed(let descriptor):
            MacFeedListView(
                descriptor: descriptor,
                store: store,
                selectedPost: $selectedPost,
                onComposePost: {
                    beginComposing(.post(defaultCommunity: selectedCommunity))
                }
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

    private var selectedCommunity: String {
        guard case .feed(let descriptor) = sidebarSelection,
              descriptor.kind == .community else {
            return ""
        }
        return descriptor.name
    }

    private func beginComposing(_ context: MacComposerContext) {
        guard dependencies.accounts.selectedAccountID != nil else {
            sidebarSelection = .accounts
            return
        }
        composer = context
    }

    private func refreshAfterSubmission() async {
        await refreshSelection(force: true)
        if let selectedPost {
            await store.loadPostDetail(for: selectedPost)
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
        private var splitViewResolutionAttempts = 0
        private var pendingSplitViewResolution: DispatchWorkItem?

        init(sidebarWidth: Binding<Double>, contentWidth: Binding<Double>) {
            _sidebarWidth = sidebarWidth
            _contentWidth = contentWidth
        }

        func install(in window: NSWindow?) {
            guard let window else { return }
            if self.window !== window {
                remove()
                self.window = window
                splitViewResolutionAttempts = 0
            }

            resolveSplitView(in: window)
        }

        func remove() {
            NotificationCenter.default.removeObserver(self)
            pendingSplitViewResolution?.cancel()
            pendingSplitViewResolution = nil
            restoreGeneration += 1
            splitViewResolutionAttempts = 0
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
                guard pendingSplitViewResolution == nil,
                      splitViewResolutionAttempts < 20 else { return }
                splitViewResolutionAttempts += 1
                let workItem = DispatchWorkItem { [weak self, weak window] in
                    guard let self, let window else { return }
                    self.pendingSplitViewResolution = nil
                    self.resolveSplitView(in: window)
                }
                pendingSplitViewResolution = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: workItem)
                return
            }
            guard splitView !== candidate else { return }

            pendingSplitViewResolution?.cancel()
            pendingSplitViewResolution = nil
            splitViewResolutionAttempts = 0
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
        private weak var titleLabel: NSTextField?

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
            guard let titleLabel, titleLabel.stringValue != title else { return }
            titleLabel.stringValue = title
        }

        func remove() {
            guard let window, let accessory else { return }
            if let index = window.titlebarAccessoryViewControllers.firstIndex(of: accessory) {
                window.removeTitlebarAccessoryViewController(at: index)
            }
            self.window = nil
            self.accessory = nil
            self.titleLabel = nil
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
            titleLabel = label
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
    let communitiesState: OctonautLoadState
    let onRefreshCommunities: () -> Void
    let accountName: String?
    let customFeeds: [CustomFeed]
    let onCreate: () -> Void
    let onEdit: (CustomFeed) -> Void
    let onDelete: (CustomFeed) -> Void

    var body: some View {
        List(selection: $selection) {
            Section("Feeds") {
                sidebarRow("Home", systemImage: "house", value: .feed(.home))
                sidebarRow("Popular", systemImage: "flame", value: .feed(.popular))
                sidebarRow("All", systemImage: "globe", value: .feed(.all))
                ForEach(customFeeds) { feed in
                    sidebarRow(feed.name, systemImage: "rectangle.stack", value: .feed(feed.descriptor))
                        .contextMenu {
                            Button("Edit Feed…") { onEdit(feed) }
                            Button("Delete Feed", role: .destructive) { onDelete(feed) }
                        }
                }
                Button(action: onCreate) {
                    Label("New Custom Feed…", systemImage: "plus")
                }
                .buttonStyle(.plain)
            }

            if accountName != nil || !communities.isEmpty {
                Section("Communities") {
                    switch communitiesState {
                    case .idle, .loading:
                        ProgressView("Loading communities…")
                    case .failed(let message):
                        Text("Couldn’t load communities. \(message)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Retry", action: onRefreshCommunities)
                    case .empty:
                        Text("No subscribed communities")
                            .foregroundStyle(.secondary)
                        Button("Refresh", action: onRefreshCommunities)
                    case .loaded:
                        EmptyView()
                    }
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

@MainActor
private struct MacCustomFeedEditor: View {
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State var feed: CustomFeed
    let communities: [CommunityCardModel]
    let onSave: (CustomFeed) -> Void
    @State private var communityInput = ""
    @State private var inputError: String?

    private var choices: [String] {
        Set(communities.map { $0.name.lowercased() }).union(feed.communities).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Feed").font(.title2.bold())
            TextField("Feed name", text: $feed.name)
            Text("Select communities for this feed. You can also add communities you don’t subscribe to.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Community name, e.g. r/swift", text: $communityInput)
                    .onSubmit(addCommunity)
                Button("Add", action: addCommunity)
                    .disabled(communityInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let inputError { Text(inputError).foregroundStyle(.red) }
            List(choices, id: \.self) { name in
                Toggle("r/\(name)", isOn: Binding(
                    get: { feed.communities.contains(name) },
                    set: { selected in
                        feed.communities.removeAll { $0 == name }
                        if selected { feed.communities.append(name) }
                    }
                ))
                .toggleStyle(.checkbox)
            }
            Text("\(feed.communities.count) selected. \(dependencies.settings.customFeedSyncStatus)")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    feed.name = feed.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    feed.communities.sort()
                    onSave(feed)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(feed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || feed.communities.isEmpty || !communityInput.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 460, height: 520)
    }

    private func addCommunity() {
        guard let name = CustomFeed.communityName(communityInput) else {
            inputError = "Enter a community name using letters, numbers or underscores, up to 21 characters."
            return
        }
        if !feed.communities.contains(name) { feed.communities.append(name) }
        communityInput = ""
        inputError = nil
    }
}
