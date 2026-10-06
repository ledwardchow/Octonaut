import Foundation

enum RedditClientError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case transport(String)
    case invalidResponse
    case http(statusCode: Int, message: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case authenticationRequired
    case accessDenied
    case anonymousAccessBlocked
    case notFound
    case malformedResponse
    case reddit(errors: [String])

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Reddit URL could not be constructed."
        case .transport(let message): return message
        case .invalidResponse: return "Reddit returned an invalid response."
        case .http(let statusCode, let message): return message ?? "Reddit returned HTTP \(statusCode)."
        case .rateLimited: return "Reddit is rate limiting requests. Try again shortly."
        case .authenticationRequired: return "This Reddit account needs to sign in again."
        case .anonymousAccessBlocked: return "Reddit's currently blocking unauthenticated requests; log in to continue."
        case .accessDenied: return "Reddit denied access to this content."
        case .notFound: return "Reddit could not find this content."
        case .malformedResponse: return "Reddit returned data Octonaut could not read."
        case .reddit(let errors): return errors.joined(separator: ", ")
        }
    }
}

protocol RedditClient: Sendable {
    func listing(_ request: ListingRequest, account: AccountID?) async throws -> Listing<Post>
    func post(_ permalink: URL, sort: CommentSort, account: AccountID?) async throws -> PostThread
    func moreComments(
        postFullname: String,
        parentFullname: String,
        childIDs: [String],
        sort: CommentSort,
        account: AccountID?
    ) async throws -> [CommentTreeNode]
    func search(_ request: RedditSearchRequest, account: AccountID?) async throws -> Listing<Post>
    func communities(_ request: RedditCommunitySearchRequest, account: AccountID?) async throws -> Listing<Community>
    func users(_ request: RedditUserSearchRequest, account: AccountID?) async throws -> Listing<UserProfile>
    func trendingCommunities(limit: Int, account: AccountID?) async throws -> Listing<Community>
    func subscribedCommunities(after: String?, account: AccountID) async throws -> Listing<Community>
    func blockedUsers(after: String?, account: AccountID) async throws -> Listing<UserReference>
    func userProfile(_ username: String, account: AccountID?) async throws -> UserProfile
    func userComments(
        _ username: String,
        section: UserSection,
        after: String?,
        account: AccountID?
    ) async throws -> Listing<UserComment>
    func reportOptions(community: String, account: AccountID) async throws -> RedditReportOptions
    func perform(_ action: RedditAction, account: AccountID) async throws -> ActionResult
}

extension RedditClient {
    func reportOptions(community: String, account: AccountID) async throws -> RedditReportOptions {
        throw UnavailableServiceError(service: "Reporting rules")
    }
}

/// Replaceable on-disk cache for logged-out Reddit JSON responses. Reddit's
/// cache headers often require a round trip, so Octonaut applies a short local
/// freshness window to feeds it can safely share between sessions.
enum RedditResponseCache {
    static let storage = URLCache(
        memoryCapacity: 16 * 1_024 * 1_024,
        diskCapacity: 100 * 1_024 * 1_024,
        diskPath: "OctonautRedditResponses"
    )

    private static let cachedAtHeader = "X-Octonaut-Cached-At"
    private static let freshness: TimeInterval = 15 * 60

    static var diskUsage: Int { storage.currentDiskUsage }

    static func removeAll() {
        storage.removeAllCachedResponses()
    }

    static func data(for request: URLRequest, now: Date = .now) -> Data? {
        guard let cached = storage.cachedResponse(for: request),
              let response = cached.response as? HTTPURLResponse,
              let timestamp = response.value(forHTTPHeaderField: cachedAtHeader).flatMap(TimeInterval.init),
              now.timeIntervalSince1970 - timestamp < freshness else {
            return nil
        }
        return cached.data
    }

