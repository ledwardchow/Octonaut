import XCTest
@testable import Octonaut

final class ReportingTests: XCTestCase {
    func testCommunityRulesFilterByContentAndDeduplicate() throws {
        let data = Data(#"{"rules":[{"short_name":"Posts","violation_reason":"Post rule","kind":"link"},{"short_name":"Comments","violation_reason":"Comment rule","kind":"comment"},{"short_name":"All","violation_reason":"All rule","kind":"all"},{"short_name":"Duplicate","violation_reason":"All rule","kind":"all"}]}"#.utf8)
        let rules = try RedditReportRule.decode(data)
        XCTAssertEqual(rules.filter { $0.applies(to: "t3_abc") }.map(\.violationReason), ["Post rule", "All rule"])
        XCTAssertEqual(rules.filter { $0.applies(to: "t1_def") }.map(\.violationReason), ["Comment rule", "All rule"])
        XCTAssertThrowsError(try RedditReportRule.decode(Data(#"{"unexpected":[]}"#.utf8)))
    }

    func testReportRequestUsesWebsiteFields() {
        let request = URLSessionRedditClient.mutationRequest(for: .report(fullname: "t1_abc", community: "test", reason: "Be kind"))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/report")
        XCTAssertEqual(request.fields["thing_id"], "t1_abc")
        XCTAssertEqual(request.fields["sr_name"], "test")
        XCTAssertEqual(request.fields["reason"], "Be kind")
        XCTAssertEqual(request.fields["rule_reason"], "Be kind")
        XCTAssertEqual(request.fields["api_type"], "json")
    }

    func testReportResponseRequiresExplicitJSONEnvelope() throws {
        XCTAssertTrue(try RedditReportRule.decodeSubmission(Data(#"{"json":{"errors":[]}}"#.utf8)).succeeded)
        let rejected = try RedditReportRule.decodeSubmission(Data(#"{"json":{"errors":[["FREE_FORM_REPORTS_NOT_ALLOWED","Choose a community rule","reason"]]}}"#.utf8))
        XCTAssertFalse(rejected.succeeded)
        for response in ["", "{}", "[]", "null", "{\"json\":{}}"] {
            XCTAssertThrowsError(try RedditReportRule.decodeSubmission(Data(response.utf8)))
        }
    }

    func testReportDestinationsAndIdentifiers() {
        for destination in ["http://www.reddit.com/api/report", "https://reddit.com.evil.example/", "https://example.com/", "https://www.reddit.com:8443/", "https://user:password@www.reddit.com/"] {
            XCTAssertFalse(RedditReportTarget.isRedditURL(URL(string: destination)!))
        }
        XCTAssertTrue(RedditReportTarget.isRedditURL(URL(string: "https://www.reddit.com/api/report")!))
        XCTAssertTrue(RedditReportTarget.validFullname("t3_abc123"))
        XCTAssertFalse(RedditReportTarget.validFullname("t2_abc"))
        XCTAssertFalse(RedditReportTarget.validFullname("t1_"))
        XCTAssertFalse(RedditReportRule.validCommunity("test/../../api"))
    }

    @MainActor
    func testBrowserReportURLIncludesCommentPermalink() throws {
        let post = PostCardModel(post: FixtureData.posts[0])
        let target = RedditReportTarget(commentID: "abc123", post: post)
        let url = try XCTUnwrap(target.browserURL)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "www.reddit.com")
        XCTAssertEqual(url.path, target.permalink.path)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "context", value: "3")])
        XCTAssertEqual(target.permalink.lastPathComponent, "abc123")
    }

    @MainActor
    func testBrowserFallbackOpensPostAndRejectsUnrelatedDestinations() throws {
        var post = PostCardModel(
            id: "abc123", community: "test", author: "tester", title: "Test post", body: "",
            score: 0, comments: 0, age: "now", vote: 0, isSaved: false, isSeen: false,
            isNSFW: false, isSpoiler: false, isSticky: false, isVideo: false, hasMedia: false,
            mediaTitle: "", shareURL: URL(string: "https://www.reddit.com/r/test/comments/abc123/test_post/")!
        )
        let target = RedditReportTarget(post: post)
        XCTAssertEqual(try XCTUnwrap(target.browserURL).path, post.shareURL.path)
        XCTAssertNil(URLComponents(url: try XCTUnwrap(target.browserURL), resolvingAgainstBaseURL: false)?.query)
        for destination in ["https://example.com/r/test/comments/abc/post/", "http://www.reddit.com/r/test/comments/abc/post/", "https://www.reddit.com/"] {
            post.shareURL = URL(string: destination)!
            XCTAssertNil(RedditReportTarget(post: post).browserURL)
        }
    }

    func testReportRequiresCookieAndModhashWithoutSendingRequest() async throws {
        let account = AccountID(rawValue: UUID())
        let vault = InMemoryCredentialVault()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportRequestProtocol.self]
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
        let action = RedditAction.report(fullname: "t3_abc", community: "test", reason: "Test report")
        for credential in [nil, RedditCredential(cookieValue: "synthetic", modhash: nil)] {
            if let credential { try await vault.save(credential, for: account) }
            do {
                _ = try await client.perform(action, account: account)
                XCTFail("Missing credentials should prevent reporting")
            } catch { XCTAssertEqual(error as? RedditClientError, .authenticationRequired) }
        }
    }

    func testReportSendsSessionOnlyToHTTPSReddit() async throws {
        let account = AccountID(rawValue: UUID())
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic", modhash: "test-modhash")])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReportRequestProtocol.self]
        let client = URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
        let result = try await client.perform(.report(fullname: "t3_abc", community: "test", reason: "Test report"), account: account)
        XCTAssertTrue(result.succeeded)
        let unsafe = URLSessionRedditClient(baseURL: URL(string: "https://example.com")!, credentialVault: vault, sessionConfiguration: configuration)
        do {
            _ = try await unsafe.perform(.report(fullname: "t3_abc", community: "test", reason: "Test report"), account: account)
            XCTFail("External host must be rejected")
        } catch { XCTAssertEqual(error as? RedditClientError, .invalidURL) }
    }
}

private final class ReportRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.absoluteString, "https://www.reddit.com/api/report")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=synthetic")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Modhash"), "test-modhash")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"json":{"errors":[]}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

final class InboxTests: XCTestCase {
    func testRepliesUseCommentContextAndPreserveMarkdown() throws {
        let data = Data(#"{"data":{"children":[{"kind":"t1","data":{"id":"abc","name":"t1_abc","subject":"comment reply","body":"Use <tag> and **bold**","context":"/r/test/comments/post/title/abc/?context=3","link_permalink":"/r/test/comments/post/title/","new":true}}]}}"#.utf8)
        let item = try XCTUnwrap(LiveAuthenticatedRedditService.decodeInbox(data).items.first)
        XCTAssertEqual(item.kind, "reply")
        XCTAssertEqual(item.body?.plainText, "Use <tag> and **bold**")
        XCTAssertEqual(item.postPermalink?.absoluteString, "https://www.reddit.com/r/test/comments/post/title/abc/?context=3")
        XCTAssertFalse(item.isRead)
    }

    func testCommentNotificationsAreNotPrivateMessages() throws {
        let data = Data(#"{"data":{"children":[{"kind":"t4","data":{"id":"abc","name":"t4_abc","was_comment":true,"subject":"username mention","body":"Mention","context":"https://example.com/","permalink":"http://www.reddit.com/","link_permalink":"/r/test/comments/post/title/"}}]}}"#.utf8)
        let item = try XCTUnwrap(LiveAuthenticatedRedditService.decodeInbox(data).items.first)
        XCTAssertEqual(item.kind, "mention")
        XCTAssertEqual(item.postPermalink?.host, "www.reddit.com")
        XCTAssertEqual(item.postPermalink?.scheme, "https")
    }

    func testConversationIncludesDeepRepliesAndRootID() throws {
        let data = Data(#"{"data":{"children":[{"kind":"t4","data":{"id":"root","name":"t4_root","body":"First","replies":{"data":{"children":[{"kind":"t4","data":{"id":"reply","body":"Second","first_message_name":"t4_root","replies":{"data":{"children":[{"kind":"t4","data":{"id":"last","body":"Third","first_message":"root"}}]}}}}]}}}}]}}"#.utf8)
        let items = try LiveAuthenticatedRedditService.decodeInbox(data, includeReplies: true).items
        XCTAssertEqual(items.map(\.id), ["root", "reply", "last"])
        XCTAssertEqual(items.map { $0.body?.plainText }, ["First", "Second", "Third"])
        XCTAssertEqual(items[1].conversationFullname, "t4_root")
        XCTAssertEqual(items[2].conversationFullname, "t4_root")
        XCTAssertEqual(try LiveAuthenticatedRedditService.decodeInbox(data).items.count, 1)
    }

    func testInboxRequestsUseWebsiteSessionAndRejectUnsafeHosts() async throws {
        let account = AccountID(rawValue: UUID())
        let vault = InMemoryCredentialVault(values: [account: RedditCredential(cookieValue: "synthetic", modhash: "test")])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InboxRequestProtocol.self]
        let service = LiveAuthenticatedRedditService(credentialVault: vault, reddit: FixtureRedditClient(), sessionConfiguration: configuration)
        let signedOut = LiveAuthenticatedRedditService(credentialVault: InMemoryCredentialVault(), reddit: FixtureRedditClient(), sessionConfiguration: configuration)
        do {
            _ = try await signedOut.fetchInbox(section: .all, accountID: account)
            XCTFail("A missing session must prevent the request")
        } catch { XCTAssertEqual(error as? RedditClientError, .authenticationRequired) }
        _ = try await service.fetchInbox(section: .all, accountID: account)
        _ = try await service.fetchConversation(messageID: "t4_abc", accountID: account)
        for destination in ["https://example.com", "http://www.reddit.com", "https://www.reddit.com:8443"] {
            let unsafe = LiveAuthenticatedRedditService(credentialVault: vault, reddit: FixtureRedditClient(), baseURL: URL(string: destination)!, sessionConfiguration: configuration)
            do {
                _ = try await unsafe.fetchInbox(section: .all, accountID: account)
                XCTFail("Unsafe destinations must be rejected")
            } catch { XCTAssertEqual(error as? RedditClientError, .invalidURL) }
        }
        do {
            _ = try await service.fetchConversation(messageID: "../inbox", accountID: account)
            XCTFail("Invalid message IDs must be rejected")
        } catch { XCTAssertEqual(error as? RedditClientError, .invalidURL) }
    }
}

private final class InboxRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.url?.host, "www.reddit.com")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertTrue(["/message/inbox.json", "/message/messages/abc.json"].contains(request.url!.path))
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "reddit_session=synthetic")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":{"children":[]}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
