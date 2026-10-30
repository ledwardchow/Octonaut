import Foundation
import XCTest
@testable import Octonaut

final class RedditGraphQLTransportTests: XCTestCase {
    func testSignedOutFeedAndSearchNeverSendRequests() async throws {
        let scenario = GraphQLScenario([])
        defer { scenario.close() }
        let client = scenario.client(vault: InMemoryCredentialVault())
        let account = AccountID()
        for accountID in [nil, account] {
            do {
                _ = try await client.listing(ListingRequest(feed: FeedDescriptor(destination: .all)), account: accountID)
                XCTFail("An account with a saved website session is required")
            } catch {
                XCTAssertEqual(error as? RedditClientError, accountID == nil ? .anonymousAccessBlocked : .authenticationRequired)
            }
            do {
                _ = try await client.search(RedditSearchRequest(query: "swift"), account: accountID)
                XCTFail("Search needs a saved website session")
            } catch {
                XCTAssertEqual(error as? RedditClientError, accountID == nil ? .anonymousAccessBlocked : .authenticationRequired)
            }
        }
        XCTAssertTrue(scenario.requests.isEmpty)
    }

    func testSearchBootstrapsWebsiteTokenAndReusesItWithoutLeakingCookies() async throws {
        let account = AccountID()
        let token = Self.token("first")
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: token),
            .graphql("SearchPosts", token: token, json: Self.emptyPostSearch),
            .graphql("SearchPosts", token: token, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")])
        let client = scenario.client(vault: vault)
        let request = RedditSearchRequest(query: "C++ & a=b", community: "r/all", sort: .top, timeRange: .week, limit: 17)
        let result = try await client.search(request, account: account)
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertNil(result.after)
        _ = try await client.search(request, account: account)
        XCTAssertEqual(scenario.requests.count, 4)
        let payload = try Self.payload(scenario.requests[2])
        let variables = try XCTUnwrap(payload["variables"] as? [String: Any])
        XCTAssertEqual(variables["query"] as? String, "C++ & a=b")
        XCTAssertEqual(variables["sort"] as? String, "TOP")
        XCTAssertEqual(variables["pageSize"] as? Int, 17)
        XCTAssertNil(variables["afterCursor"])
        let filters = try XCTUnwrap(variables["filters"] as? [[String: String]])
        XCTAssertEqual(filters, [["key": "time_range", "value": "week"]])
        let extensions = try XCTUnwrap(payload["extensions"] as? [String: Any])
        let persisted = try XCTUnwrap(extensions["persistedQuery"] as? [String: Any])
        XCTAssertEqual(persisted["version"] as? Int, 1)
        XCTAssertEqual(persisted["sha256Hash"] as? String, "c3d31b88bfa15180fdcd0c8f6f13b8c0e131d0c981c9b9c8a7c537ddd0ed3348")
        scenario.assertFinished()
    }

