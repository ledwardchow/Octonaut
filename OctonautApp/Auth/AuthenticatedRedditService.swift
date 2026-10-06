import Foundation

protocol AuthenticatedRedditService: Sendable {
    /// Pass the previous page's `after` cursor to load older items.
    func fetchInbox(section: InboxSection, after: String?, accountID: AccountID) async throws -> Listing<InboxItem>
    func fetchConversation(messageID: String, accountID: AccountID) async throws -> [Message]
    func perform(_ action: RedditAction, accountID: AccountID) async throws -> ActionResult
}

extension AuthenticatedRedditService {
    func fetchInbox(section: InboxSection, accountID: AccountID) async throws -> Listing<InboxItem> {
        try await fetchInbox(section: section, after: nil, accountID: accountID)
    }
}

actor LiveAuthenticatedRedditService: AuthenticatedRedditService {
    private let credentialVault: any AccountCredentialVault
    private let reddit: any RedditClient
    private let session: URLSession
    private let baseURL: URL

    init(
        credentialVault: any AccountCredentialVault,
        reddit: any RedditClient,
        baseURL: URL = URL(string: "https://www.reddit.com")!,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.credentialVault = credentialVault
        self.reddit = reddit
        self.baseURL = baseURL
        let configuration = sessionConfiguration
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        session = URLSession(configuration: configuration, delegate: AuthenticatedRedirectDelegate(), delegateQueue: nil)
    }

    func fetchInbox(section: InboxSection, after: String?, accountID: AccountID) async throws -> Listing<InboxItem> {
        let data = try await request(path: "/message/\(section.rawValue).json", after: after, accountID: accountID)
        return try Self.decodeInbox(data)
    }

    func fetchConversation(messageID: String, accountID: AccountID) async throws -> [Message] {
        let shortID = messageID.hasPrefix("t4_") ? String(messageID.dropFirst(3)) : messageID
        guard !shortID.isEmpty, shortID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw RedditClientError.invalidURL
        }
        let encodedID = shortID
        // Reddit nests the rest of a private message thread under the first message's replies.
        let listing = try Self.decodeInbox(
            try await request(path: "/message/messages/\(encodedID).json", after: nil, accountID: accountID),
            includeReplies: true
        )
        return listing.items
            .map {
                Message(
                    id: $0.id,
                    conversationID: $0.conversationFullname ?? $0.fullname,
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

    private func request(path: String, after: String?, accountID: AccountID) async throws -> Data {
        guard let credential = try await credentialVault.credential(for: accountID) else {
            throw RedditClientError.authenticationRequired
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = path
        components?.queryItems = [URLQueryItem(name: "raw_json", value: "1"), URLQueryItem(name: "limit", value: "100")]
            + (after.map { [URLQueryItem(name: "after", value: $0)] } ?? [])
        guard let url = components?.url, RedditReportTarget.isRedditURL(url) else { throw RedditClientError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("\(credential.cookieName)=\(credential.cookieValue)", forHTTPHeaderField: "Cookie")
        request.setValue(URLSessionRedditClient.browserUserAgent, forHTTPHeaderField: "User-Agent")
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

    static func decodeInbox(_ data: Data, includeReplies: Bool = false) throws -> Listing<InboxItem> {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let listing = root["data"] as? [String: Any] else {
            throw RedditClientError.malformedResponse
        }
        var children = listing["children"] as? [[String: Any]] ?? []
        if includeReplies {
            func flatten(_ child: [String: Any]) -> [[String: Any]] {
                let replies = ((child["data"] as? [String: Any])?["replies"] as? [String: Any])?["data"] as? [String: Any]
                return [child] + (replies?["children"] as? [[String: Any]] ?? []).flatMap(flatten)
            }
            children = children.flatMap(flatten)
        }
        let items = children.compactMap { child -> InboxItem? in
            let payload = child["data"] as? [String: Any] ?? child
            guard let id = string(payload, "id") ?? string(payload, "name") else { return nil }
            let isComment = payload["was_comment"] as? Bool == true || string(child, "kind") == "t1"
            let fullname = string(payload, "name") ?? IDNormalization.fullname(id, kind: isComment ? "t1" : "t4")
            let subject = string(payload, "subject") ?? "Reddit notification"
            let body = string(payload, "body").map { RichText(plainText: $0) }
                ?? string(payload, "body_html").map { RichText(plainText: stripMarkup($0)) }
            let author = string(payload, "author") ?? string(payload, "author_name")
            let community = string(payload, "subreddit")
            let permalink = ["context", "permalink", "link_permalink"].compactMap { key -> URL? in
                guard let value = string(payload, key),
                      let url = URL(string: value, relativeTo: URL(string: "https://www.reddit.com")!)?.absoluteURL,
                      RedditReportTarget.isRedditURL(url) else { return nil }
                return url
            }.first
            let timestamp = number(payload, "created_utc") ?? Date().timeIntervalSince1970
            let unread = payload["new"] as? Bool ?? false
            return InboxItem(
                id: id,
                fullname: fullname,
                subject: subject,
                body: body,
                author: author.map(UserReference.init(username:)),
                community: community.map { CommunityReference(name: $0) },
                postPermalink: permalink,
                createdAt: Date(timeIntervalSince1970: timestamp),
                isRead: !unread,
                kind: isComment ? (subject.localizedCaseInsensitiveContains("mention") ? "mention" : "reply") : fullname.hasPrefix("t4_") ? "message" : "reply",
                conversationFullname: string(payload, "first_message_name")
                    ?? string(payload, "first_message").map { IDNormalization.fullname($0, kind: "t4") }
            )
        }
        return Listing(items: items, after: listing["after"] as? String, before: listing["before"] as? String)
    }

    private static func string(_ object: [String: Any], _ key: String) -> String? {
        (object[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func number(_ object: [String: Any], _ key: String) -> TimeInterval? {
        if let value = object[key] as? NSNumber { return value.doubleValue }
        if let value = object[key] as? String { return TimeInterval(value) }
        return nil
    }

    private static let markupRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "<[^>]+>")
        } catch {
            fatalError("Invalid markupRegex: \(error)")
        }
    }()

    private static func stripMarkup(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<br />", with: "\n")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
        result = Self.markupRegex.stringByReplacingMatches(
            in: result,
            range: NSRange(result.startIndex..., in: result),
            withTemplate: ""
        )
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

actor FixtureAuthenticatedRedditService: AuthenticatedRedditService {
    func fetchInbox(section: InboxSection, after: String?, accountID: AccountID) async throws -> Listing<InboxItem> {
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
        guard let url = request.url, RedditReportTarget.isRedditURL(url),
              let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
