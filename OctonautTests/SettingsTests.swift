import XCTest
@testable import Octonaut

@MainActor
final class SettingsTests: XCTestCase {
    func testCustomFeedsStayInCloudWhenUserLogsOutAndReturnForSameUsername() async throws {
        let dependencies = AppDependencies.preview()
        let settings = dependencies.settings
        // The preview suite can contain feeds from other preview runs.
        settings.removeAllData()
        let cloud = MemoryFeedCloud()
        settings.startCustomFeedSync(using: cloud)
        let firstAccount = Account(username: "Reader", health: .healthy)
        try await dependencies.persistence.saveAccount(firstAccount)
        await dependencies.accounts.load()
        settings.customFeeds = [CustomFeed(name: "Tech", communities: ["swift"])]
        let owned = try XCTUnwrap(settings.customFeeds.first)
        XCTAssertEqual(owned.ownerUsername, "reader")
        let cloudBeforeLogout = cloud.values

        try await dependencies.accounts.logOut()
        XCTAssertTrue(settings.customFeeds.isEmpty)
        XCTAssertEqual(cloud.values, cloudBeforeLogout)

        // Logging in creates a new local ID after logout removed the old account.
        let newAccount = Account(username: "READER", health: .healthy)
        try await dependencies.persistence.saveAccount(newAccount)
        await dependencies.accounts.load()
        try await dependencies.accounts.select(newAccount.id)
        XCTAssertEqual(settings.customFeeds, [owned])
    }