    static func store(_ data: Data, response: HTTPURLResponse, for request: URLRequest, now: Date = .now) {
        var headers = response.allHeaderFields.reduce(into: [String: String]()) { values, pair in
            guard let key = pair.key as? String else { return }
            values[key] = String(describing: pair.value)
        }
        headers["Cache-Control"] = "max-age=900"
        headers[cachedAtHeader] = String(now.timeIntervalSince1970)
        guard let cachedResponse = HTTPURLResponse(
            url: response.url ?? request.url!,
            statusCode: response.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else { return }
        storage.storeCachedResponse(
            CachedURLResponse(response: cachedResponse, data: data, storagePolicy: .allowed),
            for: request
        )
    }
}

/// A Reddit web-session JSON client. It uses an ephemeral URLSession and asks
/// the credential vault for the selected account on every request.
actor URLSessionRedditClient: RedditClient {
    /// Reddit throttles unfamiliar clients on website routes, so every Reddit
    /// request presents the same Safari user agent.
    static let browserUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"

    private let baseURL: URL
    private let session: URLSession
    /// Signed-in requests use their own session with no cookie jar or response
    /// cache, so one account's cookies never reach another account or the
    /// anonymous path, and private responses are never written to disk.
    private let authenticatedSession: URLSession
    private let credentialVault: any AccountCredentialVault
    private let userAgent: String
    private var didBootstrapAnonymousSession = false
    private var anonymousBootstrapTask: Task<Bool, Never>?
    private var isMoreCommentsRequestInFlight = false
    private var moreCommentsRequestWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        baseURL: URL = URL(string: "https://www.reddit.com")!,
        credentialVault: any AccountCredentialVault,
        userAgent: String = URLSessionRedditClient.browserUserAgent,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        self.baseURL = baseURL
        self.credentialVault = credentialVault
        self.userAgent = userAgent

        let configuration = sessionConfiguration ?? URLSessionConfiguration.ephemeral
        let authenticatedConfiguration = configuration.copy() as! URLSessionConfiguration
        authenticatedConfiguration.httpShouldSetCookies = false
        authenticatedConfiguration.httpCookieStorage = nil
        authenticatedConfiguration.urlCache = nil
        authenticatedConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
        authenticatedConfiguration.timeoutIntervalForRequest = 30
        authenticatedConfiguration.timeoutIntervalForResource = 60
        // Ephemeral sessions keep Reddit's logged-out edge cookies in memory
        // without persisting browsing state beyond this app process.
        configuration.httpShouldSetCookies = true
        configuration.urlCache = RedditResponseCache.storage
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(
            configuration: configuration,
            delegate: RedditRedirectDelegate(),
            delegateQueue: nil
        )
        self.authenticatedSession = URLSession(
            configuration: authenticatedConfiguration,
            delegate: RedditRedirectDelegate(),
            delegateQueue: nil
        )
    }

    func listing(_ request: ListingRequest, account: AccountID? = nil) async throws -> Listing<Post> {
        let path = feedPath(request.feed)
        var query: [URLQueryItem] = [
            URLQueryItem(name: "raw_json", value: "1"),
            URLQueryItem(name: "limit", value: String(min(max(request.limit, 1), 100))),
            URLQueryItem(name: "sort", value: redditSort(request.feed.sort))
        ]
        if let topTime = request.feed.topTime, request.feed.sort.acceptsTopTime {
            query.append(URLQueryItem(name: "t", value: topTime.rawValue))
        }
        // A saved, upvoted, downvoted, hidden, or overview listing interleaves
        // posts and comments. This method can only return posts, so ask Reddit
        // for links and keep every page as full as the limit allows.
        if case .user(_, let section) = request.feed.destination, section.mixesPostsAndComments {
            query.append(URLQueryItem(name: "type", value: "links"))
        }
        appendPagination(after: request.after, before: request.before, to: &query)
        let data: Data
        do {
            data = try await requestData(
                method: "GET", path: path, query: query, body: nil,
                account: account ?? accountFromScope(request.accountScope),
                retryable: true, responseCachePolicy: request.responseCachePolicy
            )
        } catch RedditClientError.notFound {
            // The main website can return 404 for combined community listings
            // that the old website still serves. Keep the same query and session.
            guard case .combined = request.feed.destination else { throw RedditClientError.notFound }
            data = try await requestData(
                method: "GET", path: path, query: query, body: nil,
                account: account ?? accountFromScope(request.accountScope),
                retryable: true, responseCachePolicy: request.responseCachePolicy,
                websiteHost: "old.reddit.com"
            )
        }
        return try RedditJSONCodec.decodePosts(data)
    }

