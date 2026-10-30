import Foundation
import Synchronization

struct GraphQLOperation: Sendable {
    let name: String
    let hash: String

    static let homeFeed = Self(name: "HomeFeedSdui", hash: "03d0ec0f2674005fe6c9777f952bd063ea2236527794344d4579fec8a669bea0")
    static let popularFeed = Self(name: "PopularFeedSdui", hash: "effee8db2d66287bea4e08a3ccf3a5fcb2db245c363be6fe50a3ba01e9962a24")
    static let allFeed = Self(name: "AllFeedSdui", hash: "dea8ebf08bd9127a580fd664b9c312e590a195690f5c04c32d60b9370d876fb0")
    static let subredditFeed = Self(name: "SubredditFeedSdui", hash: "45faffc9969af3d623a079e279c9d9a535b6f877809426a9a8ed203f046a23f0")
    static let customFeed = Self(name: "CustomFeedSdui", hash: "5a7d82da6ae429dcc26d7e7f0530c09dabc27f140db52c44312d6c9a5fac5a04")
    static let postsByIDs = Self(name: "PostsByIds", hash: "b210ea1d852cdc2c25d9bff2d9fa8a406e1a968f36392798812f336694ac27f4")
    static let subredditInfo = Self(name: "SubredditInfoByName", hash: "8c1815b07b762aee3c086cc84306f14b3907018e9ee152046c8e4d08ad4c7b88")
    static let exploreFeed = Self(name: "ExploreFeedSdui", hash: "78c98e9b4f7845ebe3bd5a22f614a84fb77b9e0bd527a73bbf1eb4a8b348183e")
    static let searchPosts = Self(name: "SearchPosts", hash: "c3d31b88bfa15180fdcd0c8f6f13b8c0e131d0c981c9b9c8a7c537ddd0ed3348")
    static let searchCommunities = Self(name: "CommunityPickerSearchPaginated", hash: "b58025ad0c98bdb93e9dc1db909accf440573bd7d3a48d2c73a02e96d33f1943")
    static let searchPeople = Self(name: "SearchPeople", hash: "db3607c1a7deea8441614a053c5f434f60da0c8c931db952f819a59d534d9743")
}

