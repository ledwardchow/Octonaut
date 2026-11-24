import Foundation
import XCTest
@testable import Octonaut

final class UserSearchPaginationTests: XCTestCase {
    @MainActor
    func testModelKeepsUserCursorAndStopsRepeatedPage() async {
        let data = Data(#"{"data":{"after":"same","before":null,"children":[{"kind":"t2","data":{"name":"Reader"}}]}}"#.utf8)
        let model = SearchFeatureModel(reddit: FixtureRedditClient(usersData: data))

        await model.submit(query: "reader", scope: .users)
        XCTAssertEqual(model.users.map(\.id), ["reader"])
        XCTAssertTrue(model.hasMoreResults)

        await model.loadMore()
        XCTAssertEqual(model.users.map(\.id), ["reader"])
        XCTAssertFalse(model.hasMoreResults)
        XCTAssertFalse(model.isLoadingMore)
    }

    @MainActor
    func testModelClearsUserCursorOnAccountChange() async {
        let data = Data(#"{"data":{"after":"next","before":null,"children":[]}}"#.utf8)
        let model = SearchFeatureModel(reddit: FixtureRedditClient(usersData: data))

        await model.submit(query: "reader", scope: .users, account: AccountID())
        XCTAssertEqual(model.state, .loaded)
        XCTAssertTrue(model.hasMoreResults)

        model.invalidateForAccountChange()
        XCTAssertFalse(model.hasMoreResults)
        XCTAssertTrue(model.users.isEmpty)
        XCTAssertEqual(model.state, .idle)
    }

    func testUserCursorUsesAfterCursorAndRejectsOtherAccountAndQuery() async throws {
        let account = AccountID()
        let other = AccountID()
        let token = WebGraphQLToken(value: "synthetic.token.signature",
                                    sourceSessionDigest: RedditSessionIdentity.digest("session-A"),
                                    expiresAt: .now.addingTimeInterval(3600))
        let vault = InMemoryCredentialVault(values: [
            account: RedditCredential(cookieValue: "session-A", webGraphQLToken: token),
            other: RedditCredential(cookieValue: "session-B")
        ])
        let scenario = UserSearchScenario([
            Self.page("Reader", cursor: "server-cursor"),
            Self.page("reader", cursor: "server-cursor")
        ])
        defer { scenario.close() }
        let client = scenario.client(vault: vault)

        let first = try await client.users(RedditUserSearchRequest(query: "reader", limit: 12), account: account)
        XCTAssertEqual(first.items.map(\.id), ["reader"])
        let cursor = try XCTUnwrap(first.after)
        XCTAssertNotEqual(cursor, "server-cursor")

        await assertRejected(client, request: RedditUserSearchRequest(query: "other", after: cursor, limit: 12), account: account)
        await assertRejected(client, request: RedditUserSearchRequest(query: "reader", after: cursor, limit: 13), account: account)
        await assertRejected(client, request: RedditUserSearchRequest(query: "reader", after: cursor, limit: 12), account: other)
        XCTAssertEqual(scenario.requests.count, 1)

        let next = try await client.users(RedditUserSearchRequest(query: "reader", after: cursor, limit: 12), account: account)
        XCTAssertEqual(next.items.map(\.id), ["reader"])
        XCTAssertNil(next.after)
        XCTAssertEqual(scenario.requests.count, 2)
        let firstVariables = try Self.variables(scenario.requests[0])
        let nextVariables = try Self.variables(scenario.requests[1])
        XCTAssertNil(firstVariables["afterCursor"])
        XCTAssertEqual(nextVariables["afterCursor"] as? String, "server-cursor")
        XCTAssertEqual(nextVariables["query"] as? String, "reader")
        XCTAssertEqual(nextVariables["pageSize"] as? Int, 12)

        try await vault.save(RedditCredential(cookieValue: "session-replaced"), for: account)
        await assertRejected(client, request: RedditUserSearchRequest(query: "reader", after: cursor, limit: 12), account: account)
        XCTAssertEqual(scenario.requests.count, 2)
    }

    private func assertRejected(_ client: URLSessionRedditClient, request: RedditUserSearchRequest,
                                account: AccountID) async {
        do {
            _ = try await client.users(request, account: account)
            XCTFail("Cursor should be bound to its account, session, query, and page size")
        } catch {
            XCTAssertEqual(error as? RedditClientError,
                           .http(statusCode: 400, message: "This Reddit sort or page direction is unavailable."))
        }
    }

    private static func page(_ name: String, cursor: String) -> String {
        #"{"data":{"search":{"general":{"authors":{"edges":[{"node":{"__typename":"Redditor","name":"\#(name)"}}],"pageInfo":{"hasNextPage":true,"endCursor":"\#(cursor)"}}}}}}"#
    }

    private static func variables(_ request: URLRequest) throws -> [String: Any] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        } else {
            throw RedditClientError.malformedResponse
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(payload["operationName"] as? String, "SearchPeople")
        return try XCTUnwrap(payload["variables"] as? [String: Any])
    }
}

private final class UserSearchScenario: @unchecked Sendable {
    let id = UUID().uuidString
    private let lock = NSLock()
    private let pages: [String]
    private var recorded: [URLRequest] = []

    init(_ pages: [String]) {
        self.pages = pages
        UserSearchProtocol.register(self)
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func response(to request: URLRequest) -> String {
        let index = lock.withLock {
            let index = recorded.count
            recorded.append(request)
            return index
        }
        XCTAssertEqual(request.url?.absoluteString, "https://cf.gql-fed.reddit.com/")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        guard index < pages.count else {
            XCTFail("Unexpected GraphQL request")
            return "{}"
        }
        return pages[index]
    }

    func client(vault: any AccountCredentialVault) -> URLSessionRedditClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UserSearchProtocol.self]
        configuration.httpAdditionalHeaders = ["X-User-Search-Test": id]
        return URLSessionRedditClient(credentialVault: vault, sessionConfiguration: configuration)
    }

    func close() { UserSearchProtocol.remove(id) }
}

private final class UserSearchProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var scenarios: [String: UserSearchScenario] = [:]

    static func register(_ scenario: UserSearchScenario) { lock.withLock { scenarios[scenario.id] = scenario } }
    static func remove(_ id: String) { _ = lock.withLock { scenarios.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let scenario = Self.lock.withLock({ Self.scenarios[request.value(forHTTPHeaderField: "X-User-Search-Test") ?? ""] }),
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
        let page = scenario.response(to: captured)
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(page.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
