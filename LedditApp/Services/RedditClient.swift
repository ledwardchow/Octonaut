import Foundation

enum RedditClientError: Error, Sendable, Equatable, LocalizedError {
    case invalidURL
    case transport(String)
    case invalidResponse
    case http(statusCode: Int, message: String?)
    case rateLimited(retryAfter: TimeInterval?)
    case authenticationRequired
    case accessDenied
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
        case .accessDenied: return "Reddit denied access to this content."
        case .notFound: return "Reddit could not find this content."
        case .malformedResponse: return "Reddit returned data Leddit could not read."
        case .reddit(let errors): return errors.joined(separator: ", ")
        }
    }
}

protocol RedditClient: Sendable {
    func listing(_ request: ListingRequest, account: AccountID?) async throws -> Listing<Post>
    func post(_ permalink: URL, sort: CommentSort, account: AccountID?) async throws -> PostThread
    func search(_ request: RedditSearchRequest, account: AccountID?) async throws -> Listing<Post>
    func communities(_ request: RedditCommunitySearchRequest, account: AccountID?) async throws -> Listing<Community>
    func subscribedCommunities(after: String?, account: AccountID) async throws -> Listing<Community>
    func userProfile(_ username: String, account: AccountID?) async throws -> UserProfile
    func userComments(_ username: String, after: String?, account: AccountID?) async throws -> Listing<UserComment>
    func perform(_ action: RedditAction, account: AccountID) async throws -> ActionResult
}

/// A Reddit web-session JSON client. It uses an ephemeral URLSession and asks
/// the credential vault for the selected account on every request.
actor URLSessionRedditClient: RedditClient {
    private let baseURL: URL
    private let session: URLSession
    private let credentialVault: any AccountCredentialVault
    private let userAgent: String
    private var didBootstrapAnonymousSession = false

    init(
        baseURL: URL = URL(string: "https://www.reddit.com")!,
        credentialVault: any AccountCredentialVault,
        userAgent: String = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
    ) {
        self.baseURL = baseURL
        self.credentialVault = credentialVault
        self.userAgent = userAgent

        let configuration = URLSessionConfiguration.ephemeral
        // Ephemeral sessions keep Reddit's logged-out edge cookies in memory
        // without persisting browsing state beyond this app process.
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        self.session = URLSession(
            configuration: configuration,
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
        if let topTime = request.feed.topTime, request.feed.sort == .top || request.feed.sort == .controversial {
            query.append(URLQueryItem(name: "t", value: topTime.rawValue))
        }
        appendPagination(after: request.after, before: request.before, to: &query)
        let data = try await requestData(
            method: "GET",
            path: path,
            query: query,
            body: nil,
            account: account ?? accountFromScope(request.accountScope),
            retryable: true
        )
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

    func userComments(_ username: String, after: String? = nil, account: AccountID? = nil) async throws -> Listing<UserComment> {
        var query = [
            URLQueryItem(name: "raw_json", value: "1"),
            URLQueryItem(name: "limit", value: "50")
        ]
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        let data = try await requestData(
            method: "GET",
            path: "/user/\(pathSegment(username))/comments.json",
            query: query,
            body: nil,
            account: account,
            retryable: true
        )
        return try RedditJSONCodec.decodeUserComments(data)
    }

    func perform(_ action: RedditAction, account: AccountID) async throws -> ActionResult {
        let request = mutationRequest(for: action)
        let data = try await requestData(
            method: request.method,
            path: request.path,
            query: request.query,
            body: request.fields,
            account: account,
            retryable: false
        )
        if data.isEmpty { return ActionResult(succeeded: true) }
        return try RedditJSONCodec.decodeActionResult(data)
    }

    private func requestData(
        method: String,
        path: String,
        query: [URLQueryItem],
        body: [String: String]?,
        account: AccountID?,
        retryable: Bool
    ) async throws -> Data {
        var attempt = 0
        while true {
            do {
                return try await sendRequest(
                    method: method,
                    path: path,
                    query: query,
                    body: body,
                    account: account
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
        account: AccountID?
    ) async throws -> Data {
        if account == nil {
            await bootstrapAnonymousSessionIfNeeded()
        }
        guard let url = makeURL(path: path, query: query) else { throw RedditClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

        if let body {
            request.httpBody = formEncoded(body)
            request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        }

        if let account {
            guard let credential = try await credentialVault.credential(for: account) else {
                throw RedditClientError.authenticationRequired
            }
            request.setValue("\(credential.cookieName)=\(credential.cookieValue)", forHTTPHeaderField: "Cookie")
            if method != "GET", let modhash = credential.modhash, !modhash.isEmpty {
                request.setValue(modhash, forHTTPHeaderField: "X-Modhash")
            }
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw RedditClientError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { throw RedditClientError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 {
            if http.statusCode == 403 { throw RedditClientError.accessDenied }
            throw RedditClientError.authenticationRequired
        }
        if http.statusCode == 404 { throw RedditClientError.notFound }
        if http.statusCode == 429 {
            throw RedditClientError.rateLimited(retryAfter: retryAfter(from: http))
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RedditClientError.http(statusCode: http.statusCode, message: nil)
        }

        let firstNonWhitespace = data.first { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
        }
        if firstNonWhitespace == 0x3C { // '<' - an HTML login/error page
            throw RedditClientError.authenticationRequired
        }
        if let result = try? RedditJSONCodec.decodeActionResult(data),
           !result.succeeded,
           let message = result.message {
            throw RedditClientError.reddit(errors: [message])
        }
        return data
    }

    private func bootstrapAnonymousSessionIfNeeded() async {
        guard !didBootstrapAnonymousSession else { return }
        didBootstrapAnonymousSession = true
        guard let url = URL(string: "https://old.reddit.com/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        do {
            _ = try await session.data(for: request)
        } catch {
            // A later manual refresh should be able to retry the cookie seed.
            didBootstrapAnonymousSession = false
        }
    }

    private func makeURL(path: String, query: [URLQueryItem]) -> URL? {
        guard let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        var components = baseComponents
        components.path = path.hasPrefix("/") ? path : "/\(path)"
        components.queryItems = query.filter { $0.value != nil }
        return components.url
    }

    private func feedPath(_ request: FeedDescriptor) -> String {
        let destination: String
        switch request.destination {
        case .home: destination = ""
        case .popular: destination = "/r/popular"
        case .all: destination = "/r/all"
        case .community(let name): destination = "/r/\(normalizedCommunity(name) ?? "")"
        case .combined(let names):
            let normalized = names.compactMap(normalizedCommunity).joined(separator: "+")
            destination = "/r/\(normalized)"
        case .multireddit(let owner, let name):
            destination = "/user/\(pathSegment(owner))/m/\(pathSegment(name))"
        case .user(let username, let section):
            destination = "/user/\(pathSegment(username))/\(section.rawValue)"
        case .search:
            destination = "/search"
        case .url(let url):
            return pathForURL(url)
        }
        let sort = redditSort(request.sort)
        return "\(destination)/\(sort).json"
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

    private func mutationRequest(for action: RedditAction) -> (method: String, path: String, query: [URLQueryItem], fields: [String: String]) {
        switch action {
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
        case .block(let username, let blocked):
            return ("POST", "/api/block_user", [], ["name": username, "container": blocked ? "" : "unblock"])
        case .follow(let username, let following):
            return ("POST", "/api/friend", [], ["name": username, "note": following ? "" : "unfollow"])
        }
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

    private func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(value)
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
        guard let host = request.url?.host?.lowercased(), allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