    func testAllFeedUsesFeedIDsAndEncodesPaginationCursor() async throws {
        let account = AccountID()
        let token = Self.token("feed")
        let feed = #"{"data":{"allFeed":{"elements":{"edges":[{"node":{"groupId":"t3_first"}},{"node":{"id":"t3_ad","adPayload":{}}},{"node":{"id":"t3_second"}}]}}}}"#
        let posts = #"{"data":{"postsInfoByIds":[{"__typename":"SubredditPost","id":"t3_second","postTitle":"Second","permalink":"/r/swift/comments/second/","subreddit":{"name":"swift"}},{"__typename":"SubredditPost","id":"t3_first","postTitle":"First","permalink":"/r/swift/comments/first/","subreddit":{"name":"swift"}}]}}"#
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: token),
            .graphql("AllFeedSdui", token: token, json: feed),
            .graphql("PostsByIds", token: token, json: posts),
            .graphql("AllFeedSdui", token: token, json: #"{"data":{"allFeed":{"elements":{"edges":[]}}}}"#)
        ])
        defer { scenario.close() }
        let client = scenario.client(vault: InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")]))
        let feedRequest = ListingRequest(feed: FeedDescriptor(destination: .all))
        let first = try await client.listing(feedRequest, account: account)
        XCTAssertEqual(first.items.map(\.id), ["first", "second"])
        XCTAssertNotNil(first.after)
        XCTAssertNotEqual(first.after, "t3_second")
        var next = feedRequest
        next.after = first.after
        let last = try await client.listing(next, account: account)
        XCTAssertTrue(last.items.isEmpty)
        XCTAssertNil(last.after)
        let hydration = try Self.payload(scenario.requests[3])["variables"] as? [String: Any]
        XCTAssertEqual(hydration?["ids"] as? [String], ["t3_first", "t3_second"])
        let pagination = try Self.payload(scenario.requests[4])["variables"] as? [String: Any]
        XCTAssertEqual(pagination?["after"] as? String, Data("t3_second".utf8).base64EncodedString())
        scenario.assertFinished()
    }

    func testCommunityAndUserSearchUseNewOperations() async throws {
        let account = AccountID()
        let token = Self.token("scopes")
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: token),
            .graphql("CommunityPickerSearchPaginated", token: token, json: #"{"data":{"search":{"general":{"communities":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#),
            .graphql("SearchPeople", token: token, json: #"{"data":{"search":{"general":{"authors":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#)
        ])
        defer { scenario.close() }
        let client = scenario.client(vault: InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")]))
        _ = try await client.communities(RedditCommunitySearchRequest(query: "/r/sw", limit: 9), account: account)
        _ = try await client.users(RedditUserSearchRequest(query: "reader", limit: 12), account: account)
        let communities = try Self.payload(scenario.requests[2])["variables"] as? [String: Any]
        XCTAssertEqual(communities?["query"] as? String, "sw")
        XCTAssertEqual(communities?["first"] as? Int, 9)
        XCTAssertNil(communities?["after"])
        let users = try Self.payload(scenario.requests[3])["variables"] as? [String: Any]
        XCTAssertEqual(users?["query"] as? String, "reader")
        XCTAssertEqual(users?["pageSize"] as? Int, 12)
        scenario.assertFinished()
    }

    func testSearchCursorBindsAccountSessionAndQueryBeforeRequest() async throws {
        let account = AccountID()
        let other = AccountID()
        let token = Self.token("search-pages")
        let firstPage = #"{"data":{"search":{"general":{"posts":{"edges":[{"node":{"__typename":"SubredditPost","id":"t3_first","postTitle":"First","subreddit":{"name":"swift"}}}],"pageInfo":{"hasNextPage":true,"endCursor":"server-one"}}}}}}"#
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: token),
            .graphql("SearchPosts", token: token, json: firstPage),
            .graphql("SearchPosts", token: token, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let vault = InMemoryCredentialVault(values: [
            account: RedditCredential(cookieValue: "session-A"), other: RedditCredential(cookieValue: "session-B")
        ])
        let client = scenario.client(vault: vault)
        let request = RedditSearchRequest(query: "swift", community: "r/iOS", sort: .top, timeRange: .week)
        let first = try await client.search(request, account: account)
        XCTAssertEqual(first.items.map(\.id), ["first"])
        let cursor = try XCTUnwrap(first.after)
        XCTAssertNotEqual(cursor, "server-one")
        var next = request
        next.after = cursor
        var changed = next
        changed.query = "other"
        await assertRejectedSearchPage(client, request: changed, account: account)
        changed = next
        changed.community = "r/other"
        await assertRejectedSearchPage(client, request: changed, account: account)
        changed = next
        changed.sort = .new
        await assertRejectedSearchPage(client, request: changed, account: account)
        changed = next
        changed.timeRange = .day
        await assertRejectedSearchPage(client, request: changed, account: account)
        await assertRejectedSearchPage(client, request: next, account: other)
        XCTAssertEqual(scenario.requests.count, 3)
        let last = try await client.search(next, account: account)
        XCTAssertTrue(last.items.isEmpty)
        XCTAssertNil(last.after)
        let variables = try Self.payload(scenario.requests[3])["variables"] as? [String: Any]
        XCTAssertEqual(variables?["afterCursor"] as? String, "server-one")
        try await vault.save(RedditCredential(cookieValue: "session-replaced"), for: account)
        await assertRejectedSearchPage(client, request: next, account: account)
        XCTAssertEqual(scenario.requests.count, 4)
        scenario.assertFinished()
    }

    private func assertRejectedSearchPage(_ client: URLSessionRedditClient, request: RedditSearchRequest,
                                          account: AccountID) async {
        do {
            _ = try await client.search(request, account: account)
            XCTFail("A search cursor cannot be used in another scope")
        } catch {
            XCTAssertEqual(error as? RedditClientError, .http(statusCode: 400, message: "This Reddit sort or page direction is unavailable."))
        }
    }

    func testCommunitySearchCursorUsesNormalizedQuery() async throws {
        let account = AccountID()
        let token = Self.token("community-pages")
        let firstPage = #"{"data":{"search":{"general":{"communities":{"edges":[{"node":{"__typename":"Subreddit","name":"swift"}}],"pageInfo":{"hasNextPage":true,"endCursor":"community-one"}}}}}}"#
        let lastPage = #"{"data":{"search":{"general":{"communities":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: token),
            .graphql("CommunityPickerSearchPaginated", token: token, json: firstPage),
            .graphql("CommunityPickerSearchPaginated", token: token, json: lastPage)
        ])
        defer { scenario.close() }
        let client = scenario.client(vault: InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")]))
        let first = try await client.communities(RedditCommunitySearchRequest(query: "/r/sw"), account: account)
        XCTAssertEqual(first.items.count, 1)
        let cursor = try XCTUnwrap(first.after)
        XCTAssertNotEqual(cursor, "community-one")
        let last = try await client.communities(RedditCommunitySearchRequest(query: "r/SW", after: cursor), account: account)
        XCTAssertTrue(last.items.isEmpty)
        let variables = try Self.payload(scenario.requests[3])["variables"] as? [String: Any]
        XCTAssertEqual(variables?["after"] as? String, "community-one")
        scenario.assertFinished()
    }

    func testSearchSkipsThreeEmptyPagesAndPreservesContinuation() async throws {
        let account = AccountID()
        let token = Self.token("empty-pages")
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: token),
            .graphql("SearchPosts", token: token, json: Self.emptySearchPage(after: "one")),
            .graphql("SearchPosts", token: token, json: Self.emptySearchPage(after: "two")),
            .graphql("SearchPosts", token: token, json: Self.emptySearchPage(after: "three")),
            .graphql("SearchPosts", token: token, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let client = scenario.client(vault: InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")]))
        let first = try await client.search(RedditSearchRequest(query: "swift"), account: account)
        XCTAssertTrue(first.items.isEmpty)
        let cursor = try XCTUnwrap(first.after)
        XCTAssertNotEqual(cursor, "three")
        let second = try await client.search(RedditSearchRequest(query: "swift", after: cursor), account: account)
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertNil(second.after)
        for (index, expected) in [(3, "one"), (4, "two"), (5, "three")] {
            let variables = try Self.payload(scenario.requests[index])["variables"] as? [String: Any]
            XCTAssertEqual(variables?["afterCursor"] as? String, expected)
        }
        scenario.assertFinished()
    }

    func testSearchStopsWhenServerRepeatsCursor() async throws {
        let account = AccountID()
        let token = Self.token("repeat")
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: token),
            .graphql("SearchPosts", token: token, json: Self.emptySearchPage(after: "one")),
            .graphql("SearchPosts", token: token, json: Self.emptySearchPage(after: "one"))
        ])
        defer { scenario.close() }
        let client = scenario.client(vault: InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")]))
        let listing = try await client.search(RedditSearchRequest(query: "swift"), account: account)
        XCTAssertTrue(listing.items.isEmpty)
        XCTAssertNil(listing.after)
        scenario.assertFinished()
    }

    private static func emptySearchPage(after: String) -> String {
        #"{"data":{"search":{"general":{"posts":{"edges":[],"pageInfo":{"hasNextPage":true,"endCursor":"\#(after)"}}}}}}"#
    }

    func testAccountTokensStaySeparateAndLogoutPreventsReuse() async throws {
        let first = AccountID()
        let second = AccountID()
        let tokenA = Self.token("A")
        let tokenB = Self.token("B")
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: tokenA),
            .graphql("SearchPosts", token: tokenA, json: Self.emptyPostSearch),
            .prime(session: "session-B"), .mint(session: "session-B", token: tokenB),
            .graphql("SearchPosts", token: tokenB, json: Self.emptyPostSearch),
            .graphql("SearchPosts", token: tokenA, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let vault = InMemoryCredentialVault(values: [
            first: RedditCredential(cookieValue: "session-A"), second: RedditCredential(cookieValue: "session-B")
        ])
        let client = scenario.client(vault: vault)
        for account in [first, second, first] {
            _ = try await client.search(RedditSearchRequest(query: "swift"), account: account)
        }
        try await vault.removeCredential(for: first)
        do {
            _ = try await client.search(RedditSearchRequest(query: "swift"), account: first)
            XCTFail("A cached token must not survive logout")
        } catch { XCTAssertEqual(error as? RedditClientError, .authenticationRequired) }
        scenario.assertFinished()
    }

    func testRateLimitAndGraphQLErrorsDoNotExposeResponseSecrets() async throws {
        for reply in [
            GraphQLReply(status: 429, headers: ["Retry-After": "7"], json: ""),
            GraphQLReply(status: 200, json: #"{"errors":[{"message":"private-response-secret"}],"data":null}"#),
            GraphQLReply(status: 200, json: "<html>private-response-secret</html>")
        ] {
            let account = AccountID()
            let token = Self.token("failure")
            let scenario = GraphQLScenario([.prime(session: "session-A"), .mint(session: "session-A", token: token), reply])
            defer { scenario.close() }
            let client = scenario.client(vault: InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")]))
            do {
                _ = try await client.search(RedditSearchRequest(query: "swift"), account: account)
                XCTFail("An invalid response must fail")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("private-response-secret"))
                if reply.status == 429 {
                    XCTAssertEqual(error as? RedditClientError, .rateLimited(retryAfter: 7))
                }
            }
            scenario.assertFinished()
        }
    }

    private static let emptyPostSearch = #"{"data":{"search":{"general":{"posts":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}"#

    func testRejectedSavedTokenRefreshesOnce() async throws {
        let account = AccountID()
        let oldValue = Self.token("old")
        let newValue = Self.token("new")
        let saved = WebGraphQLToken(value: oldValue, sourceSessionDigest: RedditSessionIdentity.digest("session-A"), expiresAt: .now.addingTimeInterval(3600))
        let scenario = GraphQLScenario([
            GraphQLReply(status: 403, json: "blocked"),
            .prime(session: "session-A"), .mint(session: "session-A", token: newValue),
            .graphql("SearchPosts", token: newValue, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A", webGraphQLToken: saved)])
        _ = try await scenario.client(vault: vault).search(RedditSearchRequest(query: "swift"), account: account)
        XCTAssertEqual(scenario.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(oldValue)")
        let current = try await vault.credential(for: account)
        XCTAssertEqual(current?.webGraphQLToken?.value, newValue)
        scenario.assertFinished()
    }

    func testExpiredSavedTokenIsRefreshedBeforeSearch() async throws {
        let account = AccountID()
        let value = Self.token("new")
        let expired = WebGraphQLToken(value: Self.token("expired"), sourceSessionDigest: RedditSessionIdentity.digest("session-A"), expiresAt: .now.addingTimeInterval(-1))
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: value),
            .graphql("SearchPosts", token: value, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A", webGraphQLToken: expired)])
        _ = try await scenario.client(vault: vault).search(RedditSearchRequest(query: "swift"), account: account)
        scenario.assertFinished()
    }

    func testConcurrentSearchesShareTokenRefresh() async throws {
        let account = AccountID()
        let value = Self.token("shared")
        let scenario = GraphQLScenario([
            .prime(session: "session-A"), .mint(session: "session-A", token: value),
            .graphql("SearchPosts", token: value, json: Self.emptyPostSearch),
            .graphql("SearchPosts", token: value, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let client = scenario.client(vault: InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")]))
        async let first = client.search(RedditSearchRequest(query: "swift"), account: account)
        async let second = client.search(RedditSearchRequest(query: "ios"), account: account)
        _ = try await (first, second)
        scenario.assertFinished()
    }

    func testLateTokenCannotRestoreDeletedOrReplacedSession() async throws {
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")])
        let token = WebGraphQLToken(value: Self.token("late"), sourceSessionDigest: RedditSessionIdentity.digest("session-A"), expiresAt: .now.addingTimeInterval(3600))
        try await vault.removeCredential(for: account)
        let savedAfterLogout = try await vault.saveWebGraphQLToken(token, for: account)
        XCTAssertFalse(savedAfterLogout)
        let removed = try await vault.credential(for: account)
        XCTAssertNil(removed)
        try await vault.save(RedditCredential(cookieValue: "session-B"), for: account)
        let savedAfterReplacement = try await vault.saveWebGraphQLToken(token, for: account)
        XCTAssertFalse(savedAfterReplacement)
        let replacement = try await vault.credential(for: account)
        XCTAssertEqual(replacement?.cookieValue, "session-B")
        XCTAssertNil(replacement?.webGraphQLToken)
    }

    func testOldCredentialsDecodeWithoutGraphQLToken() throws {
        let credential = try JSONDecoder().decode(RedditCredential.self, from: Data(#"{"cookieName":"reddit_session","cookieValue":"synthetic"}"#.utf8))
        XCTAssertEqual(credential.cookieValue, "synthetic")
        XCTAssertNil(credential.webGraphQLToken)
    }

    func testModhashUpdateCannotOverwriteRenewedSessionOrToken() async throws {
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A", modhash: "original")])
        let rotated = try await vault.replaceSessionCookie("session-B", expected: "session-A", for: account)
        XCTAssertTrue(rotated)
        let token = WebGraphQLToken(value: Self.token("current"), sourceSessionDigest: RedditSessionIdentity.digest("session-B"), expiresAt: .now.addingTimeInterval(3600))
        let tokenSaved = try await vault.saveWebGraphQLToken(token, for: account)
        XCTAssertTrue(tokenSaved)
        let staleUpdate = try await vault.updateModhash("stale", expectedSession: "session-A", for: account)
        XCTAssertFalse(staleUpdate)
        let currentUpdate = try await vault.updateModhash("current", expectedSession: "session-B", for: account)
        XCTAssertTrue(currentUpdate)
        let credential = try await vault.credential(for: account)
        XCTAssertEqual(credential?.cookieValue, "session-B")
        XCTAssertEqual(credential?.modhash, "current")
        XCTAssertEqual(credential?.webGraphQLToken, token)
        try await vault.removeCredential(for: account)
        let removedUpdate = try await vault.updateModhash("late", expectedSession: "session-B", for: account)
        XCTAssertFalse(removedUpdate)
    }

    func testIdentityResponseFromReplacedSessionCannotUpdateModhash() async throws {
        let account = AccountID()
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A", modhash: "old-modhash", redditUser: "reader")])
        let identity = GraphQLReply(json: #"{"data":{"name":"reader","modhash":"old-session-response"}}"#, beforeReply: {
            try? await vault.save(RedditCredential(cookieValue: "session-B", modhash: "new-session-modhash", redditUser: "reader"), for: account)
        })
        let scenario = GraphQLScenario([GraphQLReply(status: 403, json: "{}"), identity])
        defer { scenario.close() }
        do {
            _ = try await scenario.client(vault: vault).perform(.vote(fullname: "t3_post", direction: 1), account: account)
            XCTFail("The original mutation must not retry after its session was replaced")
        } catch { XCTAssertEqual(error as? RedditClientError, .accessDenied) }
        let credential = try await vault.credential(for: account)
        XCTAssertEqual(credential?.cookieValue, "session-B")
        XCTAssertEqual(credential?.modhash, "new-session-modhash")
        scenario.assertFinished()
    }

    func testBootstrapUsesRenewedWebsiteSessionAndPersistsIt() async throws {
        let account = AccountID()
        let value = Self.token("renewed")
        let head = GraphQLReply(headers: ["Set-Cookie": "reddit_session=session-A-renewed; Path=/; Secure; HttpOnly, csrf_token=synthetic-csrf; Path=/; Secure"], json: "", check: { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=session-A")
        })
        let scenario = GraphQLScenario([
            head, .mint(session: "session-A-renewed", token: value),
            .graphql("SearchPosts", token: value, json: Self.emptyPostSearch),
            .graphql("SearchPosts", token: value, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A", modhash: "existing-modhash")])
        _ = try await scenario.client(vault: vault).search(RedditSearchRequest(query: "swift"), account: account)
        let saved = try await vault.credential(for: account)
        XCTAssertEqual(saved?.cookieValue, "session-A-renewed")
        XCTAssertEqual(saved?.modhash, "existing-modhash")
        XCTAssertEqual(saved?.webGraphQLToken?.sourceSessionDigest, RedditSessionIdentity.digest("session-A-renewed"))
        _ = try await scenario.client(vault: vault).search(RedditSearchRequest(query: "ios"), account: account)
        scenario.assertFinished()
    }

    func testCookieRenewalKeepsGenerationDuringVaultWrite() async throws {
        let account = AccountID()
        let value = Self.token("renewal-race")
        let head = GraphQLReply(
            headers: ["Set-Cookie": "reddit_session=session-B; Path=/; Secure; HttpOnly, csrf_token=synthetic-csrf; Path=/; Secure"],
            json: "",
            check: { request in
                XCTAssertEqual(request.httpMethod, "HEAD")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=session-A")
            }
        )
        let scenario = GraphQLScenario([
            head,
            .mint(session: "session-B", token: value),
            .graphql("SearchPosts", token: value, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let vault = ObservingCookieReplacementVault(account: account, cookie: "session-A")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphQLRequestProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Octonaut-Test": scenario.id]
        let graphQL = RedditGraphQLClient(credentialVault: vault, sessionConfiguration: configuration)
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration, graphQL: graphQL)
        let originalGeneration = try await graphQL.sessionGeneration(for: account)
        await vault.observeCookieReplacement { try await graphQL.sessionGeneration(for: account) }

        let result = try await client.search(RedditSearchRequest(query: "swift"), account: account)

        XCTAssertTrue(result.items.isEmpty)
        let generationDuringWrite = await vault.generationDuringWrite()
        XCTAssertEqual(generationDuringWrite, originalGeneration)
        let saved = try await vault.credential(for: account)
        XCTAssertEqual(saved?.cookieValue, "session-B")
        XCTAssertEqual(saved?.webGraphQLToken?.value, value)
        XCTAssertEqual(saved?.webGraphQLToken?.sourceSessionDigest, RedditSessionIdentity.digest("session-B"))
        scenario.assertFinished()
    }

    func testRedirectResponsesStopBeforeSendingCredentialsElsewhere() async throws {
        for hop in 0..<3 {
            let account = AccountID()
            let value = Self.token("redirect")
            var replies: [GraphQLReply] = [.prime(session: "session-A"), .mint(session: "session-A", token: value)]
            let redirect = GraphQLReply(status: 302, headers: ["Location": "https://example.com/"], json: "")
            if hop < replies.count { replies = Array(replies.prefix(hop)) + [redirect] }
            else { replies.append(redirect) }
            let scenario = GraphQLScenario(replies)
            defer { scenario.close() }
            let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")])
            do {
                _ = try await scenario.client(vault: vault).search(RedditSearchRequest(query: "swift"), account: account)
                XCTFail("A redirect must fail")
            } catch { XCTAssertEqual(error as? RedditClientError, .invalidResponse) }
            XCTAssertTrue(scenario.requests.allSatisfy { ["www.reddit.com", "cf.gql-fed.reddit.com"].contains($0.url?.host ?? "") })
            scenario.assertFinished()
        }
    }

    func testRejectedTokenAfterSessionRenewalRefreshesCurrentSession() async throws {
        let account = AccountID()
        let oldValue = Self.token("renewed-first")
        let newValue = Self.token("renewed-retry")
        let head = GraphQLReply(headers: ["Set-Cookie": "reddit_session=session-A-renewed; Path=/; Secure, csrf_token=synthetic-csrf; Path=/; Secure"], json: "")
        let scenario = GraphQLScenario([
            head, .mint(session: "session-A-renewed", token: oldValue), GraphQLReply(status: 401, json: "{}"),
            .prime(session: "session-A-renewed"), .mint(session: "session-A-renewed", token: newValue),
            .graphql("SearchPosts", token: newValue, json: Self.emptyPostSearch)
        ])
        defer { scenario.close() }
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "session-A")])
        _ = try await scenario.client(vault: vault).search(RedditSearchRequest(query: "swift"), account: account)
        let credential = try await vault.credential(for: account)
        XCTAssertEqual(credential?.webGraphQLToken?.value, newValue)
        scenario.assertFinished()
    }

    private static func token(_ marker: String, expires: TimeInterval = Date.now.timeIntervalSince1970 + 3600) -> String {
        let data = Data("{\"exp\":\(Int(expires)),\"marker\":\"\(marker)\"}".utf8)
        let payload = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "synthetic.\(payload).signature"
    }

    private static func payload(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody { data = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            data = body
        } else { throw RedditClientError.malformedResponse }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private actor ObservingCookieReplacementVault: AccountCredentialVault {
    private let backing: InMemoryCredentialVault
    private var observer: (@Sendable () async throws -> String)?
    private var observedGeneration: String?

    init(account: AccountID, cookie: String) {
        backing = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: cookie)])
    }

    func observeCookieReplacement(_ observer: @escaping @Sendable () async throws -> String) {
        self.observer = observer
    }

    func generationDuringWrite() -> String? { observedGeneration }

    func credential(for accountID: AccountID) async throws -> RedditCredential? {
        try await backing.credential(for: accountID)
    }

    func save(_ credential: RedditCredential, for accountID: AccountID) async throws {
        try await backing.save(credential, for: accountID)
    }

    func removeCredential(for accountID: AccountID) async throws {
        try await backing.removeCredential(for: accountID)
    }

    func removeAllCredentials() async throws {
        try await backing.removeAllCredentials()
    }

    func saveWebGraphQLToken(_ token: WebGraphQLToken, for accountID: AccountID) async throws -> Bool {
        try await backing.saveWebGraphQLToken(token, for: accountID)
    }

    func replaceSessionCookie(_ newValue: String, expected oldValue: String, for accountID: AccountID) async throws -> Bool {
        let replaced = try await backing.replaceSessionCookie(newValue, expected: oldValue, for: accountID)
        if replaced, let observer {
            observedGeneration = try await observer()
        }
        return replaced
    }

    func updateModhash(_ modhash: String, expectedSession: String, for accountID: AccountID) async throws -> Bool {
        try await backing.updateModhash(modhash, expectedSession: expectedSession, for: accountID)
    }
}

private struct GraphQLReply: Sendable {
    var status = 200
    var headers: [String: String] = [:]
    var json: String
    var beforeReply: (@Sendable () async -> Void)?
    var check: (@Sendable (URLRequest) -> Void)?

    static func prime(session: String) -> Self {
        Self(headers: ["Set-Cookie": "csrf_token=synthetic-csrf; Path=/; Secure"], json: "", check: { request in
            XCTAssertEqual(request.httpMethod, "HEAD")
            XCTAssertEqual(request.url?.absoluteString, "https://www.reddit.com/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=\(session)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        })
    }

    static func mint(session: String, token: String) -> Self {
        Self(status: 400, headers: ["Set-Cookie": "token_v2=\(token); Domain=.reddit.com; Path=/; Secure; HttpOnly"], json: "{}", check: { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://www.reddit.com/svc/shreddit/graphql")
            let cookies = request.value(forHTTPHeaderField: "Cookie") ?? ""
            XCTAssertTrue(cookies.contains("reddit_session=\(session)"))
            XCTAssertTrue(cookies.contains("csrf_token=synthetic-csrf"))
            XCTAssertFalse(cookies.contains("token_v2="))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        })
    }

    static func graphql(_ operation: String, token: String, json: String) -> Self {
        Self(json: json, check: { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.absoluteString, "https://cf.gql-fed.reddit.com/")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Modhash"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            if let body = request.httpBody,
               let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                XCTAssertEqual(payload["operationName"] as? String, operation)
            }
        })
    }
}

private final class GraphQLScenario: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private let replies: [GraphQLReply]
    private var recorded: [URLRequest] = []

    init(_ replies: [GraphQLReply]) {
        self.replies = replies
        GraphQLRequestProtocol.register(self)
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func reply(to request: URLRequest) -> GraphQLReply {
        let index = lock.withLock {
            let index = recorded.count
            recorded.append(request)
            return index
        }
        guard index < replies.count else {
            XCTFail("Unexpected request \(request.url?.host ?? "unknown")")
            return GraphQLReply(status: 500, json: "{}")
        }
        let reply = replies[index]
        reply.check?(request)
        return reply
    }

    func client(vault: any AccountCredentialVault) -> URLSessionRedditClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GraphQLRequestProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Octonaut-Test": id]
        return URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
    }

    func assertFinished(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(requests.count, replies.count, file: file, line: line)
    }

    func close() { GraphQLRequestProtocol.remove(id) }
}

private final class GraphQLRequestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenarios: [String: GraphQLScenario] = [:]

    static func register(_ scenario: GraphQLScenario) { lock.withLock { scenarios[scenario.id] = scenario } }
    static func remove(_ id: String) { _ = lock.withLock { scenarios.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scenario = Self.lock.withLock { Self.scenarios[request.value(forHTTPHeaderField: "X-Octonaut-Test") ?? ""] }
        guard let scenario, let url = request.url else {
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
        let reply = scenario.reply(to: captured)
        if let beforeReply = reply.beforeReply {
            Task { @Sendable [self, reply, url, beforeReply] in
                await beforeReply()
                self.deliver(reply, url: url)
            }
        } else {
            deliver(reply, url: url)
        }
    }

    private func deliver(_ reply: GraphQLReply, url: URL) {
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
