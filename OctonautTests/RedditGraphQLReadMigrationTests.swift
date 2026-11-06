import Foundation
import XCTest
@testable import Octonaut

final class RedditGraphQLReadMigrationTests: XCTestCase {
    @MainActor
    func testEmptySearchPageKeepsContinuationVisibleAndStopsRepeatedCursor() async {
        let fixture = FixtureRedditClient(searchData: Data(#"{"data":{"children":[],"after":"next"}}"#.utf8))
        let model = SearchFeatureModel(reddit: fixture)
        await model.submit(query: "swift", scope: .posts)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.hasMoreResults)
        await model.loadMore()
        XCTAssertEqual(model.state, .empty)
        XCTAssertFalse(model.hasMoreResults)
        XCTAssertFalse(model.isLoadingMore)
    }

    func testAdOnlyFeedPageAdvancesUsingServerProvidedPostCursor() async throws {
        let account = AccountID()
        let after = Data("t3_pageboundary".utf8).base64EncodedString()
        let empty = #"{"data":{"homeFeed":{"elements":{"edges":[{"node":{"id":"t3_ad","adPayload":{}}}],"pageInfo":{"hasNextPage":true,"endCursor":"\#(after)"}}}}}"#
        let scenario = ReadMigrationScenario([
            "HomeFeedSdui": [empty, Self.feed("homeFeed", ids: ["t3_first"])],
            "PostsByIds": [Self.posts(["t3_first"])]
        ])
        defer { scenario.close() }
        let result = try await scenario.client(account: account).listing(ListingRequest(feed: FeedDescriptor(destination: .home)), account: account)
        XCTAssertEqual(result.items.map(\.id), ["first"])
        XCTAssertEqual(scenario.variables(for: "HomeFeedSdui").last?["after"] as? String, after)
        scenario.assertOperations(["HomeFeedSdui": 2, "PostsByIds": 1])
    }

    func testFeedWithoutHasNextPageHydratesPostsAndContinues() async throws {
        let account = AccountID()
        let page = #"{"data":{"homeV3":{"elements":{"edges":[{"node":{"groupId":"t3_first"}}],"pageInfo":{"endCursor":"opaque-server-cursor"}}}}}"#
        let end = #"{"data":{"homeV3":{"elements":{"edges":[],"pageInfo":{"endCursor":null}}}}}"#
        let scenario = ReadMigrationScenario([
            "HomeFeedSdui": [page, end],
            "PostsByIds": [Self.posts(["t3_first"])]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let feed = FeedDescriptor(destination: .home)
        let first = try await client.listing(ListingRequest(feed: feed), account: account)
        XCTAssertEqual(first.items.map(\.id), ["first"])
        let next = try await client.listing(ListingRequest(feed: feed, after: XCTUnwrap(first.after)), account: account)
        XCTAssertTrue(next.items.isEmpty)
        XCTAssertNil(next.after)
        XCTAssertEqual(scenario.variables(for: "HomeFeedSdui").last?["after"] as? String,
                       Data("t3_first".utf8).base64EncodedString())
        scenario.assertOperations(["HomeFeedSdui": 2, "PostsByIds": 1])
    }

    func testNamedUnavailableSubscriptionsRemainVisible() throws {
        let data = Data(#"{"data":{"identity":{"subscribedSubredditInfos":{"edges":[{"node":{"__typename":"UnavailableSubreddit","name":"privatecommunity","forbiddenReason":"PRIVATE"}}],"pageInfo":{"hasNextPage":false}}}}}"#.utf8)
        let page = try RedditGraphQLCodec.subscriptions(data: data, fetchSubscribed: true, fetchFollowed: false)
        let community = try XCTUnwrap(page.communities.first)
        XCTAssertEqual(community.reference.name, "privatecommunity")
        XCTAssertTrue(community.isPrivate)
        XCTAssertTrue(community.isSubscribed)
    }

    func testStructuredPostBodyUsesMarkdownRendererFormat() throws {
        let data = Data(#"{"data":{"postsInfoByIds":[{"__typename":"SubredditPost","id":"t3_post","title":"Post","isSelfPost":true,"content":{"richtext":{"document":[{"e":"par","c":[{"e":"text","t":"Body","f":[[1,0,4]]}]}]}}}]}}"#.utf8)
        let post = try XCTUnwrap(RedditGraphQLCodec.posts(data: data, orderedIDs: ["t3_post"]).first)
        XCTAssertEqual(post.body?.plainText, "**Body**")
    }

    func testOpeningSameFeedAgainKeepsExistingContinuationUsable() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "HomeFeedSdui": [Self.feed("homeFeed", ids: ["t3_first"]), Self.feed("homeFeed", ids: ["t3_second"]), Self.feed("homeFeed", ids: [])],
            "PostsByIds": [Self.posts(["t3_first"]), Self.posts(["t3_second"])]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let feed = FeedDescriptor(destination: .home)
        let first = try await client.listing(ListingRequest(feed: feed), account: account)
        _ = try await client.listing(ListingRequest(feed: feed), account: account)
        let next = try await client.listing(ListingRequest(feed: feed, after: XCTUnwrap(first.after)), account: account)
        XCTAssertTrue(next.items.isEmpty)
        scenario.assertOperations(["HomeFeedSdui": 3, "PostsByIds": 2])
    }

    func testSelectionInvalidationChangesSessionScopeImmediately() async throws {
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic-session")])
        let client = RedditGraphQLClient(credentialVault: vault)
        let first = try await client.sessionGeneration(for: account)
        client.invalidateContinuations()
        let second = try await client.sessionGeneration(for: account)
        XCTAssertNotEqual(first, second)
    }

    func testPartialGraphQLErrorDoesNotBecomeEmptyFeed() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "HomeFeedSdui": [#"{"data":{"homeFeed":{"elements":{"edges":[]}}},"errors":[{"message":"private server details"}]}"#]
        ])
        defer { scenario.close() }
        do {
            _ = try await scenario.client(account: account).listing(ListingRequest(feed: FeedDescriptor(destination: .home)), account: account)
            XCTFail("Partial errors must fail")
        } catch { XCTAssertEqual(error as? RedditClientError, .malformedResponse) }
        scenario.assertOperations(["HomeFeedSdui": 1])
    }

    func testGatedSubredditRequiresAccessApprovalEvenWithSubredditType() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [#"{"data":{"subredditInfoByName":{"__typename":"Subreddit","forbiddenReason":"GATED"}}}"#]
        ])
        defer { scenario.close() }
        do {
            _ = try await scenario.client(account: account).listing(ListingRequest(feed: FeedDescriptor(destination: .community("swift"))), account: account)
            XCTFail("Gated content needs user-visible approval")
        } catch {
            XCTAssertEqual(error as? RedditClientError, .http(statusCode: 403, message: "Open this community on Reddit to approve access."))
        }
        scenario.assertOperations(["SubredditInfoByName": 1])
    }

