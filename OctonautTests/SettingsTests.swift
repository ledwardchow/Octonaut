import XCTest
@testable import Octonaut

@MainActor
final class SettingsTests: XCTestCase {
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
    func synchronize() -> Bool { true }
}
