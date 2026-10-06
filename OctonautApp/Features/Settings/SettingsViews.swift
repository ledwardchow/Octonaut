import SwiftUI
import UIKit

@MainActor
struct SettingsRootView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        Form {
            Section {
                NavigationLink(value: FeatureRoute.settings(.general)) { Label("General", systemImage: "slider.horizontal.3") }
                // ponytail: Theme is hidden until the app applies it.
                NavigationLink(value: FeatureRoute.settings(.appearance)) { Label("Appearance", systemImage: "rectangle.3.group") }
                NavigationLink(value: FeatureRoute.settings(.intelligence)) { Label("Intelligence", systemImage: "sparkles") }
            }
            Section {
                NavigationLink(value: FeatureRoute.settings(.account)) { Label("Account", systemImage: "person.crop.circle") }
                NavigationLink(value: FeatureRoute.settings(.blockedUsers)) { Label("Blocked Users", systemImage: "person.crop.circle.badge.xmark") }
                NavigationLink(value: FeatureRoute.settings(.dataUse)) { Label("Data Use", systemImage: "antenna.radiowaves.left.and.right") }
                NavigationLink(value: FeatureRoute.settings(.statistics)) { Label("Statistics", systemImage: "chart.bar") }
            }
            Section {
                NavigationLink(value: FeatureRoute.settings(.advanced)) { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                NavigationLink(value: FeatureRoute.settings(.about)) { Label("About Octonaut", systemImage: "info.circle") }
                LegalDocumentLinks()
            }
            Section {
                Text("Octonaut keeps preferences, drafts, filters, summaries, and statistics on this device. Reddit session secrets are stored in Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

@MainActor
struct SettingsDetailView: View {
    let destination: SettingsDestination
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingReset = false
    @State private var showingAppReset = false
    @State private var isResettingApp = false
    @State private var appResetNotice: AppResetNotice?
    @State private var imageCacheBytes = 0
    @State private var responseCacheBytes = 0
    @State private var usageStatistics = UsageStatistics()
    @State private var statisticsError: String?
    @State private var summaryAvailability: IntelligenceAvailability = .unsupported
    @State private var summaryAPIKey = ""
    @State private var apiKeySaved = false
    @State private var apiKeyMessage: String?

    var body: some View {
        settingsContent
        .formStyle(.grouped)
        .navigationTitle(destination.title)
        .confirmationDialog("Reset statistics?", isPresented: $showingReset, titleVisibility: .visible) {
            Button("Reset Statistics", role: .destructive) {
                Task { await resetStatistics() }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Reset Octonaut?", isPresented: $showingAppReset, titleVisibility: .visible) {
            Button("Reset App", role: .destructive) {
                Task { await resetApp() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes all Octonaut data from this device and deletes synced custom feeds from iCloud. You will need to sign in again.")
        }
        .alert(item: $appResetNotice) { notice in
            Alert(
                title: Text(notice.title),
                message: Text(notice.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .task(id: destination) {
            intelligenceAvailability = await dependencies.intelligence.availability
            if destination == .intelligence {
                await refreshIntelligenceSettings()
            }
            if destination == .dataUse {
                imageCacheBytes = await OctonautImageCache.diskUsage()
                responseCacheBytes = RedditResponseCache.diskUsage
            }
            if destination == .statistics {
                await loadStatistics()
            }
        }
        .onChange(of: dependencies.settings.configurationRevision) { _, _ in
            guard destination == .intelligence else { return }
            Task { summaryAvailability = await dependencies.intelligence.summaryAvailability }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        if destination == .blockedUsers {
            BlockedUsersSettingsContent(reddit: dependencies.reddit)
        } else {
            Form {
                switch destination {
                case .general:
                    general
                case .theme:
                    theme
                case .appearance:
                    appearance
                case .intelligence:
                    intelligence
                case .account:
                    account
                case .blockedUsers:
                    EmptyView()
                case .dataUse:
                    dataUse
                case .statistics:
                    statistics
                case .advanced:
                    advanced
                case .about:
                    about
                }
            }
        }
    }

    private var general: some View {
        Group {
            // ponytail: startup and comment-sort settings are hidden until the app applies them.
            Section("Sorting") {
                Picker("Default post sort", selection: Binding(get: { dependencies.settings.defaultPostSort }, set: { dependencies.settings.defaultPostSort = $0 })) {
                    ForEach(["default", "best", "hot", "new", "top", "rising", "controversial"], id: \.self) { value in Text(value.capitalized).tag(PostSort(rawValue: value)) }
                }
                Picker("Default top time", selection: Binding(get: { dependencies.settings.defaultTopTime }, set: { dependencies.settings.defaultTopTime = $0 })) {
                    ForEach(TopTime.allCases, id: \.self) { value in Text(value.title).tag(value) }
                }
                Toggle("Remember sort per community", isOn: Binding(get: { dependencies.settings.rememberSortPerCommunity }, set: { dependencies.settings.rememberSortPerCommunity = $0 }))
                // `spec/07-settings-reference.md` asks for this one too. The
                // property was persisted from the first commit but never had a
                // control, so nothing could turn it on.
                Toggle("Remember sort per multireddit", isOn: Binding(get: { dependencies.settings.rememberSortPerMultireddit }, set: { dependencies.settings.rememberSortPerMultireddit = $0 }))
            }
        }
    }

    private var theme: some View {
        Section {
            Picker("Theme", selection: Binding(get: { dependencies.settings.theme }, set: { dependencies.settings.theme = $0 })) {
                Text("System").tag(ThemeChoice.system); Text("Light").tag(ThemeChoice.light); Text("Dark").tag(ThemeChoice.dark); Text("Midnight").tag(ThemeChoice.midnight); Text("Deep Ocean").tag(ThemeChoice.deepOcean); Text("Aurora").tag(ThemeChoice.aurora)
            }
            Toggle("Pure black background", isOn: Binding(get: { dependencies.settings.pureBlackBackground }, set: { dependencies.settings.pureBlackBackground = $0 }))
            Toggle("Tint follows community", isOn: Binding(get: { dependencies.settings.tintFollowsCommunity }, set: { dependencies.settings.tintFollowsCommunity = $0 }))
            Text("Custom themes are checked for readable text contrast before saving.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var appearance: some View {
        Group {
            AppIconPicker()
            Section("Reading") {
                Picker("Feed layout", selection: Binding(get: { dependencies.settings.feedLayout }, set: { dependencies.settings.feedLayout = $0 })) { Text("Media cards").tag(FeedLayout.full); Text("Compact rows").tag(FeedLayout.compact) }
                Picker("Thumbnail side", selection: Binding(get: { dependencies.settings.compactThumbnailSide }, set: { dependencies.settings.compactThumbnailSide = $0 })) { Text("Left").tag(CompactThumbnailSide.left); Text("Right").tag(CompactThumbnailSide.right) }
                Toggle("Show post flair", isOn: Binding(get: { dependencies.settings.showPostFlair }, set: { dependencies.settings.showPostFlair = $0 }))
                Toggle("Blur spoilers", isOn: Binding(get: { dependencies.settings.blurSpoilers }, set: { dependencies.settings.blurSpoilers = $0 }))
                Toggle("Blur NSFW media", isOn: Binding(get: { dependencies.settings.blurNSFWMedia }, set: { dependencies.settings.blurNSFWMedia = $0 }))
                Toggle("Hide seen posts", isOn: Binding(get: { dependencies.settings.hideSeenPosts }, set: { dependencies.settings.hideSeenPosts = $0 }))
                Toggle("Mark posts seen while scrolling", isOn: Binding(get: { dependencies.settings.autoMarkSeenWhileScrolling }, set: { dependencies.settings.autoMarkSeenWhileScrolling = $0 }))
                Toggle("Show filter count", isOn: Binding(get: { dependencies.settings.showFilterCount }, set: { dependencies.settings.showFilterCount = $0 }))
                Picker("Video autoplay", selection: Binding(get: { dependencies.settings.autoplayVideo }, set: { dependencies.settings.autoplayVideo = $0 })) {
                    Text("Never").tag(AutoplayVideo.never)
                    Text("Wi-Fi").tag(AutoplayVideo.wifi)
                    Text("Always").tag(AutoplayVideo.always)
                }
                Toggle("Play video audio in feed", isOn: Binding(
                    get: { dependencies.settings.playFeedVideoAudio },
                    set: { dependencies.settings.playFeedVideoAudio = $0 }
                ))
            }
            Section("Large screens") {
                Toggle("Use split view", isOn: Binding(
                    get: { dependencies.settings.useSplitViewOnIPad },
                    set: { dependencies.settings.useSplitViewOnIPad = $0 }
                ))
                if UIDevice.current.userInterfaceIdiom != .pad {
                    Toggle("Show navigation at bottom", isOn: Binding(
                        get: { dependencies.settings.showBottomNavigationOnLargeScreens },
                        set: { dependencies.settings.showBottomNavigationOnLargeScreens = $0 }
                    ))
                }
                Text("Shows communities, the selected feed, and post details in separate columns on iPad and wide inner displays.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if UIDevice.current.userInterfaceIdiom != .pad {
                    Text("On wide phone displays, navigation starts at the top and can move to the side. Turn this on to use the floating bottom navigation instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var intelligence: some View {
        Group {
            Section("Summaries") {
                Picker("Summary provider", selection: Binding(
                    get: { dependencies.settings.summaryProvider },
                    set: { dependencies.settings.summaryProvider = $0 }
                )) {
                    ForEach(SummaryProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                if dependencies.settings.summaryProvider == .openAICompatible {
                    TextField("Endpoint", text: Binding(
                        get: { dependencies.settings.summaryEndpoint },
                        set: { dependencies.settings.summaryEndpoint = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    TextField("Model", text: Binding(
                        get: { dependencies.settings.summaryModel },
                        set: { dependencies.settings.summaryModel = $0 }
                    ))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    SecureField(apiKeySaved ? "API key saved" : "API key", text: $summaryAPIKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: summaryAPIKey) { _, _ in apiKeyMessage = nil }
                    HStack {
                        Button("Save API key") { Task { await saveSummaryAPIKey() } }
                            .disabled(summaryAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if apiKeySaved {
                            Button("Remove", role: .destructive) { Task { await removeSummaryAPIKey() } }
                        }
                    }
                    Text("Post and comment text is sent to this provider when you request a summary. The API key is stored in Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label("Apple Intelligence", systemImage: "sparkles")
                }
                Text(summaryAvailability.userMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let apiKeyMessage {
                    Text(apiKeyMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Toggle("Show post summaries", isOn: Binding(get: { dependencies.settings.showPostSummaries }, set: { dependencies.settings.showPostSummaries = $0 }))
                Toggle("Show comment summaries", isOn: Binding(get: { dependencies.settings.showCommentSummaries }, set: { dependencies.settings.showCommentSummaries = $0 }))
                Toggle("Automatically summarise posts", isOn: Binding(get: { dependencies.settings.automaticVisibleSummaries }, set: { dependencies.settings.automaticVisibleSummaries = $0 }))
                Toggle("Automatically summarise comments", isOn: Binding(
                    get: { dependencies.settings.automaticCommentSummaries },
                    set: {
                        dependencies.settings.automaticCommentSummaries = $0
                        if $0 { dependencies.settings.showCommentSummaries = true }
                    }
                ))
                Toggle("Use Key excerpts if unavailable", isOn: Binding(get: { dependencies.settings.keyExcerptsFallback }, set: { dependencies.settings.keyExcerptsFallback = $0 }))
            }
            Section("Filters") {
                SemanticFilterSettingsView(intelligence: dependencies.intelligence)
            }
        }
    }

    private func refreshIntelligenceSettings() async {
        do {
            apiKeySaved = try await dependencies.summaryAPIKeyStore.apiKey()?.isEmpty == false
        } catch {
            apiKeyMessage = error.localizedDescription
        }
        summaryAvailability = await dependencies.intelligence.summaryAvailability
    }

    private func saveSummaryAPIKey() async {
        do {
            try await dependencies.summaryAPIKeyStore.saveAPIKey(summaryAPIKey)
            summaryAPIKey = ""
            apiKeySaved = true
            apiKeyMessage = "API key saved."
            summaryAvailability = await dependencies.intelligence.summaryAvailability
        } catch {
            apiKeyMessage = error.localizedDescription
        }
    }

    private func removeSummaryAPIKey() async {
        do {
            try await dependencies.summaryAPIKeyStore.removeAPIKey()
            summaryAPIKey = ""
            apiKeySaved = false
            apiKeyMessage = "API key removed."
            summaryAvailability = await dependencies.intelligence.summaryAvailability
        } catch {
            apiKeyMessage = error.localizedDescription
        }
    }

    private var account: some View {
        Section {
            NavigationLink(value: FeatureRoute.account(store.accounts.first?.username ?? "Accounts")) { Label("Manage Accounts", systemImage: "person.2") }
            Toggle("Show username in Account tab", isOn: Binding(get: { dependencies.settings.showUsernameInAccountTab }, set: { dependencies.settings.showUsernameInAccountTab = $0 }))
            Text("Account sessions are isolated. Removing an account also removes its Keychain credential and private cached data.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var dataUse: some View {
        Group {
            // ponytail: data-mode settings are hidden until media loading applies them.
            Section("Storage") {
                Picker("Image cache limit", selection: Binding(
                    get: { dependencies.settings.imageCacheLimitMB },
                    set: { value in
                        dependencies.settings.imageCacheLimitMB = value
                        Task { await OctonautImageCache.configure(diskCapacityMB: value) }
                    }
                )) {
                    ForEach([100, 250, 500, 1_000], id: \.self) { limit in
                        Text(limit == 1_000 ? "1 GB" : "\(limit) MB").tag(limit)
                    }
                }
                LabeledContent("Image cache", value: ByteCountFormatter.string(
                    fromByteCount: Int64(imageCacheBytes),
                    countStyle: .file
                ))
                LabeledContent("Reddit response cache", value: ByteCountFormatter.string(
                    fromByteCount: Int64(responseCacheBytes),
                    countStyle: .file
                ))
                Button("Clear Network and Media Cache") {
                    RedditResponseCache.removeAll()
                    responseCacheBytes = 0
                    Task {
                        await SubscribedCommunitiesCache.shared.removeAll()
                        await UserProfileCache.shared.removeAll()
                        await OctonautImageCache.removeAll()
                        imageCacheBytes = 0
                    }
                }
            }
        }
    }

    private var statistics: some View {
        Group {
            Section {
                Toggle("Collect local usage statistics", isOn: Binding(get: { dependencies.settings.collectLocalUsageStatistics }, set: { dependencies.settings.collectLocalUsageStatistics = $0 }))
                LabeledContent("Posts viewed", value: usageStatistics.postsViewed.formatted())
                LabeledContent("Community visits", value: usageStatistics.communityVisits.formatted())
                LabeledContent("Scroll distance", value: usageStatistics.scrollDistanceMeters.formatted(.number.precision(.fractionLength(1))) + " m")
                if let statisticsError {
                    Text(statisticsError).font(.footnote).foregroundStyle(.red)
                }
            }
            Section {
                Button("Reset Statistics", role: .destructive) { showingReset = true }
            }
        }
    }

    private func loadStatistics() async {
        do {
            usageStatistics = try await dependencies.persistence.loadUsageStatistics()
            statisticsError = nil
        } catch {
            statisticsError = "Statistics could not be loaded."
        }
    }

    private func resetStatistics() async {
        showingReset = false
        do {
            try await dependencies.persistence.resetUsageStatistics()
            usageStatistics = UsageStatistics()
            statisticsError = nil
        } catch {
            statisticsError = "Statistics could not be reset."
        }
    }

    private var advanced: some View {
        Group {
            Section("Intelligence") {
                LabeledContent("Summary provider", value: dependencies.settings.summaryProvider.title)
                LabeledContent("On-device model", value: intelligenceAvailability == .available ? "Available" : "Unavailable")
                Text(intelligenceAvailability.userMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Reset") {
                Button("Reset Settings to Defaults", role: .destructive) { dependencies.settings.resetToDefaults() }
                Button("Reset App", role: .destructive) { showingAppReset = true }
                    .disabled(isResettingApp)
                Text("Removes accounts, Keychain credentials, drafts, preferences, caches, statistics, and synced custom feeds.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func resetApp() async {
        isResettingApp = true
        defer { isResettingApp = false }
        do {
            try await dependencies.resetAllData()
            appResetNotice = AppResetNotice(
                title: "Octonaut Reset",
                message: "All app data was removed. You can now sign in again."
            )
        } catch {
            appResetNotice = AppResetNotice(title: "Reset Incomplete", message: error.localizedDescription)
        }
    }

    @State private var intelligenceAvailability: IntelligenceAvailability = .unsupported

    private var about: some View {
        Section {
            VStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill").font(.system(size: 52)).foregroundStyle(.orange)
                Text("Octonaut").font(.title2.weight(.bold))
                Text("A native, local-first Reddit reader for Apple platforms.")
                    .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("Version 1.0").font(.caption).foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
        }
    }
}

private struct AppResetNotice: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}


@MainActor
private struct BlockedUsersSettingsContent: View {
    @Environment(AppDependencies.self) private var dependencies
    @State private var model: BlockedUsersSettingsModel
    @State private var username = ""
    @State private var pendingAction: BlockedUserAction?
    @State private var showingLogin = false

    init(reddit: any RedditClient) {
        _model = State(initialValue: BlockedUsersSettingsModel(reddit: reddit))
    }

    private var accountContext: String {
        "\(dependencies.accounts.selectedAccountID?.rawValue.uuidString ?? "anonymous"):\(dependencies.accounts.selectionGeneration)"
    }
    private var accountID: AccountID? {
        dependencies.accounts.selectedAccount?.health == .healthy ? dependencies.accounts.selectedAccountID : nil
    }
    private var newUsername: String? { BlockedUsersSettingsModel.normalizedUsername(username) }
    private var busy: Bool { model.isLoading || model.isUpdating }

    var body: some View {
        Form {
            Section {
                if let account = dependencies.accounts.selectedAccount {
                    Text("Block list for u/\(account.username)")
                }
                Text("These changes apply to your Reddit account.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if accountID == nil || model.needsLogin {
                Section {
                    Text("Sign in to view and manage blocked users.")
                    Button("Sign In") { showingLogin = true }
                }
            } else {
                Section("Add a blocked user") {
                    TextField("Username or u/username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(busy)
                    Button("Block User", role: .destructive) {
                        if let newUsername { pendingAction = BlockedUserAction(username: newUsername, blocked: true) }
                    }
                    .disabled(busy || newUsername == nil
                              || newUsername?.caseInsensitiveCompare(dependencies.accounts.selectedAccount?.username ?? "") == .orderedSame
                              || model.users.contains { $0.id == newUsername?.lowercased() })
                }
                Section("Blocked users (\(model.users.count))") {
                    if model.isLoading { ProgressView("Loading blocked users…") }
                    if model.isUpdating { ProgressView("Updating block list…") }
                    if model.users.isEmpty && !model.isLoading && model.errorMessage == nil {
                        Text("No blocked users.").foregroundStyle(.secondary)
                    }
                    ForEach(model.users) { user in
                        HStack {
                            OctonautUsernameLink(username: user.username)
                            Spacer()
                            Button("Unblock") {
                                pendingAction = BlockedUserAction(username: user.username, blocked: false)
                            }
                            .buttonStyle(.bordered)
                            .disabled(busy)
                            .accessibilityLabel("Unblock u/\(user.username)")
                        }
                    }
                    Button("Refresh") { Task { await reload() } }.disabled(busy)
                }
            }
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.secondary)
                    Button("Retry") { Task { await reload() } }.disabled(busy)
                }
            }
        }
        .task(id: accountContext) {
            username = ""
            pendingAction = nil
            await reload()
        }
        .sheet(isPresented: $showingLogin) {
            RedditLoginView(accounts: dependencies.accounts)
        }
        .confirmationDialog(
            pendingAction.map { "\($0.blocked ? "Block" : "Unblock") u/\($0.username)?" } ?? "Update block list?",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } }),
            titleVisibility: .visible
        ) {
            if let action = pendingAction {
                Button(action.blocked ? "Block User" : "Unblock User", role: action.blocked ? .destructive : nil) {
                    Task {
                        if await model.setBlocked(action.blocked, username: action.username), action.blocked {
                            username = ""
                        }
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
    }

    private func reload() async {
        await model.load(accountID: accountID, context: accountContext)
    }
}

private struct BlockedUserAction {
    let username: String
    let blocked: Bool
}