    func testDeletedProfilePostUsesRequestedIdentityAndLink() throws {
        let data = Data(#"{"data":{"postsInfoByIds":[{"__typename":"DeletedProfilePost"}]}}"#.utf8)
        let url = try XCTUnwrap(URL(string: "https://www.reddit.com/user/reader/comments/post/"))
        let post = try XCTUnwrap(RedditGraphQLCodec.posts(data: data, orderedIDs: ["t3_post"], deletedPostPermalink: url).first)
        XCTAssertEqual(post.id, "post")
        XCTAssertEqual(post.title, "[deleted]")
        XCTAssertEqual(post.permalink, url)
        XCTAssertEqual(post.body?.plainText, "[deleted]")
    }

    func testHomeFeedHydratesInFeedOrderAndUsesScopedNextPage() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "HomeFeedSdui": [Self.feed("homeFeed", ids: ["t3_first", "t3_second"]), Self.feed("homeFeed", ids: [])],
            "PostsByIds": [Self.posts(["t3_second", "t3_first"])]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let request = ListingRequest(feed: FeedDescriptor(destination: .home))
        let first = try await client.listing(request, account: account)
        XCTAssertEqual(first.items.map(\.title), ["first", "second"])
        let cursor = try XCTUnwrap(first.after)
        XCTAssertNotEqual(cursor, "t3_second")
        XCTAssertEqual(scenario.variables(for: "HomeFeedSdui").first?["sort"] as? String, "BEST")
        XCTAssertEqual(scenario.variables(for: "PostsByIds").first?["ids"] as? [String], ["t3_first", "t3_second"])
        let last = try await client.listing(ListingRequest(feed: request.feed, after: cursor), account: account)
        XCTAssertTrue(last.items.isEmpty)
        XCTAssertNil(last.after)
        XCTAssertEqual(scenario.variables(for: "HomeFeedSdui").last?["after"] as? String,
                       Data("t3_second".utf8).base64EncodedString())
        scenario.assertOperations(["HomeFeedSdui": 2, "PostsByIds": 1])
    }

