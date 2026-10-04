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