    func testCustomFeedSyncAndDeletionAreScopedToUsername() throws {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "OwnedFeed.A.\(UUID())")!)
        let cloud = MemoryFeedCloud()
        settings.startCustomFeedSync(using: cloud)
        settings.setCustomFeedUser("alice")
        settings.customFeeds = [CustomFeed(name: "Alice's feed", communities: ["swift"])]
        let aliceFeed = try XCTUnwrap(settings.customFeeds.first)
        settings.setCustomFeedUser("bob")
        XCTAssertTrue(settings.customFeeds.isEmpty)
        settings.customFeeds = [CustomFeed(name: "Bob's feed", communities: ["games"])]
        settings.customFeeds = []
        settings.setCustomFeedUser("alice")
        XCTAssertEqual(settings.customFeeds, [aliceFeed])

        let otherDevice = SettingsStore(defaults: UserDefaults(suiteName: "OwnedFeed.B.\(UUID())")!)
        otherDevice.startCustomFeedSync(using: cloud)
        XCTAssertTrue(otherDevice.customFeeds.isEmpty)
        otherDevice.setCustomFeedUser("ALICE")
        XCTAssertEqual(otherDevice.customFeeds, [aliceFeed])
        otherDevice.setCustomFeedUser("bob")
        XCTAssertTrue(otherDevice.customFeeds.isEmpty)
    }

    func testLegacyFeedsAreAssignedOnceAndAnonymousFeedsStaySeparate() throws {
        let defaults = UserDefaults(suiteName: "OwnedFeed.Legacy.\(UUID())")!
        let legacy = CustomFeed(name: "Old feed", communities: ["swift"], ownerUsername: nil)
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "feeds.custom")
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.customFeeds.isEmpty)
        settings.setCustomFeedUser("alice")
        XCTAssertEqual(settings.customFeeds.first?.ownerUsername, "alice")
        settings.setCustomFeedUser("bob")
        XCTAssertTrue(settings.customFeeds.isEmpty)
        settings.setCustomFeedUser(nil)
        settings.customFeeds = [CustomFeed(name: "Anonymous feed", communities: ["games"])]
        settings.setCustomFeedUser("alice")
        XCTAssertEqual(settings.customFeeds.map(\.name), ["Old feed"])
        let restarted = SettingsStore(defaults: defaults)
        XCTAssertEqual(restarted.customFeeds.map(\.name), ["Anonymous feed"])
        restarted.setCustomFeedUser("alice")
        XCTAssertEqual(restarted.customFeeds.map(\.name), ["Old feed"])
    }

    func testFeedVideoAudioDefaultsOffAndPersists() {
        let defaults = UserDefaults(suiteName: "FeedVideoAudio.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.playFeedVideoAudio)

        settings.playFeedVideoAudio = true
        XCTAssertTrue(SettingsStore(defaults: defaults).playFeedVideoAudio)
    }

    func testCustomFeedsSyncCreateEditDeleteAndKeepOfflineCopiesDeleted() throws {
        let aDefaults = UserDefaults(suiteName: "FeedSync.A.\(UUID())")!
        let bDefaults = UserDefaults(suiteName: "FeedSync.B.\(UUID())")!
        let a = SettingsStore(defaults: aDefaults)
        let b = SettingsStore(defaults: bDefaults)
        let cloud = MemoryFeedCloud()
        a.startCustomFeedSync(using: cloud)
        b.startCustomFeedSync(using: cloud)
        let feed = CustomFeed(name: "Games", communities: ["games", "valheim"])
        a.customFeeds = [feed]
        b.mergeCustomFeedsFromCloud()
        XCTAssertEqual(b.customFeeds, [feed])
        b.customFeeds[0].name = "Gaming"
        b.customFeeds[0].communities.append("macgaming")
        a.mergeCustomFeedsFromCloud()
        XCTAssertEqual(a.customFeeds, b.customFeeds)
        a.customFeeds = []
        // A stale device reconnects without making any edits.
        let restartedB = SettingsStore(defaults: bDefaults)
        restartedB.startCustomFeedSync(using: cloud)
        XCTAssertTrue(restartedB.customFeeds.isEmpty)
        XCTAssertTrue(a.customFeeds.isEmpty)
        let deletion = try JSONDecoder().decode(CustomFeedSyncRecord.self, from: XCTUnwrap(cloud.values[CustomFeedSyncRecord.key(for: feed.id)]))
        XCTAssertNil(deletion.feed)
    }

    func testCustomFeedSyncMergesSeparateDeviceEditsAndMigratesLocalFeeds() {
        let a = SettingsStore(defaults: UserDefaults(suiteName: "FeedSync.A.\(UUID())")!)
        let b = SettingsStore(defaults: UserDefaults(suiteName: "FeedSync.B.\(UUID())")!)
        let cloud = MemoryFeedCloud()
        let games = CustomFeed(name: "Games", communities: ["games"])
        let tech = CustomFeed(name: "Tech", communities: ["swift"])
        a.customFeeds = [games]
        a.startCustomFeedSync(using: cloud)
        b.startCustomFeedSync(using: cloud)
        a.customFeeds[0].name = "Gaming"
        b.customFeeds.append(tech)
        b.mergeCustomFeedsFromCloud()
        a.mergeCustomFeedsFromCloud()
        XCTAssertEqual(a.customFeeds, b.customFeeds)
        XCTAssertEqual(a.customFeeds.map(\.name), ["Gaming", "Tech"])
    }

    func testLegacyFeedMigrationHonorsCloudRevisionAndMalformedDataIsIgnored() throws {
        let defaults = UserDefaults(suiteName: "FeedSync.Legacy.\(UUID())")!
        let legacy = CustomFeed(name: "Games", communities: ["games"])
        defaults.set(try JSONEncoder().encode([legacy]), forKey: "feeds.custom")
        let cloud = MemoryFeedCloud()
        var remote = legacy
        remote.name = "Gaming"
        let record = CustomFeedSyncRecord(id: remote.id, feed: remote, modifiedAt: 100)
        cloud.set(try JSONEncoder().encode(record), forKey: CustomFeedSyncRecord.key(for: remote.id))
        cloud.set(Data("broken".utf8), forKey: "customFeed.v1.invalid")
        let store = SettingsStore(defaults: defaults)
        store.startCustomFeedSync(using: cloud)
        XCTAssertEqual(store.customFeeds, [remote])
        XCTAssertEqual(SettingsStore(defaults: defaults).customFeeds, [remote])
    }

    func testCustomFeedSyncConflictOrderIsDeterministic() {
        let feed = CustomFeed(name: "Games", communities: ["games"])
        let edit = CustomFeedSyncRecord(id: feed.id, feed: feed, modifiedAt: 100, revision: "a")
        let deletion = CustomFeedSyncRecord(id: feed.id, feed: nil, modifiedAt: 100, revision: "b")
        XCTAssertTrue(deletion.isNewer(than: edit))
        XCTAssertFalse(edit.isNewer(than: deletion))
    }

    func testAppleAccountChangeDoesNotUploadPreviousAccountsFeeds() {
        let defaults = UserDefaults(suiteName: "FeedSync.Account.\(UUID())")!
        let store = SettingsStore(defaults: defaults)
        let cloud = MemoryFeedCloud()
        store.startCustomFeedSync(using: cloud)
        store.customFeeds = [CustomFeed(name: "Games", communities: ["games"])]
        cloud.values = [:]
        store.mergeCustomFeedsFromCloud(replacingAccount: true)
        XCTAssertTrue(store.customFeeds.isEmpty)
        XCTAssertTrue(cloud.values.isEmpty)
        XCTAssertNotNil(defaults.data(forKey: "feeds.previousAppleAccount.backup"))
    }

    func testCombinedFeedFallsBackToOldWebsiteWithPaginationAndSession() async throws {
        GamesRouteProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GamesRouteProtocol.self]
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic-test-session")])
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
        let page = try await client.listing(
            ListingRequest(feed: FeedDescriptor(destination: .combined(["Swift", "macos"]), sort: .top, topTime: .week),
                           limit: 35, after: "t3_previous", accountScope: .account(account), responseCachePolicy: .reloadIgnoringCache),
            account: account
        )
        XCTAssertEqual(page.items.map { $0.community.name }, ["swift"])
        XCTAssertEqual(page.after, "t3_next")
        let requests = GamesRouteProtocol.requests
        XCTAssertEqual(requests.map { $0.url?.host }, ["www.reddit.com", "old.reddit.com"])
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.path, "/r/swift+macos/top.json")
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertTrue(query.contains(URLQueryItem(name: "after", value: "t3_previous")))
            XCTAssertTrue(query.contains(URLQueryItem(name: "t", value: "week")))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=synthetic-test-session")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testCombinedFeedDoesNotRetryAccessDeniedAndSingleFeedDoesNotFallBack() async throws {
        for (destination, expectedError) in [(FeedDestination.combined(["denied", "swift"]), RedditClientError.accessDenied), (.community("missing"), .notFound)] {
            GamesRouteProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GamesRouteProtocol.self]
            let account = AccountID()
            let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic-test-session")])
            let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
            do {
                _ = try await client.listing(ListingRequest(feed: FeedDescriptor(destination: destination)), account: account)
                XCTFail("Expected request failure")
            } catch { XCTAssertEqual(error as? RedditClientError, expectedError) }
            XCTAssertEqual(GamesRouteProtocol.requests.count, 1)
        }
    }

    func testFeedRejectsUntrustedOrInsecureHostsBeforeSendingCredentials() async throws {
        for base in ["http://www.reddit.com", "https://example.com", "https://www.reddit.com:8443"] {
            GamesRouteProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GamesRouteProtocol.self]
            let account = AccountID()
            let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic-test-session")])
            let client = URLSessionRedditClient(baseURL: URL(string: base)!, credentialVault: vault, sessionConfiguration: configuration)
            do {
                _ = try await client.listing(ListingRequest(feed: FeedDescriptor(destination: .combined(["swift", "macos"]))), account: account)
                XCTFail("Expected invalid URL")
            } catch { XCTAssertEqual(error as? RedditClientError, .invalidURL) }
            XCTAssertTrue(GamesRouteProtocol.requests.isEmpty)
        }
    }

    func testSwitchingFeedsClearsPanesAndIgnoresAnOlderResponse() async throws {
        let homeData = Data(#"{"data":{"children":[{"kind":"t3","data":{"id":"old","name":"t3_old","title":"Old feed","subreddit":"oldcommunity","permalink":"/r/oldcommunity/comments/old/title/","author":"reader"}}],"after":null}}"#.utf8)
        let customData = Data(#"{"data":{"children":[{"kind":"t3","data":{"id":"new","name":"t3_new","title":"New feed","subreddit":"swift","permalink":"/r/swift/comments/new/title/","author":"reader"}}],"after":null}}"#.utf8)
        let destination = FeedDestination.combined(["swift", "macos"])
        let client = FixtureRedditClient(
            listingsByDestination: [.home: homeData, destination: customData],
            delaysByDestination: [.home: .milliseconds(180), destination: .milliseconds(20)]
        )
        let store = OctonautFeatureStore(reddit: client)
        let oldLoad = Task { await store.refreshPosts(for: .home) }
        while await client.listingRequests() == 0 { await Task.yield() }
        store.detailPost = .sample
        store.clearVisibleFeed()
        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertTrue(store.comments.isEmpty)
        XCTAssertNil(store.detailPost)
        XCTAssertEqual(store.feedState, .loading)
        let custom = CustomFeed(name: "Technology", communities: ["swift", "macos"])
        await store.refreshPosts(for: custom.descriptor)
        XCTAssertEqual(store.posts.map(\.community), ["swift"])
        await oldLoad.value
        XCTAssertEqual(store.posts.map(\.community), ["swift"])
        XCTAssertEqual(store.feedState, .loaded)
    }

    func testClearingDetailIgnoresAnOutstandingPostLoad() async throws {
        let client = FixtureRedditClient(postDelay: .milliseconds(80))
        let store = OctonautFeatureStore(reddit: client)
        let load = Task { await store.loadPostDetail(for: .sample) }
        while store.detailState != .loading { await Task.yield() }
        store.clearVisibleFeed()
        let succeeded = await load.value
        XCTAssertFalse(succeeded)
        XCTAssertNil(store.detailPost)
        XCTAssertTrue(store.comments.isEmpty)
        XCTAssertEqual(store.detailState, .idle)
    }

    func testReopeningPostUsesCachedCommentsUntilRefresh() async throws {
        let thread = Data(#"[{"data":{"children":[{"kind":"t3","data":{"id":"sample","name":"t3_sample","title":"Cached post","subreddit":"swift","permalink":"/r/swift/comments/sample/title/","author":"reader"}}]}},{"data":{"children":[{"kind":"t1","data":{"id":"reply","name":"t1_reply","parent_id":"t3_sample","body":"Cached comment","author":"reply_author","created_utc":1700000000}}]}}]"#.utf8)
        let client = FixtureRedditClient(postData: thread)
        let store = OctonautFeatureStore(reddit: client)

        let firstLoad = await store.loadPostDetail(for: .sample)
        XCTAssertTrue(firstLoad)
        XCTAssertEqual(store.comments.count, 1)
        store.clearPostDetail()
        let secondLoad = await store.loadPostDetail(for: .sample)
        XCTAssertTrue(secondLoad)
        XCTAssertEqual(store.comments.count, 1)
        let requestsAfterReopen = await client.postRequests()
        XCTAssertEqual(requestsAfterReopen, 1)

        let refreshed = await store.loadPostDetail(for: .sample, forceRefresh: true)
        XCTAssertTrue(refreshed)
        let requestsAfterRefresh = await client.postRequests()
        XCTAssertEqual(requestsAfterRefresh, 2)
    }

    func testCustomFeedLoadsCombinedCommunitiesWithoutAnAccount() async throws {
        let client = FixtureRedditClient(listingData: Data(#"{"data":{"children":[],"after":null}}"#.utf8))
        let store = OctonautFeatureStore(reddit: client)
        let feed = CustomFeed(name: "Technology", communities: ["swift", "macos"])
        await store.refreshPosts(for: feed.descriptor)
        let captured = await client.lastListingRequest
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.feed.destination, .combined(["swift", "macos"]))
        XCTAssertEqual(request.accountScope, .anonymous)
        XCTAssertEqual(request.feed.sort, .hot)
    }

    func testCustomFeedsPersistMembershipAndIdentity() throws {
        let suite = "OctonautTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        XCTAssertTrue(settings.customFeeds.isEmpty)
        let feed = CustomFeed(name: "Technology", communities: ["swift", "macos"])
        settings.customFeeds = [feed]
        let reloaded = SettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.customFeeds, [feed])
        XCTAssertEqual(feed.descriptor.kind, .custom)
        XCTAssertEqual(feed.descriptor.communities, ["swift", "macos"])
        XCTAssertEqual(feed.descriptor.customFeedID, feed.id)
        var edited = feed
        edited.communities = ["ios"]
        XCTAssertNotEqual(edited.descriptor, feed.descriptor)
        reloaded.customFeeds = []
        XCTAssertTrue(SettingsStore(defaults: defaults).customFeeds.isEmpty)
    }

    func testCustomCommunityNamesRejectRoutesAndNormalizePrefixes() {
        XCTAssertEqual(CustomFeed.communityName(" /r/Swift "), "swift")
        XCTAssertEqual(CustomFeed.communityName("r/iOS"), "ios")
        for invalid in ["", "../swift", "swift+ios", "swift?x=1", "https://example.com", "all", "popular"] {
            XCTAssertNil(CustomFeed.communityName(invalid), invalid)
        }
    }

    func testDefaultsMatchTheReleaseOneBaseline() {
        let defaults = UserDefaults(suiteName: "OctonautTests.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.feedLayout, .full)
        XCTAssertEqual(settings.defaultPostSort.rawValue, "default")
        XCTAssertEqual(settings.defaultTopTime, .day)
        XCTAssertTrue(settings.openRedditLinksInOctonaut)
        XCTAssertTrue(settings.collectLocalUsageStatistics)
        XCTAssertEqual(settings.summaryProvider, .openAICompatible)
        XCTAssertEqual(settings.summaryEndpoint, "https://openrouter.ai/api/v1")
        XCTAssertEqual(settings.summaryModel, "openai/gpt-5.6-luna")
        XCTAssertFalse(settings.keyExcerptsFallback)
        XCTAssertFalse(settings.showBottomNavigationOnLargeScreens)
    }

    func testLargeScreenNavigationPlacementRoundTripsThroughDefaults() {
        let suite = "OctonautTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)

        settings.showBottomNavigationOnLargeScreens = true

        XCTAssertTrue(SettingsStore(defaults: defaults).showBottomNavigationOnLargeScreens)
    }

    func testChangingFilterIncrementsFilterRevision() {
        let defaults = UserDefaults(suiteName: "OctonautTests.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        let before = settings.filterRevision
        settings.hideSeenPosts.toggle()
        XCTAssertEqual(settings.filterRevision, before &+ 1)
    }

    func testThemeRoundTripsThroughDefaults() {
        let suite = "OctonautTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.theme = .deepOcean
        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reloaded.theme, .deepOcean)
    }

    func testShowUsernameInAccountTabRoundTripsThroughDefaults() {
        let suite = "OctonautTests.\(UUID())"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(settings.showUsernameInAccountTab)
        settings.showUsernameInAccountTab = false

        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertFalse(reloaded.showUsernameInAccountTab)
    }

    private func post(id: String = "t3_blur", isNSFW: Bool, isSpoiler: Bool) -> PostCardModel {
        PostCardModel(
            id: id, community: "pics", author: "someone", title: "Title", body: "",
            score: 1, comments: 0, age: "1h", vote: 0, isSaved: false, isSeen: false,
            isNSFW: isNSFW, isSpoiler: isSpoiler, isSticky: false, isVideo: false,
            hasMedia: true, mediaTitle: "",
            shareURL: URL(string: "https://www.reddit.com/r/pics/comments/blur")!
        )
    }

    func testBlurPreferencesGateSensitivityPerKind() {
        let nsfw = post(isNSFW: true, isSpoiler: false)
        let spoiler = post(isNSFW: false, isSpoiler: true)
        let both = post(isNSFW: true, isSpoiler: true)
        let neither = post(isNSFW: false, isSpoiler: false)

        for post in [nsfw, spoiler, both] {
            XCTAssertTrue(post.isSensitive(blurringNSFW: true, blurringSpoilers: true))
            XCTAssertFalse(post.isSensitive(blurringNSFW: false, blurringSpoilers: false))
        }
        XCTAssertFalse(neither.isSensitive(blurringNSFW: true, blurringSpoilers: true))

        // Each toggle only suppresses its own kind.
        XCTAssertFalse(nsfw.isSensitive(blurringNSFW: false, blurringSpoilers: true))
        XCTAssertTrue(spoiler.isSensitive(blurringNSFW: false, blurringSpoilers: true))
        XCTAssertTrue(nsfw.isSensitive(blurringNSFW: true, blurringSpoilers: false))
        XCTAssertFalse(spoiler.isSensitive(blurringNSFW: true, blurringSpoilers: false))

        // A post that is both stays blurred until both toggles are off.
        XCTAssertTrue(both.isSensitive(blurringNSFW: true, blurringSpoilers: false))
        XCTAssertTrue(both.isSensitive(blurringNSFW: false, blurringSpoilers: true))
    }

    func testAutomaticCommentSummaryRoundTripsThroughDefaults() {
        let suite = "OctonautTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.automaticCommentSummaries)
        settings.automaticCommentSummaries = true

        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(reloaded.automaticCommentSummaries)
    }

    func testAvailableModelEnablesSummaryCardsWhenUserHasNotChosen() {
        let defaults = UserDefaults(suiteName: "OctonautTests.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)

        settings.applySummaryVisibilityDefaults(modelAvailable: true)

        XCTAssertTrue(settings.showPostSummaries)
        XCTAssertTrue(settings.showCommentSummaries)
    }

    func testAvailabilityDefaultPreservesExplicitSummaryChoices() {
        let defaults = UserDefaults(suiteName: "OctonautTests.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.showPostSummaries = false
        settings.showCommentSummaries = false

        settings.applySummaryVisibilityDefaults(modelAvailable: true)

        XCTAssertFalse(settings.showPostSummaries)
        XCTAssertFalse(settings.showCommentSummaries)
    }

    func testSummaryProviderSettingsRoundTripThroughDefaults() {
        let suite = "OctonautTests.\(UUID())"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.summaryProvider = .onDevice
        settings.summaryEndpoint = "https://example.test/v1"
        settings.summaryModel = "summary-model"

        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reloaded.summaryProvider, .onDevice)
        XCTAssertEqual(reloaded.summaryEndpoint, "https://example.test/v1")
        XCTAssertEqual(reloaded.summaryModel, "summary-model")
    }

    func testOpenAICompatibleEndpointAddsChatCompletionsPath() {
        let configuration = OpenAICompatibleSummaryConfiguration(
            endpoint: "https://openrouter.ai/api/v1/",
            model: "openai/gpt-5.6-luna"
        )

        XCTAssertEqual(
            configuration.chatCompletionsURL?.absoluteString,
            "https://openrouter.ai/api/v1/chat/completions"
        )
        XCTAssertTrue(configuration.isValid)
    }

    func testOpenRouterRequestsIdentifyOctonaut() throws {
        let configuration = OpenAICompatibleSummaryConfiguration(
            endpoint: "https://openrouter.ai/api/v1",
            model: "openai/gpt-5.6-luna"
        )
        var request = URLRequest(url: try XCTUnwrap(configuration.chatCompletionsURL))

        configuration.addOpenRouterAttributionHeaders(to: &request)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "HTTP-Referer"),
            "https://github.com/ledwardchow/octonaut"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Title"), "Octonaut")
    }

    func testOtherProvidersDoNotReceiveOpenRouterIdentification() throws {
        let configuration = OpenAICompatibleSummaryConfiguration(
            endpoint: "https://example.test/v1",
            model: "summary-model"
        )
        var request = URLRequest(url: try XCTUnwrap(configuration.chatCompletionsURL))

        configuration.addOpenRouterAttributionHeaders(to: &request)

        XCTAssertNil(request.value(forHTTPHeaderField: "HTTP-Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-OpenRouter-Title"))
    }

    func testRemoveAllDataClearsDefaultsAndSyncedFeeds() {
        let defaults = UserDefaults(suiteName: "Reset.\(UUID())")!
        defaults.set("leftover", forKey: "unknown.future.setting")
        let store = SettingsStore(defaults: defaults)
        let cloud = MemoryFeedCloud()
        store.startCustomFeedSync(using: cloud)
        store.feedLayout = .compact
        store.customFeeds = [CustomFeed(name: "Games", communities: ["games"])]
        XCTAssertFalse(cloud.values.isEmpty)

        store.removeAllData()

        XCTAssertEqual(store.feedLayout, .full)
        XCTAssertTrue(store.customFeeds.isEmpty)
        XCTAssertTrue(cloud.values.isEmpty)
        XCTAssertNil(defaults.object(forKey: "unknown.future.setting"))
    }

    // MARK: - Profile sections

    func testFailedUnsaveRestoresOnlyItsPostAfterAnotherUnsaveSucceeds() throws {
        let first = post(id: "first", isNSFW: false, isSpoiler: false)
        let second = post(id: "second", isNSFW: false, isSpoiler: false)
        let third = post(id: "third", isNSFW: false, isSpoiler: false)
        var posts = [first, second, third]

        let failed = try XCTUnwrap(UserSectionPostRemoval(postID: first.id, posts: &posts))
        _ = try XCTUnwrap(UserSectionPostRemoval(postID: second.id, posts: &posts))
        failed.restore(in: &posts)

        XCTAssertEqual(posts.map(\.id), ["first", "third"])
        failed.restore(in: &posts)
        XCTAssertEqual(posts.map(\.id), ["first", "third"])
    }

    func testProfileActionsUseOnlyTheSelectedWebsiteSession() async throws {
        UserSectionRouteProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserSectionRouteProtocol.self]
        let selected = AccountID()
        let other = AccountID()
        let vault = InMemoryCredentialVault(values: [
            selected: RedditCredential(cookieValue: "synthetic-selected", modhash: "synthetic-modhash"),
            other: RedditCredential(cookieValue: "synthetic-other")
        ])
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
        for action in [RedditAction.follow(username: "reader", following: true), .block(username: "reader", blocked: true)] {
            _ = try await client.perform(action, account: selected)
        }
        XCTAssertEqual(UserSectionRouteProtocol.requests.count, 2)
        for request in UserSectionRouteProtocol.requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "www.reddit.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=synthetic-selected")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Modhash"), "synthetic-modhash")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        do {
            _ = try await client.perform(.follow(username: "reader", following: true), account: AccountID())
            XCTFail("Missing website session should require login")
        } catch {
            XCTAssertEqual(error as? RedditClientError, .authenticationRequired)
        }
        XCTAssertEqual(UserSectionRouteProtocol.requests.count, 2)
    }

    func testUnblockUsesTheSignedInUsersIDAndWebsiteSession() async throws {
        UserSectionRouteProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserSectionRouteProtocol.self]
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [
            account: RedditCredential(cookieValue: "synthetic-selected", modhash: "synthetic-modhash")
        ])
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
        _ = try await client.perform(.block(username: "reader", blocked: false), account: account)
        let requests = UserSectionRouteProtocol.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.url?.path, "/user/me/about.json")
        let mutation = try XCTUnwrap(requests.last)
        XCTAssertEqual(mutation.url?.path, "/api/unfriend")
        XCTAssertEqual(mutation.httpMethod, "POST")
        let body = try XCTUnwrap(mutation.httpBody ?? mutation.httpBodyStream.flatMap { stream in
            stream.open()
            defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            let count = stream.read(&bytes, maxLength: bytes.count)
            return count > 0 ? Data(bytes.prefix(count)) : nil
        })
        var components = URLComponents()
        components.percentEncodedQuery = String(decoding: body, as: UTF8.self)
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(fields["name"], "reader")
        XCTAssertEqual(fields["type"], "enemy")
        XCTAssertEqual(fields["container"], "t2_abc123")
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "www.reddit.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=synthetic-selected")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
        XCTAssertEqual(mutation.value(forHTTPHeaderField: "X-Modhash"), "synthetic-modhash")
    }

    func testUnblockDoesNotSendAMutationWithoutTheSignedInUsersID() async throws {
        UserSectionRouteProtocol.reset()
        UserSectionRouteProtocol.identityData = Data(#"{"data":{"name":"selected"}}"#.utf8)
        defer { UserSectionRouteProtocol.reset() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserSectionRouteProtocol.self]
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic-selected")])
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
        do {
            _ = try await client.perform(.block(username: "reader", blocked: false), account: account)
            XCTFail("Unblock must require a valid signed-in user ID")
        } catch {
            XCTAssertEqual(error as? RedditClientError, .authenticationRequired)
        }
        XCTAssertEqual(UserSectionRouteProtocol.requests.count, 1)
        XCTAssertEqual(UserSectionRouteProtocol.requests.first?.httpMethod, "GET")
    }

    func testBlockedUsersListingUsesTheSelectedWebsiteSessionAndPaging() async throws {
        UserSectionRouteProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserSectionRouteProtocol.self]
        let account = AccountID()
        let client = URLSessionRedditClient(
            credentialVault: InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic-selected")]),
            sessionConfiguration: configuration
        )
        let page = try await client.blockedUsers(after: "t2_previous", account: account)
        XCTAssertEqual(page.items.map(\.username), ["blocked_reader"])
        let request = try XCTUnwrap(UserSectionRouteProtocol.requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host, "www.reddit.com")
        XCTAssertEqual(request.url?.path, "/prefs/blocked.json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=synthetic-selected")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "after", value: "t2_previous")))
        XCTAssertTrue(query.contains(URLQueryItem(name: "limit", value: "100")))
        do {
            _ = try await client.blockedUsers(after: nil, account: AccountID())
            XCTFail("Missing session must require login")
        } catch {
            XCTAssertEqual(error as? RedditClientError, .authenticationRequired)
        }
        XCTAssertEqual(UserSectionRouteProtocol.requests.count, 1)
    }

    func testBlockedUsersCodecHandlesWebsiteUserListsAndWrappedUsers() throws {
        let data = Data(#"{"kind":"UserList","data":{"children":[{"name":"reader","id":"t2_1"},{"kind":"t2","data":{"name":"other","id":"2"}},{"name":"READER","id":"t2_1"}],"after":"t2_next"}}"#.utf8)
        let page = try RedditJSONCodec.decodeBlockedUsers(data)
        XCTAssertEqual(page.items.map(\.username), ["reader", "other"])
        XCTAssertEqual(page.after, "t2_next")
        XCTAssertThrowsError(try RedditJSONCodec.decodeBlockedUsers(Data(#"{"data":{}}"#.utf8)))
        XCTAssertThrowsError(try RedditJSONCodec.decodeBlockedUsers(Data(#"{"data":{"children":[{"name":"../unsafe"}]}}"#.utf8)))
    }

    func testBlockedUsersSettingsLoadsAddsAndRemovesWithoutDuplicates() async {
        let client = FixtureRedditClient(blockedUsers: ["zebra", "reader", "READER"])
        let model = BlockedUsersSettingsModel(reddit: client)
        await model.load(accountID: AccountID(), context: "account")
        XCTAssertEqual(model.users.map(\.username), ["reader", "zebra"])
        let added = await model.setBlocked(true, username: " u/new_reader ")
        XCTAssertTrue(added)
        XCTAssertEqual(model.users.map(\.username), ["new_reader", "reader", "zebra"])
        let removed = await model.setBlocked(false, username: "READER")
        XCTAssertTrue(removed)
        XCTAssertEqual(model.users.map(\.username), ["new_reader", "zebra"])
        XCTAssertNil(BlockedUsersSettingsModel.normalizedUsername("invalid/name"))
        XCTAssertNil(BlockedUsersSettingsModel.normalizedUsername(""))
    }

    func testFailedBlockListChangeKeepsTheUserVisible() async {
        let client = FixtureRedditClient(blockedUsers: ["reader"], actionResult: ActionResult(succeeded: false, message: "Denied"))
        let model = BlockedUsersSettingsModel(reddit: client)
        await model.load(accountID: AccountID(), context: "account")
        let removed = await model.setBlocked(false, username: "reader")
        XCTAssertFalse(removed)
        XCTAssertEqual(model.users.map(\.username), ["reader"])
        XCTAssertEqual(model.errorMessage, "Denied")
        XCTAssertFalse(model.isUpdating)
    }

    func testChangingAccountDiscardsThePreviousBlockedUsersResponse() async {
        let client = FixtureRedditClient(blockedUsers: ["private_reader"], listingDelay: .milliseconds(100))
        let model = BlockedUsersSettingsModel(reddit: client)
        let pending = Task { await model.load(accountID: AccountID(), context: "old-account") }
        while !model.isLoading { await Task.yield() }
        await model.load(accountID: nil, context: "signed-out")
        await pending.value
        XCTAssertTrue(model.users.isEmpty)
        XCTAssertTrue(model.needsLogin)
        XCTAssertFalse(model.isLoading)
    }

    func testUserSectionListingUsesTheSectionRouteWithoutASortPathSegment() async throws {
        UserSectionRouteProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserSectionRouteProtocol.self]
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic-test-session")])
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)

        let page = try await client.listing(
            ListingRequest(
                feed: FeedDescriptor(
                    destination: .user(username: "Example_Author", section: .saved),
                    sort: .new
                ),
                limit: 35,
                accountScope: .account(account),
                responseCachePolicy: .reloadIgnoringCache
            ),
            account: account
        )

        XCTAssertEqual(page.items.map(\.id), ["saved"])
        let request = try XCTUnwrap(UserSectionRouteProtocol.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/user/Example_Author/saved.json")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "sort", value: "new")))
        // A mixed listing is narrowed to posts, since `listing` only returns posts.
        XCTAssertTrue(query.contains(URLQueryItem(name: "type", value: "links")))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=synthetic-test-session")
    }

    func testSavedCommentsUseTheSameRouteNarrowedToComments() async throws {
        UserSectionRouteProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserSectionRouteProtocol.self]
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic-test-session")])
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)

        let page = try await client.userComments("Example_Author", section: .saved, after: nil, account: account)

        XCTAssertEqual(page.items.map(\.id), ["savedcomment"])
        let url = try XCTUnwrap(UserSectionRouteProtocol.requests.first?.url)
        XCTAssertEqual(url.path, "/user/Example_Author/saved.json")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(URLQueryItem(name: "type", value: "comments")))
    }

    func testProfileSubmittedListingDoesNotAskForALinksOnlyListing() async throws {
        UserSectionRouteProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserSectionRouteProtocol.self]
        let client = URLSessionRedditClient(credentialVault: InMemoryCredentialVault(), sessionConfiguration: configuration)

        _ = try await client.listing(
            ListingRequest(
                feed: FeedDescriptor(
                    destination: .user(username: "Example_Author", section: .submitted),
                    sort: .new
                ),
                responseCachePolicy: .reloadIgnoringCache
            ),
            account: nil
        )

        let url = try XCTUnwrap(UserSectionRouteProtocol.requests.last?.url)
        XCTAssertEqual(url.path, "/user/Example_Author/submitted.json")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertFalse(query.contains { $0.name == "type" })
    }

    func testFetchUserSectionAsksForTheSavedListingAndReturnsItsRows() async throws {
        let client = FixtureRedditClient(
            listingData: Data(#"{"data":{"children":[{"kind":"t3","data":{"id":"saved","name":"t3_saved","title":"A saved post","subreddit":"swift","permalink":"/r/swift/comments/saved/title/","author":"reader"}}],"after":"t3_next"}}"#.utf8)
        )
        let store = OctonautFeatureStore(reddit: client)

        let page = try await store.fetchUserSection(.saved, username: "Example_Author")

        XCTAssertEqual(page.posts.map(\.id), ["saved"])
        XCTAssertEqual(page.nextPage, "t3_next")
        let captured = await client.lastListingRequest
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.feed.destination, .user(username: "Example_Author", section: .saved))
        XCTAssertEqual(request.feed.sort, .new)
    }

    // MARK: - Top time range

    func testTopSortCarriesATimeRangeAndOtherSortsDoNot() async throws {
        let client = FixtureRedditClient(listingData: Data(#"{"data":{"children":[],"after":null}}"#.utf8))
        let store = OctonautFeatureStore(reddit: client)

        await store.applySort(.top, topTime: .week, for: .home)
        var captured = await client.lastListingRequest
        var request = try XCTUnwrap(captured)
        XCTAssertEqual(request.feed.sort, .top)
        XCTAssertEqual(request.feed.topTime, .week)

        await store.applySort(.new, for: .home)
        captured = await client.lastListingRequest
        request = try XCTUnwrap(captured)
        XCTAssertEqual(request.feed.sort, .new)
        XCTAssertNil(request.feed.topTime)
    }

    func testChangingSortRereadsTheFeedAndReturningToOneReusesItsCache() async throws {
        let client = FixtureRedditClient(listingData: Data(#"{"data":{"children":[{"kind":"t3","data":{"id":"one","name":"t3_one","title":"A post","subreddit":"swift","permalink":"/r/swift/comments/one/title/","author":"reader"}}],"after":null}}"#.utf8))
        let store = OctonautFeatureStore(reddit: client)

        await store.refreshPosts(for: .home)
        var requests = await client.listingRequests()
        XCTAssertEqual(requests, 1)

        // A new sort is a different listing, so the cached rows must not answer it.
        await store.applySort(.top, topTime: .day, for: .home)
        requests = await client.listingRequests()
        XCTAssertEqual(requests, 2)

        // A different time range on the same sort is also a different listing.
        await store.applySort(.top, topTime: .year, for: .home)
        requests = await client.listingRequests()
        XCTAssertEqual(requests, 3)

        // Returning to a sort read moments ago is served from the cache.
        await store.applySort(.top, topTime: .day, for: .home)
        requests = await client.listingRequests()
        XCTAssertEqual(requests, 3)
        XCTAssertEqual(store.posts.map(\.id), ["one"])
    }

    func testStoreStartsOnTheDefaultSortAndTopTimeFromSettings() async throws {
        let defaults = UserDefaults(suiteName: "Sorting.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.defaultPostSort = .top
        settings.defaultTopTime = .year
        let client = FixtureRedditClient(listingData: Data(#"{"data":{"children":[],"after":null}}"#.utf8))
        let store = OctonautFeatureStore(reddit: client, settings: settings)

        XCTAssertEqual(store.selectedSort, .top)
        XCTAssertEqual(store.selectedTopTime, .year)
        await store.refreshPosts(for: .home)
        let captured = await client.lastListingRequest
        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.feed.sort, .top)
        XCTAssertEqual(request.feed.topTime, .year)
    }

    func testDefaultSortFallsBackToBestSoTheSortControlHasASelection() {
        let defaults = UserDefaults(suiteName: "Sorting.Default.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.defaultPostSort, .default)
        let store = OctonautFeatureStore(reddit: FixtureRedditClient(), settings: settings)
        XCTAssertEqual(store.selectedSort, .best)
    }

    func testCombinedFeedReadsHotWhereRedditHasNoBestListing() {
        let store = OctonautFeatureStore(reddit: FixtureRedditClient())
        store.selectedSort = .best
        let custom = CustomFeed(name: "Technology", communities: ["swift", "macos"]).descriptor
        XCTAssertEqual(store.effectiveSort(for: custom), .hot)
        XCTAssertEqual(store.effectiveSort(for: .home), .best)
    }

    func testPreviewLineSettingsClampWithoutRecursing() {
        let defaults = UserDefaults(suiteName: "PreviewLines.\(UUID())")!
        let store = SettingsStore(defaults: defaults)

        store.selfTextPreviewLines = 100
        store.linkDescriptionLines = -1

        XCTAssertEqual(store.selfTextPreviewLines, 20)
        XCTAssertEqual(store.linkDescriptionLines, 0)
        XCTAssertEqual(defaults.integer(forKey: "appearance.selfTextPreviewLines"), 20)
        XCTAssertEqual(defaults.integer(forKey: "appearance.linkDescriptionLines"), 0)
    }
}

/// Serves every profile-section route with one post and one comment. These
/// tests never contact Reddit.
private final class UserSectionRouteProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = RequestStorage()
    private final class RequestStorage: @unchecked Sendable {
        let lock = NSLock()
        var values: [URLRequest] = []
        var identityData = Data(#"{"data":{"id":"abc123","name":"selected"}}"#.utf8)
    }
    static var identityData: Data {
        get {
            storage.lock.lock()
            defer { storage.lock.unlock() }
            return storage.identityData
        }
        set {
            storage.lock.lock()
            defer { storage.lock.unlock() }
            storage.identityData = newValue
        }
    }
    static var requests: [URLRequest] {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.values
    }
    static func reset() {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.values = []
        storage.identityData = Data(#"{"data":{"id":"abc123","name":"selected"}}"#.utf8)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.storage.lock.lock()
        Self.storage.values.append(request)
        Self.storage.lock.unlock()
        let url = request.url!
        let listingData = Data(#"""
        {"data":{"after":"t3_next","before":null,"children":[
          {"kind":"t3","data":{"id":"saved","name":"t3_saved","title":"A saved post","subreddit":"swift","permalink":"/r/swift/comments/saved/title/","author":"reader"}},
          {"kind":"t1","data":{"id":"savedcomment","name":"t1_savedcomment","parent_id":"t3_saved","body":"A saved comment","subreddit":"swift","author":"reader","link_title":"A saved post","link_permalink":"https://www.reddit.com/r/swift/comments/saved/title/"}}
        ]}}
        """#.utf8)
        let data: Data
        if url.path == "/user/me/about.json" {
            data = Self.identityData
        } else if url.path == "/prefs/blocked.json" {
            data = Data(#"{"kind":"UserList","data":{"children":[{"name":"blocked_reader","id":"t2_blocked"}],"after":null}}"#.utf8)
        } else {
            data = listingData
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Intercepts every request. These tests never contact Reddit.
private final class GamesRouteProtocol: URLProtocol, @unchecked Sendable {
    private static let storage = RequestStorage()
    private final class RequestStorage: @unchecked Sendable {
        let lock = NSLock()
        var values: [URLRequest] = []
    }
    static var requests: [URLRequest] {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        return storage.values
    }
    static func reset() {
        storage.lock.lock()
        defer { storage.lock.unlock() }
        storage.values = []
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.storage.lock.lock()
        Self.storage.values.append(request)
        Self.storage.lock.unlock()
        let url = request.url!
        let status = url.path.contains("denied") ? 403 : (url.host == "old.reddit.com" ? 200 : 404)
        let data = Data(#"{"data":{"children":[{"kind":"t3","data":{"id":"test","name":"t3_test","title":"Test post","subreddit":"swift","permalink":"/r/swift/comments/test/title/","author":"reader"}}],"after":"t3_next"}}"#.utf8)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
private final class MemoryFeedCloud: CustomFeedCloudStore {
    var values: [String: Data] = [:]
    func set(_ data: Data, forKey key: String) { values[key] = data }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    func synchronize() -> Bool { true }
}