    func testFeedCursorRejectsOtherAccountAndFeedBeforeRequest() async throws {
        let account = AccountID()
        let second = AccountID()
        let scenario = ReadMigrationScenario([
            "HomeFeedSdui": [Self.feed("homeFeed", ids: ["t3_first"])],
            "PostsByIds": [Self.posts(["t3_first"])]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account, additionalAccount: second)
        let first = try await client.listing(ListingRequest(feed: FeedDescriptor(destination: .home)), account: account)
        let cursor = try XCTUnwrap(first.after)
        for (feed, selected) in [(FeedDescriptor(destination: .home), second),
                                 (FeedDescriptor(destination: .popular), account)] {
            do {
                _ = try await client.listing(ListingRequest(feed: feed, after: cursor), account: selected)
                XCTFail("A cursor from another account or feed must fail")
            } catch {
                XCTAssertEqual(error as? RedditClientError,
                               .http(statusCode: 400, message: "This Reddit sort or page direction is unavailable."))
            }
        }
        scenario.assertOperations(["HomeFeedSdui": 1, "PostsByIds": 1])
    }

    func testCommunityRequestChecksAccessAndNormalizesName() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [#"{"data":{"subredditInfoByName":{"__typename":"Subreddit"}}}"#],
            "SubredditFeedSdui": [Self.feed("subredditFeed", ids: ["t3_first"])],
            "PostsByIds": [Self.posts(["t3_first"])]
        ])
        defer { scenario.close() }
        let result = try await scenario.client(account: account).listing(
            ListingRequest(feed: FeedDescriptor(destination: .community("r/swift"))), account: account)
        XCTAssertEqual(result.items.map(\.id), ["first"])
        XCTAssertEqual(scenario.variables(for: "SubredditInfoByName").first?["subredditName"] as? String, "swift")
        XCTAssertEqual(scenario.variables(for: "SubredditFeedSdui").first?["subredditName"] as? String, "swift")
        scenario.assertOperations(["SubredditInfoByName": 1, "SubredditFeedSdui": 1, "PostsByIds": 1])
    }

    func testSignedInCombinedFeedNormalizesSourcesOrdersNewPostsAndBuffersNextPage() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [Self.availableCommunity, Self.availableCommunity],
            "SubredditFeedSdui": [
                Self.finalFeed(ids: ["t3_a1", "t3_a2"]),
                Self.finalFeed(ids: ["t3_b1", "t3_b2"])
            ],
            "PostsByIds": [
                Self.posts([("t3_a1", 400, 100), ("t3_a2", 200, 90)]),
                Self.posts([("t3_b1", 300, 80), ("t3_b2", 100, 70)])
            ]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let feed = FeedDescriptor(destination: .combined(["r/Swift", "swift", "MACOS"]), sort: .new)
        let first = try await client.listing(ListingRequest(feed: feed, limit: 2), account: account)
        XCTAssertEqual(first.items.map(\.id), ["a1", "b1"])
        XCTAssertTrue(first.communityFailures.isEmpty)
        let cursor = try XCTUnwrap(first.after)
        XCTAssertNotEqual(cursor, "t3_b1")
        let second = try await client.listing(ListingRequest(feed: feed, limit: 2, after: cursor), account: account)
        XCTAssertEqual(second.items.map(\.id), ["a2", "b2"])
        XCTAssertNil(second.after)
        XCTAssertEqual(scenario.variables(for: "SubredditInfoByName").compactMap { $0["subredditName"] as? String }, ["swift", "macos"])
        XCTAssertEqual(scenario.variables(for: "SubredditFeedSdui").compactMap { $0["subredditName"] as? String }, ["swift", "macos"])
        scenario.assertOperations(["SubredditInfoByName": 2, "SubredditFeedSdui": 2, "PostsByIds": 2])
    }

    func testCombinedHotInterleavesCommunitiesAndDeduplicatesPostFullnames() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [Self.availableCommunity, Self.availableCommunity],
            "SubredditFeedSdui": [
                Self.finalFeed(ids: ["t3_a1", "t3_shared", "t3_a2"]),
                Self.finalFeed(ids: ["t3_b1", "t3_shared", "t3_b2"])
            ],
            "PostsByIds": [
                Self.posts(["t3_a1", "t3_shared", "t3_a2"]),
                Self.posts(["t3_b1", "t3_shared", "t3_b2"])
            ]
        ])
        defer { scenario.close() }
        let result = try await scenario.client(account: account).listing(
            ListingRequest(feed: FeedDescriptor(destination: .combined(["swift", "macos"]), sort: .hot), limit: 10), account: account)
        XCTAssertEqual(result.items.map(\.id), ["a1", "b1", "shared", "b2", "a2"])
        XCTAssertNil(result.after)
        scenario.assertOperations(["SubredditInfoByName": 2, "SubredditFeedSdui": 2, "PostsByIds": 2])
    }

    func testCombinedTopUsesScoreThenDateAndKeepsSourceOrderForTies() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [Self.availableCommunity, Self.availableCommunity],
            "SubredditFeedSdui": [Self.finalFeed(ids: ["t3_a1", "t3_a2"]),
                                  Self.finalFeed(ids: ["t3_b1", "t3_b2"])],
            "PostsByIds": [Self.posts([("t3_a1", 200, 10), ("t3_a2", 100, 10)]),
                           Self.posts([("t3_b1", 300, 20), ("t3_b2", 100, 10)])]
        ])
        defer { scenario.close() }
        let result = try await scenario.client(account: account).listing(
            ListingRequest(feed: FeedDescriptor(destination: .combined(["swift", "macos"]), sort: .top, topTime: .week), limit: 10), account: account)
        XCTAssertEqual(result.items.map(\.id), ["b1", "a1", "a2", "b2"])
        XCTAssertEqual(scenario.variables(for: "SubredditFeedSdui").compactMap { $0["sort"] as? String }, ["TOP", "TOP"])
        XCTAssertEqual(scenario.variables(for: "SubredditFeedSdui").compactMap { $0["time"] as? String }, ["WEEK", "WEEK"])
    }

    func testCombinedNewWaitsForSourceContinuationBeforeEmittingOlderPosts() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [Self.availableCommunity, Self.availableCommunity],
            "SubredditFeedSdui": [Self.continuingFeed(ids: ["t3_a1"]), Self.finalFeed(ids: ["t3_b1"]),
                                  Self.finalFeed(ids: ["t3_a2"])],
            "PostsByIds": [Self.posts([("t3_a1", 400, 0)]), Self.posts([("t3_b1", 100, 0)]),
                           Self.posts([("t3_a2", 300, 0)])]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let feed = FeedDescriptor(destination: .combined(["swift", "macos"]), sort: .new)
        let first = try await client.listing(ListingRequest(feed: feed, limit: 2), account: account)
        XCTAssertEqual(first.items.map(\.id), ["a1"])
        let second = try await client.listing(ListingRequest(feed: feed, limit: 2, after: XCTUnwrap(first.after)), account: account)
        XCTAssertEqual(second.items.map(\.id), ["a2", "b1"])
        XCTAssertNil(second.after)
        XCTAssertEqual(scenario.variables(for: "SubredditFeedSdui").last?["after"] as? String,
                       Data("t3_a1".utf8).base64EncodedString())
        scenario.assertOperations(["SubredditInfoByName": 2, "SubredditFeedSdui": 3, "PostsByIds": 3])
    }

    func testCombinedCursorRejectsOtherAccountDescriptorAndLimitWithoutRequests() async throws {
        let account = AccountID()
        let other = AccountID()
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [Self.availableCommunity, Self.availableCommunity],
            "SubredditFeedSdui": [Self.finalFeed(ids: ["t3_a1", "t3_a2"]),
                                  Self.finalFeed(ids: ["t3_b1", "t3_b2"])],
            "PostsByIds": [Self.posts(["t3_a1", "t3_a2"]), Self.posts(["t3_b1", "t3_b2"])]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account, additionalAccount: other)
        let feed = FeedDescriptor(destination: .combined(["swift", "macos"]), sort: .hot)
        let first = try await client.listing(ListingRequest(feed: feed, limit: 1), account: account)
        let cursor = try XCTUnwrap(first.after)
        let count = scenario.requests.count
        for (selected, descriptor, limit) in [
            (other, feed, 1),
            (account, FeedDescriptor(destination: .combined(["macos", "swift"]), sort: .hot), 1),
            (account, feed, 2)
        ] {
            do {
                _ = try await client.listing(ListingRequest(feed: descriptor, limit: limit, after: cursor), account: selected)
                XCTFail("Combined cursor escaped its original request")
            } catch { XCTAssertNotNil(error as? RedditClientError) }
            XCTAssertEqual(scenario.requests.count, count)
        }
    }

    func testCombinedPartialFailureStaysVisibleOnNextPageAndRefreshRetriesSource() async throws {
        let account = AccountID()
        let denied = #"{"data":{"subredditInfoByName":{"__typename":"Subreddit","forbiddenReason":"PRIVATE"}}}"#
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [Self.availableCommunity, denied, Self.availableCommunity, Self.availableCommunity],
            "SubredditFeedSdui": [Self.finalFeed(ids: ["t3_a1", "t3_a2"]),
                                  Self.finalFeed(ids: ["t3_a1"]),
                                  Self.finalFeed(ids: ["t3_b1"])],
            "PostsByIds": [Self.posts(["t3_a1", "t3_a2"]), Self.posts(["t3_a1"]), Self.posts(["t3_b1"])]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let feed = FeedDescriptor(destination: .combined(["swift", "denied"]), sort: .hot)
        let first = try await client.listing(ListingRequest(feed: feed, limit: 1), account: account)
        XCTAssertEqual(first.items.map(\.id), ["a1"])
        XCTAssertEqual(first.communityFailures.map(\.community), ["denied"])
        XCTAssertFalse(try XCTUnwrap(first.communityFailures.first).message.isEmpty)
        let next = try await client.listing(ListingRequest(feed: feed, limit: 1, after: XCTUnwrap(first.after)), account: account)
        XCTAssertEqual(next.items.map(\.id), ["a2"])
        XCTAssertEqual(next.communityFailures.map(\.community), ["denied"])
        XCTAssertNil(next.after)
        scenario.assertOperations(["SubredditInfoByName": 2, "SubredditFeedSdui": 1, "PostsByIds": 1])

        let refreshed = try await client.listing(ListingRequest(feed: feed, limit: 1,
            responseCachePolicy: .reloadIgnoringCache), account: account)
        XCTAssertTrue(refreshed.communityFailures.isEmpty)
        let recovered = try await client.listing(ListingRequest(feed: feed, limit: 1, after: XCTUnwrap(refreshed.after)), account: account)
        XCTAssertEqual(recovered.items.map(\.id), ["b1"])
        XCTAssertEqual(scenario.variables(for: "SubredditInfoByName").count, 4)
    }

    @MainActor
    func testCombinedEmptySourcePageKeepsManualContinuationUsable() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [Self.availableCommunity, Self.availableCommunity],
            "SubredditFeedSdui": [Self.continuingFeed(ids: [], after: "t3_emptypage"),
                                  Self.finalFeed(ids: ["t3_older"]),
                                  Self.finalFeed(ids: ["t3_newer"])],
            "PostsByIds": [Self.posts([("t3_older", 10, 1)]), Self.posts([("t3_newer", 20, 2)])]
        ])
        defer { scenario.close() }
        let store = OctonautFeatureStore(reddit: scenario.client(account: account))
        store.synchronizeAccount(id: account, generation: 1, accounts: [])
        store.selectedSort = .new
        let feed = CustomFeed(name: "Tech", communities: ["swift", "apple"]).descriptor
        await store.refreshPosts(for: feed)
        XCTAssertTrue(store.posts.isEmpty)
        XCTAssertEqual(store.feedState, .loaded)
        XCTAssertNotNil(store.galleryPageCursor(for: feed))
        await store.loadMorePosts(for: feed)
        XCTAssertEqual(store.posts.map(\.id), ["newer", "older"])
        XCTAssertNil(store.galleryPageCursor(for: feed))
        scenario.assertOperations(["SubredditInfoByName": 2, "SubredditFeedSdui": 3, "PostsByIds": 2])
    }

    func testCombinedAllSourcesFailThrowsInsteadOfShowingAnEmptyFeed() async throws {
        let account = AccountID()
        let denied = #"{"data":{"subredditInfoByName":{"__typename":"Subreddit","forbiddenReason":"PRIVATE"}}}"#
        let scenario = ReadMigrationScenario(["SubredditInfoByName": [denied, denied]])
        defer { scenario.close() }
        do {
            _ = try await scenario.client(account: account).listing(
                ListingRequest(feed: FeedDescriptor(destination: .combined(["swift", "macos"]))), account: account)
            XCTFail("All failed sources must fail the feed")
        } catch {
            XCTAssertNotNil(error as? RedditClientError)
        }
        scenario.assertOperations(["SubredditInfoByName": 2])
    }

    @MainActor
    func testStoreShowsPartialCommunityFailureAndClearsItOnAccountChange() async throws {
        let account = AccountID()
        let denied = #"{"data":{"subredditInfoByName":{"__typename":"Subreddit","forbiddenReason":"PRIVATE"}}}"#
        let scenario = ReadMigrationScenario([
            "SubredditInfoByName": [Self.availableCommunity, denied],
            "SubredditFeedSdui": [Self.finalFeed(ids: ["t3_first"])],
            "PostsByIds": [Self.posts(["t3_first"])]
        ])
        defer { scenario.close() }
        let store = OctonautFeatureStore(reddit: scenario.client(account: account))
        store.synchronizeAccount(id: account, generation: 1, accounts: [])
        await store.refreshPosts(for: CustomFeed(name: "Tech", communities: ["swift", "denied"]).descriptor)
        XCTAssertEqual(store.posts.map(\.id), ["first"])
        XCTAssertEqual(store.feedCommunityFailures.map(\.community), ["denied"])
        store.synchronizeAccount(id: nil, generation: 2, accounts: [])
        XCTAssertTrue(store.feedCommunityFailures.isEmpty)
    }

    func testFocusedPostAndTypedMorePageUseCommentsOperation() async throws {
        let account = AccountID()
        let commentPage = #"{"data":{"postInfoById":{"commentForest":{"trees":[{"depth":0,"node":{"__typename":"Comment","id":"t1_parent","content":{"richtext":{"document":[{"e":"par","c":[{"e":"text","t":"Parent text"}]}]}}}},{"depth":1,"more":{"cursor":"server-next","count":2}},{"depth":0,"node":{"__typename":"DeletedComment","id":"t1_gone","removedByCategory":"DELETED"}}]}}}}"#
        let nextPage = #"{"data":{"postInfoById":{"commentForest":{"trees":[{"depth":0,"node":{"__typename":"Comment","id":"t1_child","content":{"markdown":"Next child"}}}]}}}}"#
        let scenario = ReadMigrationScenario([
            "PostsByIds": [Self.posts(["t3_post"])],
            "SubredditInfoByName": [#"{"data":{"subredditInfoByName":{"__typename":"Subreddit"}}}"#],
            "PostComments": [commentPage, nextPage]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let url = try XCTUnwrap(URL(string: "https://www.reddit.com/r/swift/comments/post/title/parent/?context=3"))
        let thread = try await client.post(url, sort: .new, account: account)
        XCTAssertEqual(thread.post.id, "post")
        XCTAssertEqual(thread.comments.count, 2)
        guard case .comment(let parent) = thread.comments[0] else { return XCTFail("Missing parent") }
        XCTAssertEqual(parent.body?.plainText.trimmingCharacters(in: .whitespacesAndNewlines), "Parent text")
        guard case .more(let more) = try XCTUnwrap(parent.children.first) else { return XCTFail("Missing page") }
        guard case .page(let continuation) = more.continuation else { return XCTFail("Missing typed continuation") }
        guard case .deleted(let deleted) = thread.comments[1] else { return XCTFail("Missing deleted comment") }
        XCTAssertEqual(deleted.reason, "[deleted]")
        let firstVariables = try XCTUnwrap(scenario.variables(for: "PostComments").first)
        XCTAssertEqual(firstVariables["id"] as? String, "t3_post")
        XCTAssertEqual(firstVariables["sortType"] as? String, "NEW")
        let focus = try XCTUnwrap(firstVariables["focusedCommentContext"] as? [String: Any])
        XCTAssertEqual(focus["commentId"] as? String, "t1_parent")
        XCTAssertEqual(focus["minDeepCommentParents"] as? Int, 3)
        XCTAssertEqual(scenario.variables(for: "PostsByIds").first?["ids"] as? [String], ["t3_post"])
        do {
            _ = try await client.moreComments(postFullname: "t3_post", parentFullname: "t1_other",
                                              continuation: .page(continuation), sort: .new, account: account)
            XCTFail("A page cannot be used under another parent")
        } catch { XCTAssertEqual(error as? RedditClientError, .invalidURL) }
        scenario.assertOperations(["PostComments": 1, "PostsByIds": 1, "SubredditInfoByName": 1])
        let children = try await client.moreComments(postFullname: "t3_post", parentFullname: "t1_parent",
                                                     continuation: .page(continuation), sort: .new, account: account)
        guard case .comment(let child) = try XCTUnwrap(children.first) else { return XCTFail("Missing continued comment") }
        XCTAssertEqual(child.body?.plainText, "Next child")
        XCTAssertEqual(scenario.variables(for: "PostComments").last?["after"] as? String, "server-next")
        scenario.assertOperations(["PostComments": 2, "PostsByIds": 1, "SubredditInfoByName": 1])
    }

    func testMorePageRejectsAccountSortPostAndStaleSession() async throws {
        let account = AccountID()
        let other = AccountID()
        let scenario = ReadMigrationScenario([:])
        defer { scenario.close() }
        let client = scenario.client(account: account, additionalAccount: other)
        let accountJSON = String(decoding: try JSONEncoder().encode(account), as: UTF8.self)
        let sortJSON = String(decoding: try JSONEncoder().encode(CommentSort.new), as: UTF8.self)
        let tokenJSON = """
            {"cursor":"next","account":\(accountJSON),"postFullname":"t3_post","parentFullname":"t1_parent","sort":\(sortJSON),"sessionGeneration":"synthetic-generation","visitedCursors":["next"]}
            """
        let token = try JSONDecoder().decode(CommentPageToken.self, from: Data(tokenJSON.utf8))
        for (post, sort, selected) in [("t3_post", CommentSort.new, other),
                                      ("t3_other", .new, account),
                                      ("t3_post", .top, account)] {
            do {
                _ = try await client.moreComments(postFullname: post, parentFullname: "t1_parent",
                                                  continuation: .page(token), sort: sort, account: selected)
                XCTFail("Mismatched continuation must fail")
            } catch { XCTAssertEqual(error as? RedditClientError, .invalidURL) }
        }
        // A typed token is tied to a session generation as well.
        do {
            _ = try await client.moreComments(postFullname: "t3_post", parentFullname: "t1_parent",
                                              continuation: .page(token), sort: .new, account: account)
            XCTFail("A stale continuation must fail")
        } catch { XCTAssertEqual(error as? RedditClientError, .authenticationRequired) }
        XCTAssertTrue(scenario.requests.isEmpty)
    }

    func testSubmittedPostsHydrateAndKeepProfileCursorScoped() async throws {
        let account = AccountID()
        let page = #"{"data":{"profileFeed":{"elements":{"edges":[{"node":{"groupId":"t3_first"}},{"node":{"groupId":"t3_second"}}],"pageInfo":{"hasNextPage":true,"endCursor":"profile-next"}}}}}"#
        let empty = #"{"data":{"profileFeed":{"elements":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        let scenario = ReadMigrationScenario([
            "SubmittedPostsFeedSdui": [page, empty],
            "PostsByIds": [Self.posts(["t3_second", "t3_first"])]
        ])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let feed = FeedDescriptor(destination: .user(username: "reader", section: .submitted))
        let first = try await client.listing(ListingRequest(feed: feed), account: account)
        XCTAssertEqual(first.items.map(\.id), ["first", "second"])
        let cursor = try XCTUnwrap(first.after)
        let last = try await client.listing(ListingRequest(feed: feed, after: cursor), account: account)
        XCTAssertTrue(last.items.isEmpty)
        XCTAssertNil(last.after)
        XCTAssertEqual(scenario.variables(for: "SubmittedPostsFeedSdui").last?["after"] as? String, "profile-next")
        XCTAssertEqual(scenario.variables(for: "PostsByIds").first?["ids"] as? [String], ["t3_first", "t3_second"])
        do {
            _ = try await client.listing(ListingRequest(feed: FeedDescriptor(destination: .user(username: "other", section: .submitted)), after: cursor), account: account)
            XCTFail("A profile cursor cannot be reused for another user")
        } catch { XCTAssertEqual(error as? RedditClientError, .invalidResponse) }
        scenario.assertOperations(["SubmittedPostsFeedSdui": 2, "PostsByIds": 1])
    }

    func testSubscriptionsKeepIndependentCursors() async throws {
        let account = AccountID()
        let first = #"{"data":{"identity":{"subscribedSubredditInfos":{"edges":[{"node":{"__typename":"Subreddit","name":"swift"}}],"pageInfo":{"hasNextPage":true,"endCursor":"sub-next"}},"followedRedditorsInfo":{"edges":[{"node":{"profile":{"redditorInfo":{"prefixedName":"u/reader"}}}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        let second = #"{"data":{"identity":{"subscribedSubredditInfos":{"edges":[{"node":{"__typename":"Subreddit","name":"ios"}}],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}"#
        let scenario = ReadMigrationScenario(["UserSubreddits": [first, second]])
        defer { scenario.close() }
        let client = scenario.client(account: account)
        let page = try await client.subscribedCommunities(after: nil, account: account)
        XCTAssertEqual(page.items.map(\.reference.name), ["swift", "u_reader"])
        let cursor = try XCTUnwrap(page.after)
        let next = try await client.subscribedCommunities(after: cursor, account: account)
        XCTAssertEqual(next.items.map(\.reference.name), ["ios"])
        XCTAssertNil(next.after)
        let variables = try XCTUnwrap(scenario.variables(for: "UserSubreddits").last)
        XCTAssertEqual(variables["subscribedAfter"] as? String, "sub-next")
        XCTAssertEqual(variables["fetchSubscribed"] as? Bool, true)
        XCTAssertEqual(variables["fetchFollowed"] as? Bool, false)
        XCTAssertTrue(variables["followedAfter"] is NSNull)
        scenario.assertOperations(["UserSubreddits": 2])
    }

    func testPrivateProfileOfOtherUserDoesNotFetchSection() async throws {
        let account = AccountID()
        let scenario = ReadMigrationScenario([:])
        defer { scenario.close() }
        let client = scenario.client(account: account, username: "reader")
        let posts = try await client.listing(ListingRequest(feed: FeedDescriptor(destination: .user(username: "other", section: .saved))), account: account)
        let comments = try await client.userComments("other", section: .saved, after: nil, account: account)
        XCTAssertTrue(posts.items.isEmpty)
        XCTAssertTrue(comments.items.isEmpty)
        XCTAssertTrue(scenario.requests.isEmpty)
    }

    private static let availableCommunity = #"{"data":{"subredditInfoByName":{"__typename":"Subreddit"}}}"#

    private static func feed(_ field: String, ids: [String]) -> String {
        let edges = ids.map { #"{"node":{"groupId":"\#($0)"}}"# }.joined(separator: ",")
        return #"{"data":{"\#(field)":{"elements":{"edges":[\#(edges)]}}}}"#
    }

    private static func finalFeed(ids: [String]) -> String {
        let edges = ids.map { #"{"node":{"groupId":"\#($0)"}}"# }.joined(separator: ",")
        return #"{"data":{"subredditFeed":{"elements":{"edges":[\#(edges)],"pageInfo":{"hasNextPage":false}}}}}"#
    }

    private static func continuingFeed(ids: [String], after: String? = nil) -> String {
        let edges = ids.map { #"{"node":{"groupId":"\#($0)"}}"# }.joined(separator: ",")
        let cursor = Data((after ?? ids.last ?? "").utf8).base64EncodedString()
        return #"{"data":{"subredditFeed":{"elements":{"edges":[\#(edges)],"pageInfo":{"hasNextPage":true,"endCursor":"\#(cursor)"}}}}}"#
    }

    private static func posts(_ ids: [String]) -> String {
        let values = ids.map { id in
            let short = String(id.dropFirst(3))
            return #"{"__typename":"SubredditPost","id":"\#(id)","postTitle":"\#(short)","permalink":"/r/swift/comments/\#(short)/","subreddit":{"name":"swift"}}"#
        }.joined(separator: ",")
        return #"{"data":{"postsInfoByIds":[\#(values)]}}"#
    }

    private static func posts(_ values: [(String, Int, Int)]) -> String {
        let nodes = values.map { id, date, score in
            let short = String(id.dropFirst(3))
            return #"{"__typename":"SubredditPost","id":"\#(id)","postTitle":"\#(short)","permalink":"/r/swift/comments/\#(short)/","subreddit":{"name":"swift"},"createdAt":"1970-01-01T00:\#(String(format: "%02d", date / 60)):\#(String(format: "%02d", date % 60))Z","score":\#(score)}"#
        }.joined(separator: ",")
        return #"{"data":{"postsInfoByIds":[\#(nodes)]}}"#
    }
}

private final class ReadMigrationScenario: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private var responses: [String: [String]]
    private var captured: [URLRequest] = []
    private let token = "synthetic-read-token"

    init(_ responses: [String: [String]]) {
        self.responses = responses
        ReadMigrationURLProtocol.register(self)
    }

    var requests: [URLRequest] { lock.withLock { captured } }

    func client(account: AccountID, additionalAccount: AccountID? = nil, username: String = "reader") -> URLSessionRedditClient {
        let saved = WebGraphQLToken(value: token, sourceSessionDigest: RedditSessionIdentity.digest("synthetic-session"),
                                    expiresAt: .now.addingTimeInterval(3600))
        let credential = RedditCredential(cookieValue: "synthetic-session", redditUser: username, webGraphQLToken: saved)
        var values = [account: credential]
        if let additionalAccount { values[additionalAccount] = credential }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReadMigrationURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Octonaut-Read-Test": id]
        return URLSessionRedditClient(credentialVault: InMemoryCredentialVault(values: values), sessionConfiguration: configuration)
    }

    func response(to request: URLRequest) -> String {
        let payload = try? Self.payload(request)
        let operation = payload?["operationName"] as? String ?? ""
        return lock.withLock {
            captured.append(request)
            XCTAssertEqual(request.url?.absoluteString, "https://cf.gql-fed.reddit.com/")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Modhash"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertNotNil(payload?["extensions"])
            guard var available = responses[operation], !available.isEmpty else {
                XCTFail("Unexpected operation \(operation)")
                return "{}"
            }
            let response = available.removeFirst()
            responses[operation] = available
            return response
        }
    }

    func variables(for operation: String) -> [[String: Any]] {
        requests.compactMap { request in
            guard let payload = try? Self.payload(request), payload["operationName"] as? String == operation else { return nil }
            return payload["variables"] as? [String: Any]
        }
    }

    func assertOperations(_ expected: [String: Int], file: StaticString = #filePath, line: UInt = #line) {
        let operations = requests.compactMap { (try? Self.payload($0))?["operationName"] as? String }
        XCTAssertEqual(operations.count, expected.values.reduce(0, +), file: file, line: line)
        for (name, count) in expected { XCTAssertEqual(operations.filter { $0 == name }.count, count, file: file, line: line) }
    }

    func close() { ReadMigrationURLProtocol.remove(id) }

    private static func payload(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var result = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                result.append(buffer, count: count)
            }
            data = result
        } else { throw RedditClientError.malformedResponse }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class ReadMigrationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenarios: [String: ReadMigrationScenario] = [:]

    static func register(_ scenario: ReadMigrationScenario) { lock.withLock { scenarios[scenario.id] = scenario } }
    static func remove(_ id: String) { _ = lock.withLock { scenarios.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scenario = Self.lock.withLock({ Self.scenarios[request.value(forHTTPHeaderField: "X-Octonaut-Read-Test") ?? ""] }),
              let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            captured.httpBody = body
        }
        let body = scenario.response(to: captured)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
