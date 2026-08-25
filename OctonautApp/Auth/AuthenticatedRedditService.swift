import Foundation

protocol AuthenticatedRedditService: Sendable {
    func fetchInbox(section: InboxSection, accountID: AccountID) async throws -> Listing<InboxItem>
    func fetchConversation(messageID: String, accountID: AccountID) async throws -> [Message]
    func perform(_ action: RedditAction, accountID: AccountID) async throws -> ActionResult
}

actor LiveAuthenticatedRedditService: AuthenticatedRedditService {
    private let credentialVault: any AccountCredentialVault
    private let reddit: any RedditClient
    private let session: URLSession
    private let baseURL: URL

    init(
        credentialVault: any AccountCredentialVault,
        reddit: any RedditClient,
        baseURL: URL = URL(string: "https://www.reddit.com")!
    ) {
        self.credentialVault = credentialVault
        self.reddit = reddit
        self.baseURL = baseURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: AuthenticatedRedirectDelegate(), delegateQueue: nil)
    }

    func fetchInbox(section: InboxSection, accountID: AccountID) async throws -> Listing<InboxItem> {
        let data = try await request(path: "/message/\(section.rawValue).json", accountID: accountID)
        return try decodeInbox(data)
    }

    func fetchConversation(messageID: String, accountID: AccountID) async throws -> [Message] {
        let encodedID = messageID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageID
        let listing: Listing<InboxItem>
        do {
            listing = try decodeInbox(try await request(path: "/message/messages/\(encodedID).json", accountID: accountID))
        } catch {
            listing = try await fetchInbox(section: .messages, accountID: accountID)
        }
        return listing.items.filter { $0.id == messageID || $0.fullname == messageID || listing.items.count > 1 }
            .map {
                Message(
                    id: $0.id,
                    conversationID: $0.id,
                    sender: $0.author,
                    recipient: nil,
                    subject: $0.subject,
                    body: $0.body ?? RichText(plainText: ""),
                    createdAt: $0.createdAt,
                    isRead: $0.isRead
                )
            }
    }

    func perform(_ action: RedditAction, accountID: AccountID) async throws -> ActionResult {
        try await reddit.perform(action, account: accountID)
    }

    private func request(path: String, accountID: AccountID) async throws -> Data {
        guard let credential = try await credentialVault.credential(for: accountID) else {
            throw RedditClientError.authenticationRequired
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = [URLQueryItem(name: "raw_json", value: "1"), URLQueryItem(name: "limit", value: "100")]
        guard let url = components?.url else { throw RedditClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("\(credential.cookieName)=\(credential.cookieValue)", forHTTPHeaderField: "Cookie")
        request.setValue("Octonaut/1.0 (iOS; Reddit reader)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RedditClientError.invalidResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw RedditClientError.authenticationRequired }
        if http.statusCode == 429 { throw RedditClientError.rateLimited(retryAfter: nil) }
        guard (200..<300).contains(http.statusCode) else { throw RedditClientError.http(statusCode: http.statusCode, message: nil) }
        if data.first(where: { byte in
            byte != 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D
        }) == 0x3C { throw RedditClientError.authenticationRequired }
        return data
    }

    private func decodeInbox(_ data: Data) throws -> Listing<InboxItem> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listing = root["data"] as? [String: Any] else {
            throw RedditClientError.malformedResponse
        }
        let children = listing["children"] as? [[String: Any]] ?? []
        let items = children.compactMap { child -> InboxItem? in
            let payload = child["data"] as? [String: Any] ?? child
            guard let id = string(payload, "id") ?? string(payload, "name") else { return nil }
            let fullname = string(payload, "name") ?? IDNormalization.fullname(id, kind: "t4")
            let subject = string(payload, "subject") ?? "Reddit notification"
            let bodyText = string(payload, "body") ?? string(payload, "body_html").map(stripMarkup)
            let author = string(payload, "author") ?? string(payload, "author_name")
            let community = string(payload, "subreddit")
            let permalink = (string(payload, "link_permalink") ?? string(payload, "permalink")).flatMap(URL.init(string:))
            let timestamp = number(payload, "created_utc") ?? Date().timeIntervalSince1970
            let unread = payload["new"] as? Bool ?? false
            return InboxItem(
                id: id,
                fullname: fullname,
                subject: subject,
                body: bodyText.map { RichText(plainText: stripMarkup($0)) },
                author: author.map(UserReference.init(username:)),
                community: community.map { CommunityReference(name: $0) },
                postPermalink: permalink,
                createdAt: Date(timeIntervalSince1970: timestamp),
                isRead: !unread,
                kind: string(child, "kind") ?? string(payload, "type") ?? "notification"
            )
        }
        return Listing(items: items, after: listing["after"] as? String, before: listing["before"] as? String)
    }

    private func string(_ object: [String: Any], _ key: String) -> String? {
        (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private func number(_ object: [String: Any], _ key: String) -> TimeInterval? {
        if let value = object[key] as? NSNumber { return value.doubleValue }
        if let value = object[key] as? String { return TimeInterval(value) }
        return nil
    }

    private func stripMarkup(_ value: String) -> String {
        value
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor FixtureAuthenticatedRedditService: AuthenticatedRedditService {
    func fetchInbox(section: InboxSection, accountID: AccountID) async throws -> Listing<InboxItem> {
        Listing(items: [])
    }

    func fetchConversation(messageID: String, accountID: AccountID) async throws -> [Message] {
        []
    }

    func perform(_ action: RedditAction, accountID: AccountID) async throws -> ActionResult {
        ActionResult(succeeded: true)
    }
}

private final class AuthenticatedRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String> = ["www.reddit.com", "reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com"]

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

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