    func post(_ permalink: URL, sort: CommentSort, account: AccountID? = nil) async throws -> PostThread {
        let route = postJSONRoute(for: permalink)
        let query = [
            URLQueryItem(name: "raw_json", value: "1"),
            URLQueryItem(name: "sort", value: sort.rawValue)
        ]
        let data = try await requestData(
            method: "GET",
            path: route.path,
            query: query + route.query,
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodeThread(data)
    }

    func moreComments(
        postFullname: String,
        parentFullname: String,
        childIDs: [String],
        sort: CommentSort,
        account: AccountID? = nil
    ) async throws -> [CommentTreeNode] {
        guard !childIDs.isEmpty else { return [] }
        await acquireMoreCommentsRequest()
        defer { releaseMoreCommentsRequest() }
        let route = Self.moreCommentsRoute(
            postFullname: postFullname,
            childIDs: Array(childIDs.prefix(100)),
            sort: sort
        )
        let data = try await requestData(
            method: "GET",
            path: route.path,
            query: route.query,
            body: nil,
            account: account,
            retryable: true,
            responseCachePolicy: .reloadIgnoringCache
        )
        return try RedditJSONCodec.decodeMoreComments(data, parentFullname: parentFullname)
    }

    func search(_ request: RedditSearchRequest, account: AccountID? = nil) async throws -> Listing<Post> {
        let path: String
        if let community = normalizedCommunity(request.community) {
            path = "/r/\(community)/search.json"
        } else {
            path = "/search.json"
        }
        var query: [URLQueryItem] = [
            URLQueryItem(name: "raw_json", value: "1"),
            URLQueryItem(name: "q", value: request.query),
            URLQueryItem(name: "sort", value: request.sort.rawValue),
            URLQueryItem(name: "restrict_sr", value: request.community == nil ? nil : "on"),
            URLQueryItem(name: "limit", value: String(min(max(request.limit, 1), 100)))
        ]
        if let timeRange = request.timeRange {
            query.append(URLQueryItem(name: "t", value: timeRange.rawValue))
        }
        if let after = request.after { query.append(URLQueryItem(name: "after", value: after)) }
        let data = try await requestData(
            method: "GET",
            path: path,
            query: query,
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodePosts(data)
    }

    func communities(_ request: RedditCommunitySearchRequest, account: AccountID? = nil) async throws -> Listing<Community> {
        var query = [
            URLQueryItem(name: "raw_json", value: "1"),
            URLQueryItem(name: "q", value: request.query),
            URLQueryItem(name: "limit", value: String(min(max(request.limit, 1), 100)))
        ]
        if let after = request.after { query.append(URLQueryItem(name: "after", value: after)) }
        let data = try await requestData(
            method: "GET",
            path: "/subreddits/search.json",
            query: query,
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodeCommunities(data)
    }

    func users(_ request: RedditUserSearchRequest, account: AccountID? = nil) async throws -> Listing<UserProfile> {
        let route = Self.userSearchRoute(for: request)
        let data = try await requestData(
            method: "GET",
            path: route.path,
            query: route.query,
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodeUserSearch(data)
    }

    func trendingCommunities(limit: Int = 25, account: AccountID? = nil) async throws -> Listing<Community> {
        let route = Self.trendingCommunitiesRoute(limit: limit)
        let data = try await requestData(
            method: "GET",
            path: route.path,
            query: route.query,
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodeCommunities(data)
    }

    func subscribedCommunities(after: String? = nil, account: AccountID) async throws -> Listing<Community> {
        var query = [
            URLQueryItem(name: "raw_json", value: "1"),
            URLQueryItem(name: "limit", value: "100")
        ]
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        let data = try await requestData(
            method: "GET",
            path: "/subreddits/mine.json",
            query: query,
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodeCommunities(data)
    }

    func blockedUsers(after: String? = nil, account: AccountID) async throws -> Listing<UserReference> {
        var query = [URLQueryItem(name: "raw_json", value: "1"), URLQueryItem(name: "limit", value: "100")]
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        let data = try await requestData(
            method: "GET", path: "/prefs/blocked.json", query: query, body: nil,
            account: account, retryable: true, responseCachePolicy: .reloadIgnoringCache
        )
        return try RedditJSONCodec.decodeBlockedUsers(data)
    }

    func userProfile(_ username: String, account: AccountID? = nil) async throws -> UserProfile {
        let data = try await requestData(
            method: "GET",
            path: "/user/\(pathSegment(username))/about.json",
            query: [URLQueryItem(name: "raw_json", value: "1")],
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodeUserProfile(data)
    }

    func userComments(
        _ username: String,
        section: UserSection = .comments,
        after: String? = nil,
        account: AccountID? = nil
    ) async throws -> Listing<UserComment> {
        var query = [
            URLQueryItem(name: "raw_json", value: "1"),
            URLQueryItem(name: "limit", value: "50")
        ]
        if section.mixesPostsAndComments {
            query.append(URLQueryItem(name: "type", value: "comments"))
        }
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        let data = try await requestData(
            method: "GET",
            path: userSectionPath(username: username, section: section),
            query: query,
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodeUserComments(data)
    }

    func reportOptions(community: String, account: AccountID) async throws -> RedditReportOptions {
        guard RedditReportRule.validCommunity(community) else { throw RedditClientError.invalidURL }
        let data = try await requestData(
            method: "GET", path: "/r/\(community)/about/rules.json",
            query: [URLQueryItem(name: "raw_json", value: "1")], body: nil,
            account: account, retryable: true
        )
        return RedditReportOptions(
            rules: try RedditReportRule.decode(data),
            siteReasons: RedditSiteReportReason.decode(data)
        )
    }

    private func validateReport(fullname: String, community: String, reason: String, account: AccountID) async throws {
        guard RedditReportTarget.validFullname(fullname), RedditReportRule.validCommunity(community),
              !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, reason.count <= 100 else {
            throw RedditClientError.invalidResponse
        }
        guard let credential = try await credentialVault.credential(for: account),
              let modhash = credential.modhash, !modhash.isEmpty else {
            throw RedditClientError.authenticationRequired
        }
    }

    func perform(_ action: RedditAction, account: AccountID) async throws -> ActionResult {
        if case .report(let fullname, let community, let reason) = action {
            try await validateReport(fullname: fullname, community: community, reason: reason, account: account)
        }
        if case .reportSiteRule(let fullname, let community, let reason) = action {
            try await validateReport(fullname: fullname, community: community, reason: reason, account: account)
        }
        var request = Self.mutationRequest(for: action)
        if case .block(_, false) = action {
            let identityData = try await requestData(
                method: "GET",
                path: "/user/me/about.json",
                query: [URLQueryItem(name: "raw_json", value: "1")],
                body: nil,
                account: account,
                retryable: true,
                responseCachePolicy: .reloadIgnoringCache
            )
            let envelope = try JSONSerialization.jsonObject(with: identityData) as? [String: Any]
            let identity = envelope?["data"] as? [String: Any] ?? envelope
            guard let id = identity?["id"] as? String, !id.isEmpty,
                  id.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").contains($0)
                  }) else { throw RedditClientError.authenticationRequired }
            request.fields["container"] = "t2_\(id)"
        }
        let data = try await requestData(
            method: request.method,
            path: request.path,
            query: request.query,
            body: request.fields,
            account: account,
            retryable: false
        )
        switch action {
        case .report, .reportSiteRule: return try RedditReportRule.decodeSubmission(data)
        default: break
        }
        if data.isEmpty { return ActionResult(succeeded: true) }
        return try RedditJSONCodec.decodeActionResult(data)
    }

    private func requestData(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: [String: String]?,
        account: AccountID?,
        retryable: Bool,
        responseCachePolicy: ListingRequest.ResponseCachePolicy = .useCache,
        websiteHost: String? = nil
    ) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await sendRequest(
                    method: method,
                    path: path,
                    query: query,
                    body: body,
                    account: account,
                    responseCachePolicy: responseCachePolicy,
                    websiteHost: websiteHost
                )
            } catch let error as RedditClientError {
                guard retryable, attempt < 2, shouldRetry(error) else { throw error }
                let delay: TimeInterval
                if case .rateLimited(let retryAfter) = error, let retryAfter {
                    delay = min(max(retryAfter, 0.25), 30)
                } else {
                    delay = pow(2, Double(attempt)) * 0.35
                }
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                attempt += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let wrapped = RedditClientError.transport(error.localizedDescription)
                guard retryable, attempt < 2 else { throw wrapped }
                try await Task.sleep(nanoseconds: UInt64(pow(2, Double(attempt)) * 350_000_000))
                attempt += 1
            }
        }
    }

    private func sendRequest(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: [String: String]?,
        account: AccountID?,
        responseCachePolicy: ListingRequest.ResponseCachePolicy,
        websiteHost: String? = nil
    ) async throws -> Data {
        guard let url = makeURL(path: path, query: query, websiteHost: websiteHost) else { throw RedditClientError.invalidURL }
        guard RedditReportTarget.isRedditURL(url) else { throw RedditClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let cacheRequest = request

        let canUsePersistentCache = method == "GET" && account == nil
        if canUsePersistentCache,
           responseCachePolicy == .useCache,
           let cached = RedditResponseCache.data(for: cacheRequest) {
            return cached
        }
        if !canUsePersistentCache || responseCachePolicy == .reloadIgnoringCache {
            request.cachePolicy = .reloadIgnoringLocalCacheData
        }

        // A cache hit should not wait for Reddit's anonymous cookie bootstrap.
        if account == nil {
            await bootstrapAnonymousSessionIfNeeded()
        }

        if let body {
            request.httpBody = formEncoded(body)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }

        if let account {
            guard let credential = try await credentialVault.credential(for: account) else {
                throw RedditClientError.authenticationRequired
            }
            if path == "/api/report" {
                guard !credential.cookieName.isEmpty, !credential.cookieValue.isEmpty,
                      let modhash = credential.modhash, !modhash.isEmpty else {
                    throw RedditClientError.authenticationRequired
                }
            }
            request.setValue("\(credential.cookieName)=\(credential.cookieValue)", forHTTPHeaderField: "Cookie")
            if method != "GET", let modhash = credential.modhash, !modhash.isEmpty {
                request.setValue(modhash, forHTTPHeaderField: "X-Modhash")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await (account == nil ? session : authenticatedSession).data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RedditClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw RedditClientError.invalidResponse }
        try Self.validateResponse(data, response: http, isAnonymous: account == nil)
        if let result = try? RedditJSONCodec.decodeActionResult(data),
           !result.succeeded,
           let message = result.message {
            throw RedditClientError.reddit(errors: [message])
        }
        if canUsePersistentCache {
            RedditResponseCache.store(data, response: http, for: cacheRequest)
        }
        return data
    }

    static func validateResponse(_ data: Data, response http: HTTPURLResponse, isAnonymous: Bool) throws {
        // Reddit explains community-level refusals in a JSON "reason". Those are
        // not a logged-out block, so signing in would not help.
        if http.statusCode == 403 || http.statusCode == 404,
           let message = communityUnavailableMessage(data) {
            throw RedditClientError.http(statusCode: http.statusCode, message: message)
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            if isAnonymous { throw RedditClientError.anonymousAccessBlocked }
            if http.statusCode == 403 { throw RedditClientError.accessDenied }
            throw RedditClientError.authenticationRequired
        }
        if http.statusCode == 404 { throw RedditClientError.notFound }
        if http.statusCode == 429 {
            throw RedditClientError.rateLimited(retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RedditClientError.http(statusCode: http.statusCode, message: nil)
        }

        let firstNonWhitespace = data.first { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
        }
        if firstNonWhitespace == 0x3C { // '<' - an HTML login/error page
            throw isAnonymous ? RedditClientError.anonymousAccessBlocked : RedditClientError.authenticationRequired
        }
    }

    static func communityUnavailableMessage(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let reason = object["reason"] as? String else { return nil }
        switch reason {
        case "private": return "This community is private."
        case "banned": return "This community has been banned."
        case "quarantined": return "This community is quarantined. Open it on reddit.com to opt in."
        case "gated": return "This community requires confirming on reddit.com before viewing."
        case "gold_only", "premium_only": return "This community is only for Reddit Premium members."
        default: return nil
        }
    }

    private func bootstrapAnonymousSessionIfNeeded() async {
        guard !didBootstrapAnonymousSession else { return }
        if let task = anonymousBootstrapTask {
            _ = await task.value
            return
        }
        guard let url = URL(string: "https://old.reddit.com/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let task = Task { [session, request] in
            guard let (_, response) = try? await session.data(for: request),
                  let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        }
        anonymousBootstrapTask = task
        // Only the caller that created this task updates the state. Other
        // callers wait for the same request without clearing a later retry.
        didBootstrapAnonymousSession = await task.value
        anonymousBootstrapTask = nil
    }

    private func makeURL(path: String, query: [URLQueryItem], websiteHost: String? = nil) -> URL? {
        guard let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var components = baseComponents
        if let websiteHost {
            guard websiteHost == "old.reddit.com" else { return nil }
            components.host = websiteHost
        }
        guard components.scheme == "https",
              let host = components.host?.lowercased(),
              ["reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com"].contains(host),
              components.user == nil, components.password == nil,
              components.port == nil || components.port == 443 else { return nil }
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        components.queryItems = query.isEmpty ? nil : query.filter { $0.value != nil }
        // URLComponents leaves "+" as-is, and Reddit reads it as a space ("C++" becomes "C  ").
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    private func feedPath(_ request: FeedDescriptor) -> String {
        let destination: String
        switch request.destination {
        case .user(let username, let section):
            // `/user/{name}/{section}` is the whole route. Reddit takes the
            // sort as a query item here, and a trailing sort path segment
            // turns the request into a 404.
            return userSectionPath(username: username, section: section)
        case .home: destination = ""
        case .popular: destination = "/r/popular"
        case .all: destination = "/r/all"
        case .community(let name): destination = "/r/\(normalizedCommunity(name) ?? "")"
        case .combined(let names):
            let normalized = names.compactMap(normalizedCommunity).joined(separator: "+")
            destination = "/r/\(normalized)"
        case .multireddit(let owner, let name):
            destination = "/user/\(pathSegment(owner))/m/\(pathSegment(name))"
        case .search:
            destination = "/search"
        case .url(let url):
            return pathForURL(url)
        }
        let sort = redditSort(request.sort)
        return "\(destination)/\(sort).json"
    }

    private func userSectionPath(username: String, section: UserSection) -> String {
        "/user/\(pathSegment(username))/\(section.rawValue).json"
    }

    private func postJSONRoute(for permalink: URL) -> (path: String, query: [URLQueryItem]) {
        var components = URLComponents(url: permalink, resolvingAgainstBaseURL: false)
        var path = components?.path ?? permalink.path
        if !path.hasSuffix(".json") { path += ".json" }
        let query = components?.queryItems ?? []
        components?.query = nil
        return (path, query)
    }

    private func pathForURL(_ url: URL) -> String {
        var path = url.path
        if path.isEmpty { path = "/" }
        if !path.hasSuffix(".json") { path += ".json" }
        return path
    }

    static func mutationRequest(for action: RedditAction) -> (method: String, path: String, query: [URLQueryItem], fields: [String: String]) {
        switch action {
        case .report(let fullname, let community, let reason):
            return ("POST", "/api/report", [], ["thing_id": fullname, "sr_name": community, "reason": reason, "rule_reason": reason, "api_type": "json", "strict_freeform_reports": "true"])
        case .reportSiteRule(let fullname, let community, let reason):
            // Mirrors the community-rule request with Reddit's site_reason field. Strict mode
            // makes Reddit reject an unrecognised reason instead of filing it as free text.
            return ("POST", "/api/report", [], ["thing_id": fullname, "sr_name": community, "reason": reason, "site_reason": reason, "api_type": "json", "strict_freeform_reports": "true"])
        case .vote(let fullname, let direction):
            return ("POST", "/api/vote", [], ["id": fullname, "dir": String(max(-1, min(direction, 1)))])
        case .save(let fullname, let saved):
            return ("POST", saved ? "/api/save" : "/api/unsave", [], ["id": fullname])
        case .hide(let fullname, let hidden):
            return ("POST", hidden ? "/api/hide" : "/api/unhide", [], ["id": fullname])
        case .subscribe(let community, let subscribed):
            return ("POST", "/api/subscribe", [], ["action": subscribed ? "sub" : "unsub", "sr_name": community])
        case .comment(let thingID, let text):
            return ("POST", "/api/comment", [], ["thing_id": thingID, "text": text, "api_type": "json"])
        case .edit(let thingID, let text):
            return ("POST", "/api/editusertext", [], ["thing_id": thingID, "text": text, "api_type": "json"])
        case .delete(let fullname):
            return ("POST", "/api/del", [], ["id": fullname])
        case .markRead(let fullname, let read):
            return ("POST", read ? "/api/read_message" : "/api/unread_message", [], ["id": fullname])
        case .markAllRead:
            return ("POST", "/api/read_all_messages", [], [:])
        case .composeMessage(let to, let subject, let text):
            return ("POST", "/api/compose", [], ["to": to, "subject": subject, "text": text, "api_type": "json"])
        case .submitPost(let community, let title, let text, let link, let sendReplies):
            var fields: [String: String] = [
                "sr": community,
                "title": title,
                "kind": link == nil ? "self" : "link",
                "sendreplies": sendReplies ? "true" : "false",
                "api_type": "json"
            ]
            if let text, !text.isEmpty { fields["text"] = text }
            if let link { fields["url"] = link.absoluteString }
            return ("POST", "/api/submit", [], fields)
        case .crosspost(let community, let title, let sourceFullname, let sendReplies):
            return (
                "POST",
                "/api/submit",
                [],
                [
                    "sr": community,
                    "title": title,
                    "kind": "crosspost",
                    "crosspost_fullname": sourceFullname,
                    "sendreplies": sendReplies ? "true" : "false",
                    "api_type": "json"
                ]
            )
        case .block(let username, let blocked):
            if blocked {
                return ("POST", "/api/block_user", [], ["name": username, "api_type": "json"])
            }
            return ("POST", "/api/unfriend", [], ["name": username, "type": "enemy", "api_type": "json"])
        case .follow(let username, let following):
            return ("POST", "/api/subscribe", [], ["sr_name": "u_\(username)", "action": following ? "sub" : "unsub", "api_type": "json"])
        }
    }

    static func userSearchRoute(for request: RedditUserSearchRequest) -> (path: String, query: [URLQueryItem]) {
        (
            "/users/search.json",
            [
                URLQueryItem(name: "raw_json", value: "1"),
                URLQueryItem(name: "q", value: request.query),
                URLQueryItem(name: "sort", value: "relevance"),
                URLQueryItem(name: "limit", value: String(request.limit)),
            ]
        )
    }

    static func trendingCommunitiesRoute(limit: Int) -> (path: String, query: [URLQueryItem]) {
        (
            "/subreddits/popular.json",
            [
                URLQueryItem(name: "raw_json", value: "1"),
                URLQueryItem(name: "limit", value: String(min(max(limit, 1), 100))),
            ]
        )
    }

    static func moreCommentsRoute(
        postFullname: String,
        childIDs: [String],
        sort: CommentSort
    ) -> (path: String, query: [URLQueryItem]) {
        (
            "/api/morechildren",
            [
                URLQueryItem(name: "api_type", value: "json"),
                URLQueryItem(name: "link_id", value: postFullname),
                URLQueryItem(name: "children", value: childIDs.prefix(100).joined(separator: ",")),
                URLQueryItem(name: "limit_children", value: "false"),
                URLQueryItem(name: "sort", value: sort == .best ? "confidence" : sort.rawValue),
                URLQueryItem(name: "raw_json", value: "1"),
            ]
        )
    }

    private func acquireMoreCommentsRequest() async {
        if !isMoreCommentsRequestInFlight {
            isMoreCommentsRequestInFlight = true
            return
        }
        await withCheckedContinuation { continuation in
            moreCommentsRequestWaiters.append(continuation)
        }
    }

    private func releaseMoreCommentsRequest() {
        guard !moreCommentsRequestWaiters.isEmpty else {
            isMoreCommentsRequestInFlight = false
            return
        }
        moreCommentsRequestWaiters.removeFirst().resume()
    }

    private func accountFromScope(_ scope: AccountScope) -> AccountID? {
        if case .account(let account) = scope { return account }
        return nil
    }

    private func redditSort(_ sort: PostSort) -> String {
        switch sort {
        case .default: return "hot"
        default: return sort.rawValue
        }
    }

    private func normalizedCommunity(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = IDNormalization.community(value)
        guard !normalized.isEmpty,
              normalized.count <= 80,
              normalized.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == "+" }) else {
            return nil
        }
        return normalized
    }

    private func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    private func appendPagination(after: String?, before: String?, to query: inout [URLQueryItem]) {
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
    }

    private func formEncoded(_ values: [String: String]) -> Data? {
        let body = values
            .sorted { $0.key < $1.key }
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
        return body.data(using: .utf8)
    }

    private func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func shouldRetry(_ error: RedditClientError) -> Bool {
        switch error {
        case .rateLimited, .transport: return true
        default: return false
        }
    }
}

private final class RedditRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String> = [
        "www.reddit.com", "reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com"
    ]

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, RedditReportTarget.isRedditURL(url),
              let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