enum GraphQLValue: Encodable, Sendable {
    case null, string(String), int(Int), bool(Bool), array([GraphQLValue]), object([String: GraphQLValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

private final class RejectGraphQLRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor RedditGraphQLClient {
    private static let website = URL(string: "https://www.reddit.com/")!
    private static let bootstrap = URL(string: "https://www.reddit.com/svc/shreddit/graphql")!
    private static let graphql = URL(string: "https://cf.gql-fed.reddit.com/")!
    private static let expiryMargin: TimeInterval = 300

    private let credentialVault: any AccountCredentialVault
    private let session: URLSession
    private let userAgent: String
    private var refreshTasks: [AccountID: (digest: String, task: Task<WebGraphQLToken, Error>)] = [:]
    private var renewingSessions: [AccountID: (old: String, new: String)] = [:]
    private struct FeedCursor {
        let account: AccountID
        let feed: FeedDescriptor
        let generation: String
        let serverAfter: String
        let visited: Set<String>
    }
    private var feedCursors: [String: FeedCursor] = [:]
    private var feedCursorOrder: [String] = []
    private enum SearchScope: Hashable {
        case posts(query: String, community: String?, sort: RedditSort, time: RedditTimeRange?, limit: Int)
        case communities(query: String, limit: Int)
    }
    private struct SearchCursor {
        let account: AccountID
        let generation: String
        let scope: SearchScope
        let serverAfter: String
        let visited: Set<String>
    }
    private var searchCursors: [String: SearchCursor] = [:]
    private var searchCursorOrder: [String] = []
    private nonisolated let selectionEpoch = Mutex<UInt64>(0)
    private var accountGenerations: [AccountID: (digest: String, generation: String, epoch: UInt64)] = [:]

    nonisolated func invalidateContinuations() {
        selectionEpoch.withLock { $0 &+= 1 }
    }

    func sessionGeneration(for account: AccountID) async throws -> String {
        let digest = try await sessionDigest(for: account)
        let epoch = selectionEpoch.withLock { $0 }
        if let existing = accountGenerations[account], existing.epoch == epoch {
            let renewal = renewingSessions[account]
            if existing.digest == digest || (renewal?.old == existing.digest && renewal?.new == digest) {
                return existing.generation
            }
        }
        let generation = UUID().uuidString
        accountGenerations[account] = (digest, generation, epoch)
        return generation
    }

    func sessionDigest(for account: AccountID) async throws -> String {
        guard let credential = try await credentialVault.credential(for: account),
              credential.cookieName == "reddit_session", !credential.cookieValue.isEmpty else {
            throw RedditClientError.authenticationRequired
        }
        return RedditSessionIdentity.digest(credential.cookieValue)
    }

    init(credentialVault: any AccountCredentialVault,
         userAgent: String = URLSessionRedditClient.browserUserAgent,
         sessionConfiguration: URLSessionConfiguration? = nil) {
        self.credentialVault = credentialVault
        self.userAgent = userAgent
        let configuration = (sessionConfiguration ?? .ephemeral).copy() as! URLSessionConfiguration
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: configuration, delegate: RejectGraphQLRedirects(), delegateQueue: nil)
    }

    func listing(_ request: ListingRequest, account: AccountID?) async throws -> Listing<Post> {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
        let generation = try await sessionGeneration(for: account)
        guard request.before == nil else { throw unsupportedRequest() }
        let (operation, defaultSort, extra) = try feedOperation(request.feed.destination)
        let sort = request.feed.sort == .default ? defaultSort : try feedSort(request.feed.sort)
        var variables: [String: GraphQLValue] = ["sort": .string(sort)]
        variables.merge(extra) { _, new in new }
        if let time = request.feed.topTime { variables["time"] = .string(time.rawValue.uppercased()) }
        if let after = request.after {
            guard let cursor = feedCursors[after], cursor.account == account,
                  cursor.feed == request.feed, cursor.generation == generation else { throw unsupportedRequest() }
            variables["after"] = .string(Data(cursor.serverAfter.utf8).base64EncodedString())
        }
        if case .community(let name) = request.feed.destination, request.after == nil {
            try await checkCommunityAccess(name: name, account: account)
        }
        var seen = request.after.flatMap { feedCursors[$0]?.visited } ?? []
        var lastCursor: String?
        for _ in 0..<3 {
            let feedData = try await execute(operation, variables: variables, account: account)
            let page = try RedditGraphQLCodec.feedPage(data: feedData)
            if let next = page.after, !seen.insert(next).inserted { return Listing(items: []) }
            var posts: [Post] = []
            if !page.ids.isEmpty {
                var postVariables = Self.postsByIDsVariables
                postVariables["ids"] = .array(page.ids.map(GraphQLValue.string))
                let postData = try await execute(.postsByIDs, variables: postVariables, account: account)
                posts = try RedditGraphQLCodec.posts(data: postData, orderedIDs: page.ids)
            }
            if let next = page.after {
                let cursor = UUID().uuidString
                feedCursors[cursor] = FeedCursor(account: account, feed: request.feed, generation: generation, serverAfter: next, visited: seen)
                feedCursorOrder.append(cursor)
                if feedCursorOrder.count > 256 { feedCursors.removeValue(forKey: feedCursorOrder.removeFirst()) }
                lastCursor = cursor
                variables["after"] = .string(Data(next.utf8).base64EncodedString())
            } else {
                lastCursor = nil
            }
            if !posts.isEmpty || page.after == nil { return Listing(items: posts, after: lastCursor) }
        }
        return Listing(items: [], after: lastCursor)
    }

    private func feedOperation(_ destination: FeedDestination) throws -> (GraphQLOperation, String, [String: GraphQLValue]) {
        switch destination {
        case .home: return (.homeFeed, "BEST", [:])
        case .popular: return (.popularFeed, "HOT", [:])
        case .all: return (.allFeed, "HOT", [:])
        case .community(let name):
            let normalized = IDNormalization.community(name)
            guard !normalized.isEmpty, !normalized.contains("+") else { throw unsupportedRequest() }
            return (.subredditFeed, "HOT", ["subredditName": .string(normalized)])
        case .multireddit(let owner, let name):
            guard !owner.isEmpty, !name.isEmpty, !owner.contains("/"), !name.contains("/") else { throw unsupportedRequest() }
            return (.customFeed, "HOT", ["path": .string("/user/\(owner)/m/\(name)")])
        default: throw unsupportedRequest()
        }
    }

    func checkCommunityAccess(name: String, account: AccountID) async throws {
        var variables: [String: GraphQLValue] = ["subredditName": .string(IDNormalization.community(name))]
        for key in "includeWelcomePage includeDevvitData filterGated".split(separator: " ") { variables[String(key)] = .bool(true) }
        for key in "loggedOutIsOptedIn includeRecapFields includeFeatureVariants includeManualFeatureVariants includeCommunityGuidanceChecklist".split(separator: " ") { variables[String(key)] = .bool(false) }
        let data = try await execute(.subredditInfo, variables: variables, account: account)
        let info = try RedditGraphQLCodec.communityAccess(data: data)
        switch info {
        case .available: break
        case .missing: throw RedditClientError.notFound
        case .banned, .privateCommunity: throw RedditClientError.accessDenied
        case .quarantined, .gated:
            throw RedditClientError.http(statusCode: 403, message: "Open this community on Reddit to approve access.")
        }
    }

    func discoveryCommunities(limit: Int, account: AccountID?) async throws -> Listing<Community> {
        let data = try await execute(.exploreFeed, variables: ["includeCarouselRecommendations": .bool(true)], account: account)
        return Listing(items: try RedditGraphQLCodec.discoveryCommunities(data: data, limit: limit))
    }

    func search(_ request: RedditSearchRequest, account: AccountID?) async throws -> Listing<Post> {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
        let sort = try searchSort(request.sort)
        var variables = Self.postFragmentVariables
        variables["query"] = .string(request.query)
        variables["productSurface"] = .string("android")
        variables["pageSize"] = .int(request.limit)
        variables["sort"] = .string(sort)
        var filters: [GraphQLValue] = []
        if let time = request.timeRange {
            filters.append(.object(["key": .string("time_range"), "value": .string(time.rawValue)]))
        }
        let community = request.community.map { Self.normalizedSearchCommunity($0) }
            .flatMap { $0.isEmpty || $0.lowercased() == "all" || $0.lowercased() == "popular" ? nil : $0 }
        if let community {
            filters.append(.object(["key": .string("subreddit_names"), "value": .string(community)]))
        }
        if !filters.isEmpty { variables["filters"] = .array(filters) }
        let scope = SearchScope.posts(query: request.query, community: community?.lowercased(),
                                     sort: request.sort, time: request.timeRange, limit: request.limit)
        return try await searchPages(operation: .searchPosts, variables: variables, afterKey: "afterCursor",
                                     after: request.after, account: account, scope: scope,
                                     decode: RedditGraphQLCodec.searchPosts)
    }

    func communities(_ request: RedditCommunitySearchRequest, account: AccountID?) async throws -> Listing<Community> {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
        let query = Self.normalizedSearchCommunity(request.query)
        let variables: [String: GraphQLValue] = [
            "query": .string(query),
            "productSurface": .string("android"), "first": .int(request.limit)
        ]
        return try await searchPages(operation: .searchCommunities, variables: variables, afterKey: "after",
                                     after: request.after, account: account, scope: .communities(query: query.lowercased(), limit: request.limit),
                                     decode: RedditGraphQLCodec.communities)
    }

    private static func normalizedSearchCommunity(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^/?r/", with: "", options: [.regularExpression, .caseInsensitive])
    }

    private func searchPages<Element: Sendable>(operation: GraphQLOperation, variables: [String: GraphQLValue],
                                                 afterKey: String, after: String?, account: AccountID,
                                                 scope: SearchScope, decode: (Data) throws -> Listing<Element>) async throws -> Listing<Element> {
        let generation = try await sessionGeneration(for: account)
        var variables = variables
        var visited: Set<String> = []
        if let after {
            guard let cursor = searchCursors[after], cursor.account == account,
                  cursor.generation == generation, cursor.scope == scope else { throw unsupportedRequest() }
            variables[afterKey] = .string(cursor.serverAfter)
            visited = cursor.visited
        }
        var lastCursor: String?
        for _ in 0..<3 {
            let page = try decode(await execute(operation, variables: variables, account: account))
            guard let serverAfter = page.after, !serverAfter.isEmpty, visited.insert(serverAfter).inserted else {
                return Listing(items: page.items)
            }
            let cursor = UUID().uuidString
            searchCursors[cursor] = SearchCursor(account: account, generation: generation, scope: scope,
                                                  serverAfter: serverAfter, visited: visited)
            searchCursorOrder.append(cursor)
            if searchCursorOrder.count > 256 {
                searchCursors.removeValue(forKey: searchCursorOrder.removeFirst())
            }
            lastCursor = cursor
            if !page.items.isEmpty { return Listing(items: page.items, after: cursor) }
            variables[afterKey] = .string(serverAfter)
        }
        return Listing(items: [], after: lastCursor)
    }

    func users(_ request: RedditUserSearchRequest, account: AccountID?) async throws -> Listing<UserProfile> {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
        let variables: [String: GraphQLValue] = ["query": .string(request.query), "productSurface": .string("android"),
                                                 "pageSize": .int(request.limit)]
        return try RedditGraphQLCodec.users(data: await execute(.searchPeople, variables: variables, account: account))
    }

    func execute(_ operation: GraphQLOperation, variables: [String: GraphQLValue], account: AccountID?) async throws -> Data {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
        let expectedGeneration = try await sessionGeneration(for: account)
        guard let credential = try await credentialVault.credential(for: account),
              credential.cookieName == "reddit_session", !credential.cookieValue.isEmpty,
              !credential.cookieValue.contains(where: { $0 == ";" || $0 == "\r" || $0 == "\n" }) else {
            throw RedditClientError.authenticationRequired
        }
        let digest = RedditSessionIdentity.digest(credential.cookieValue)
        var token = try await freshToken(for: account, credential: credential, digest: digest)
        try await confirmSession(account: account, digest: token.sourceSessionDigest)
        var result = try await send(operation, variables: variables, token: token.value)
        if result.response.statusCode == 401 || result.response.statusCode == 403 {
            guard let current = try await credentialVault.credential(for: account),
                  current.cookieName == "reddit_session",
                  RedditSessionIdentity.digest(current.cookieValue) == token.sourceSessionDigest else {
                throw RedditClientError.authenticationRequired
            }
            token = try await refresh(for: account, credential: current, digest: token.sourceSessionDigest)
            try await confirmSession(account: account, digest: token.sourceSessionDigest)
            result = try await send(operation, variables: variables, token: token.value)
        }
        switch result.response.statusCode {
        case 200..<300: break
        case 401: throw RedditClientError.authenticationRequired
        case 403: throw RedditClientError.accessDenied
        case 429: throw RedditClientError.rateLimited(retryAfter: retryAfter(result.response))
        default: throw RedditClientError.http(statusCode: result.response.statusCode, message: nil)
        }
        guard try await sessionGeneration(for: account) == expectedGeneration else {
            throw RedditClientError.authenticationRequired
        }
        guard let root = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let data = root["data"] as? [String: Any], !data.isEmpty else {
            throw RedditClientError.malformedResponse
        }
        if let errors = root["errors"] as? [Any], !errors.isEmpty {
            throw RedditClientError.malformedResponse
        }
        return result.data
    }

    private func freshToken(for account: AccountID, credential: RedditCredential, digest: String) async throws -> WebGraphQLToken {
        if let token = credential.webGraphQLToken,
           token.sourceSessionDigest == digest,
           token.expiresAt.timeIntervalSinceNow > Self.expiryMargin { return token }
        return try await refresh(for: account, credential: credential, digest: digest)
    }

    private func refresh(for account: AccountID, credential: RedditCredential, digest: String) async throws -> WebGraphQLToken {
        if let existing = matchingRefresh(account: account, digest: digest) { return try await existing.value }
        do { try await confirmSession(account: account, digest: digest) }
        catch {
            if let existing = matchingRefresh(account: account, digest: digest) { return try await existing.value }
            throw error
        }
        if let existing = matchingRefresh(account: account, digest: digest) { return try await existing.value }
        let task = Task { try await bootstrapToken(for: account, credential: credential, digest: digest) }
        refreshTasks[account] = (digest, task)
        defer { if refreshTasks[account]?.digest == digest { refreshTasks.removeValue(forKey: account) } }
        return try await task.value
    }

    private func matchingRefresh(account: AccountID, digest: String) -> Task<WebGraphQLToken, Error>? {
        guard let existing = refreshTasks[account] else { return nil }
        let renewal = renewingSessions[account]
        guard existing.digest == digest || (renewal?.old == existing.digest && renewal?.new == digest) else { return nil }
        return existing.task
    }

    private func confirmSession(account: AccountID, digest: String) async throws {
        guard let current = try await credentialVault.credential(for: account),
              current.cookieName == "reddit_session",
              RedditSessionIdentity.digest(current.cookieValue) == digest else {
            throw RedditClientError.authenticationRequired
        }
    }

    private func bootstrapToken(for account: AccountID, credential: RedditCredential, digest: String) async throws -> WebGraphQLToken {
        var rotation: (old: String, new: String)?
        defer {
            if let rotation, let pending = renewingSessions[account],
               pending.old == rotation.old, pending.new == rotation.new {
                renewingSessions.removeValue(forKey: account)
            }
        }
        let sourceCookie = "reddit_session=\(credential.cookieValue)"
        var head = URLRequest(url: Self.website)
        head.httpMethod = "HEAD"
        head.setValue(sourceCookie, forHTTPHeaderField: "Cookie")
        head.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let headResult = try await perform(head, expectedHost: "www.reddit.com")
        if headResult.response.statusCode == 429 {
            throw RedditClientError.rateLimited(retryAfter: retryAfter(headResult.response))
        }
        guard (200..<400).contains(headResult.response.statusCode) else {
            throw RedditClientError.authenticationRequired
        }
        var sessionValue = credential.cookieValue
        var sessionDigest = digest
        if let renewed = setCookies(headResult.response).first(where: { $0.name == "reddit_session" }),
           renewed.value != credential.cookieValue {
            guard !renewed.value.isEmpty,
                  !renewed.value.contains(where: { $0 == ";" || $0 == "\r" || $0 == "\n" }) else {
                throw RedditClientError.authenticationRequired
            }
            if let oldAccount = jwtClaim(credential.cookieValue, key: "sub"),
               let newAccount = jwtClaim(renewed.value, key: "sub"),
               oldAccount != newAccount { throw RedditClientError.authenticationRequired }
            let renewedDigest = RedditSessionIdentity.digest(renewed.value)
            rotation = (digest, renewedDigest)
            renewingSessions[account] = rotation
            guard try await credentialVault.replaceSessionCookie(renewed.value, expected: credential.cookieValue, for: account) else {
                throw RedditClientError.authenticationRequired
            }
            sessionValue = renewed.value
            sessionDigest = renewedDigest
            if let generation = accountGenerations[account], generation.digest == digest {
                accountGenerations[account] = (sessionDigest, generation.generation, generation.epoch)
            }
        }
        let extraCookies = safeBootstrapCookies(headResult.response)
        var post = URLRequest(url: Self.bootstrap)
        post.httpMethod = "POST"
        post.httpBody = Data("{}".utf8)
        post.setValue("application/json", forHTTPHeaderField: "Content-Type")
        post.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        post.setValue((["reddit_session=\(sessionValue)"] + extraCookies).joined(separator: "; "), forHTTPHeaderField: "Cookie")
        let result = try await perform(post, expectedHost: "www.reddit.com")
        if result.response.statusCode == 429 {
            throw RedditClientError.rateLimited(retryAfter: retryAfter(result.response))
        }
        guard result.response.statusCode == 400 || (200..<300).contains(result.response.statusCode) else {
            throw RedditClientError.authenticationRequired
        }
        guard let cookie = setCookies(result.response).first(where: { $0.name == "token_v2" }),
              !cookie.value.isEmpty else { throw RedditClientError.authenticationRequired }
        if let sessionAccount = jwtClaim(sessionValue, key: "sub"),
           let tokenAccount = jwtClaim(cookie.value, key: "lid"),
           sessionAccount != tokenAccount { throw RedditClientError.authenticationRequired }
        let expiry = jwtExpiry(cookie.value) ?? cookie.expiry
        guard let expiry, expiry.timeIntervalSinceNow > Self.expiryMargin else {
            throw RedditClientError.authenticationRequired
        }
        let token = WebGraphQLToken(value: cookie.value, sourceSessionDigest: sessionDigest, expiresAt: expiry)
        guard try await credentialVault.saveWebGraphQLToken(token, for: account) else {
            throw RedditClientError.authenticationRequired
        }
        return token
    }

    private func send(_ operation: GraphQLOperation, variables: [String: GraphQLValue], token: String) async throws -> (data: Data, response: HTTPURLResponse) {
        let body: GraphQLValue = .object([
            "operationName": .string(operation.name), "variables": .object(variables),
            "extensions": .object(["persistedQuery": .object(["version": .int(1), "sha256Hash": .string(operation.hash)])])
        ])
        var request = URLRequest(url: Self.graphql)
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(body)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await perform(request, expectedHost: "cf.gql-fed.reddit.com")
    }

    private func perform(_ request: URLRequest, expectedHost: String) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host == expectedHost,
              url.port == nil, url.user == nil, url.password == nil else { throw RedditClientError.invalidURL }
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  http.url == url else { throw RedditClientError.invalidResponse }
            guard !(300..<400).contains(http.statusCode) else { throw RedditClientError.invalidResponse }
            return (data, http)
        } catch let error as RedditClientError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw RedditClientError.transport("Reddit could not be reached.") }
    }

    private func feedSort(_ sort: PostSort) throws -> String {
        switch sort {
        case .default, .hot: "HOT"
        case .new: "NEW"
        case .top: "TOP"
        case .rising: "RISING"
        case .controversial: "CONTROVERSIAL"
        case .best: "BEST"
        case .unknown: throw unsupportedRequest()
        }
    }

    private func searchSort(_ sort: RedditSort) throws -> String {
        switch sort {
        case .hot: "HOT"
        case .new: "NEW"
        case .top: "TOP"
        default: throw unsupportedRequest()
        }
    }

    private func unsupportedRequest() -> RedditClientError {
        .http(statusCode: 400, message: "This Reddit sort or page direction is unavailable.")
    }

    private func retryAfter(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value) { return max(0, seconds) }
        return HTTPDateFormatter.parse(value).map { max(0, $0.timeIntervalSinceNow) }
    }

    private struct Cookie { let name: String; let value: String; let expiry: Date? }

    private func setCookies(_ response: HTTPURLResponse) -> [Cookie] {
        let headers = response.allHeaderFields.compactMap { key, value -> String? in
            guard String(describing: key).caseInsensitiveCompare("Set-Cookie") == .orderedSame else { return nil }
            return String(describing: value)
        }
        let splitter = try! NSRegularExpression(pattern: ",(?=\\s*[A-Za-z0-9_-]+=)")
        return headers.flatMap { header -> [Cookie] in
            let range = NSRange(header.startIndex..., in: header)
            let pieces = splitter.stringByReplacingMatches(in: header, range: range, withTemplate: "\n")
            return pieces.split(separator: "\n").compactMap { line in
                let parts = line.split(separator: ";", omittingEmptySubsequences: false)
                guard let first = parts.first, let equal = first.firstIndex(of: "=") else { return nil }
                let name = String(first[..<equal]).trimmingCharacters(in: .whitespaces)
                let value = String(first[first.index(after: equal)...]).trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }),
                      !value.contains(";") && !value.contains("\r") && !value.contains("\n") else { return nil }
                var expiry: Date?
                for attribute in parts.dropFirst() {
                    let item = attribute.trimmingCharacters(in: .whitespaces)
                    if item.lowercased().hasPrefix("max-age="), let seconds = TimeInterval(item.dropFirst(8)) {
                        expiry = Date().addingTimeInterval(seconds)
                    } else if item.lowercased().hasPrefix("expires=") {
                        expiry = HTTPDateFormatter.parse(String(item.dropFirst(8)))
                    }
                }
                return Cookie(name: name, value: value, expiry: expiry)
            }
        }
    }

    private func safeBootstrapCookies(_ response: HTTPURLResponse) -> [String] {
        setCookies(response).filter { cookie in
            cookie.name != "reddit_session" && cookie.name != "token_v2" && !cookie.value.isEmpty
        }.map { "\($0.name)=\($0.value)" }
    }

    private func jwtExpiry(_ token: String) -> Date? {
        guard let value = jwtClaim(token, key: "exp"), let expiry = TimeInterval(value) else { return nil }
        return Date(timeIntervalSince1970: expiry)
    }

    private func jwtClaim(_ token: String, key: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let value = claims[key] as? String { return value }
        if let value = claims[key] as? NSNumber { return value.stringValue }
        return nil
    }

    private enum HTTPDateFormatter {
        static func parse(_ value: String) -> Date? {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            return formatter.date(from: value)
        }
    }

    static let postsByIDsVariables: [String: GraphQLValue] = {
        var values: [String: GraphQLValue] = [:]
        for key in "includeAwards includeSubredditInPosts includePcpV2InPosts includePostStats includeDeletedPosts includeStillMediaAltText includeExtraStillResolutions includePlaybackMp4s includeMuxedMp4s includeDevvitData includeCommunityStatus includeIsModRemovedContentReadAllowed includeUnavailablePostReason includePredictedRemovalReasons includeSubredditBackgroundColor includeOverlayData includeCtaEnrichedPageTitle includePlaCards includeWebviewPrefetchField includeAdBrowserDestinationField includeCollectionsHeroCard includeGalleryAdUrl includeCtaMediaColor includeFollowedForNotificationsStatus includeRedditHandleInfo includeVerificationStatus includeIsActiveComments includeMediaSynthesis includePostTombstone".split(separator: " ") {
            values[String(key)] = .bool(true)
        }
        for key in "includeCurrentUserAwards includeExtendedVideoAsset includeVideoPlaybackInComments includePlaCardThumbnail skipModerationInfo includeIsReceivingPostReplies skipRedditPlayPlaybackMp4s includeLinkPreviewTitle includeInterestTags includeAutomatedFeedback includeCommentId".split(separator: " ") {
            values[String(key)] = .bool(false)
        }
        values["skipRedditPlayPlaybackMp4s"] = .bool(true)
        values["commentId"] = .string("")
        return values
    }()

    private static let postFragmentVariables: [String: GraphQLValue] = {
        let declared = Set("includeSubredditInPosts includeAwards includePostStats includeCurrentUserAwards includeStillMediaAltText includeExtraStillResolutions includeExtendedVideoAsset includePlaybackMp4s includeMuxedMp4s includeDevvitData includeCommunityStatus includeIsModRemovedContentReadAllowed includeVideoPlaybackInComments includeSubredditBackgroundColor includeOverlayData includeCtaEnrichedPageTitle includePlaCards includePlaCardThumbnail includeWebviewPrefetchField includeAdBrowserDestinationField includeCollectionsHeroCard includeGalleryAdUrl includeCtaMediaColor includeFollowedForNotificationsStatus includePredictedRemovalReasons includeRedditHandleInfo includeVerificationStatus skipModerationInfo includeIsReceivingPostReplies includeIsActiveComments includeMediaSynthesis skipRedditPlayPlaybackMp4s includeLinkPreviewTitle".split(separator: " ").map(String.init))
        return postsByIDsVariables.filter { declared.contains($0.key) }
    }()
}
