import SwiftUI

@MainActor
struct SettingsRootView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies

    var body: some View {
        Form {
            Section {
                NavigationLink(value: FeatureRoute.settings(.general)) { Label("General", systemImage: "slider.horizontal.3") }
                NavigationLink(value: FeatureRoute.settings(.theme)) { Label("Theme", systemImage: "paintpalette") }
                NavigationLink(value: FeatureRoute.settings(.appearance)) { Label("Appearance", systemImage: "rectangle.3.group") }
                NavigationLink(value: FeatureRoute.settings(.intelligence)) { Label("Intelligence", systemImage: "sparkles") }
            }
            Section {
                NavigationLink(value: FeatureRoute.settings(.account)) { Label("Account", systemImage: "person.crop.circle") }
                NavigationLink(value: FeatureRoute.settings(.dataUse)) { Label("Data Use", systemImage: "antenna.radiowaves.left.and.right") }
                NavigationLink(value: FeatureRoute.settings(.statistics)) { Label("Statistics", systemImage: "chart.bar") }
            }
            Section {
                NavigationLink(value: FeatureRoute.settings(.advanced)) { Label("Advanced", systemImage: "wrench.and.screwdriver") }
                NavigationLink(value: FeatureRoute.settings(.about)) { Label("About Octonaut", systemImage: "info.circle") }
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
    @AppStorage("appearance.showUsername") private var showUsername = true
    @State private var showingReset = false
    @State private var imageCacheBytes = 0
    @State private var responseCacheBytes = 0
    @State private var usageStatistics = UsageStatistics()
    @State private var statisticsError: String?
    @State private var summaryAvailability: IntelligenceAvailability = .unsupported
    @State private var summaryAPIKey = ""
    @State private var apiKeySaved = false
    @State private var apiKeyMessage: String?

    var body: some View {
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
        .formStyle(.grouped)
        .navigationTitle(destination.title)
        .confirmationDialog("Reset statistics?", isPresented: $showingReset, titleVisibility: .visible) {
            Button("Reset Statistics", role: .destructive) {
                Task { await resetStatistics() }
            }
            Button("Cancel", role: .cancel) {}
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

    private var general: some View {
        Group {
            Section("Startup") {
                Picker("Startup tab", selection: Binding(get: { dependencies.settings.startupTab }, set: { dependencies.settings.startupTab = $0 })) {
                    Text("Posts").tag(AppTab.posts); Text("Inbox").tag(AppTab.inbox); Text("Accounts").tag(AppTab.account)
                }
                Picker("Startup destination", selection: startupDestination) {
                    Text("Home").tag("home"); Text("Popular").tag("popular"); Text("All").tag("all")
                }
                Toggle("Restore last screen", isOn: Binding(get: { dependencies.settings.restoreLastScreen }, set: { dependencies.settings.restoreLastScreen = $0 }))
            }
            Section("Sorting") {
                Picker("Default post sort", selection: Binding(get: { dependencies.settings.defaultPostSort }, set: { dependencies.settings.defaultPostSort = $0 })) {
                    ForEach(["default", "best", "hot", "new", "top", "rising", "controversial"], id: \.self) { value in Text(value.capitalized).tag(PostSort(rawValue: value)) }
                }
                Picker("Default comment sort", selection: Binding(get: { dependencies.settings.defaultCommentSort }, set: { dependencies.settings.defaultCommentSort = $0 })) {
                    ForEach(["best", "new", "top", "controversial", "old", "qa"], id: \.self) { value in Text(value == "qa" ? "Q&A" : value.capitalized).tag(CommentSort(rawValue: value)) }
                }
                Toggle("Remember sort per community", isOn: Binding(get: { dependencies.settings.rememberSortPerCommunity }, set: { dependencies.settings.rememberSortPerCommunity = $0 }))
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
            Section("Reading") {
                Picker("Feed layout", selection: Binding(get: { dependencies.settings.feedLayout }, set: { dependencies.settings.feedLayout = $0 })) { Text("Media cards").tag(FeedLayout.full); Text("Compact rows").tag(FeedLayout.compact) }
                Picker("Thumbnail side", selection: Binding(get: { dependencies.settings.compactThumbnailSide }, set: { dependencies.settings.compactThumbnailSide = $0 })) { Text("Left").tag(CompactThumbnailSide.left); Text("Right").tag(CompactThumbnailSide.right) }
                Toggle("Show community icons", isOn: Binding(get: { dependencies.settings.showCommunityIcons }, set: { dependencies.settings.showCommunityIcons = $0 }))
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
            }
            Section("iPad") {
                Toggle("Use split view", isOn: Binding(
                    get: { dependencies.settings.useSplitViewOnIPad },
                    set: { dependencies.settings.useSplitViewOnIPad = $0 }
                ))
                Text("Shows communities, the selected feed, and post details in separate columns when space allows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
            Toggle("Show username in Account tab", isOn: $showUsername)
            Toggle("Confirm account switch while composing", isOn: Binding(get: { dependencies.settings.confirmAccountSwitchWhileComposing }, set: { dependencies.settings.confirmAccountSwitchWhileComposing = $0 }))
            Text("Account sessions are isolated. Removing an account also removes its Keychain credential and private cached data.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var dataUse: some View {
        Group {
            Section("Connection") {
                Picker("Wi-Fi", selection: Binding(get: { dependencies.settings.wifiDataMode }, set: { dependencies.settings.wifiDataMode = $0 })) { Text("Normal").tag(DataMode.normal); Text("Low Data").tag(DataMode.lowData) }
                Picker("Cellular", selection: Binding(get: { dependencies.settings.cellularDataMode }, set: { dependencies.settings.cellularDataMode = $0 })) { Text("Normal").tag(DataMode.normal); Text("Low Data").tag(DataMode.lowData) }
                Toggle("Respect system Low Data Mode", isOn: Binding(get: { dependencies.settings.respectSystemLowDataMode }, set: { dependencies.settings.respectSystemLowDataMode = $0 }))
                Toggle("Respect Low Power Mode", isOn: Binding(get: { dependencies.settings.respectLowPowerMode }, set: { dependencies.settings.respectLowPowerMode = $0 }))
            }
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
                LabeledContent("Summary cache", value: "0 MB")
            }
            Section("Reset") {
                Button("Reset Settings to Defaults", role: .destructive) { dependencies.settings.resetToDefaults() }
            }
        }
    }

    @State private var intelligenceAvailability: IntelligenceAvailability = .unsupported

    private var startupDestination: Binding<String> {
        Binding(
            get: {
                switch dependencies.settings.startupPostsDestination {
                case .popular: "popular"
                case .all: "all"
                default: "home"
                }
            },
            set: { value in
                switch value {
                case "popular": dependencies.settings.startupPostsDestination = .popular
                case "all": dependencies.settings.startupPostsDestination = .all
                default: dependencies.settings.startupPostsDestination = .home
                }
            }
        )
    }

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
