import Foundation

/// The persisted queries used only for the repaired r/all and search screens.
private enum GraphQLOperation {
    case allFeed, postsByIDs, searchPosts, searchCommunities, searchPeople

    var name: String {
        switch self {
        case .allFeed: "AllFeedSdui"
        case .postsByIDs: "PostsByIds"
        case .searchPosts: "SearchPosts"
        case .searchCommunities: "CommunityPickerSearchPaginated"
        case .searchPeople: "SearchPeople"
        }
    }

    var hash: String {
        switch self {
        case .allFeed: "dea8ebf08bd9127a580fd664b9c312e590a195690f5c04c32d60b9370d876fb0"
        case .postsByIDs: "b210ea1d852cdc2c25d9bff2d9fa8a406e1a968f36392798812f336694ac27f4"
        case .searchPosts: "c3d31b88bfa15180fdcd0c8f6f13b8c0e131d0c981c9b9c8a7c537ddd0ed3348"
        case .searchCommunities: "b58025ad0c98bdb93e9dc1db909accf440573bd7d3a48d2c73a02e96d33f1943"
        case .searchPeople: "db3607c1a7deea8441614a053c5f434f60da0c8c931db952f819a59d534d9743"
        }
    }
}

private enum GraphQLValue: Encodable, Sendable {
    case string(String), int(Int), bool(Bool), array([GraphQLValue]), object([String: GraphQLValue])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
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
        guard account != nil else { throw RedditClientError.anonymousAccessBlocked }
        guard case .all = request.feed.destination else { throw unsupportedRequest() }
        guard request.before == nil else { throw unsupportedRequest() }
        let sort = try feedSort(request.feed.sort)
        var variables: [String: GraphQLValue] = ["sort": .string(sort)]
        if let time = request.feed.topTime { variables["time"] = .string(time.rawValue.uppercased()) }
        if let after = request.after {
            guard after.hasPrefix("t3_") else { throw unsupportedRequest() }
            variables["after"] = .string(Data(after.utf8).base64EncodedString())
        }
        let feedData = try await execute(.allFeed, variables: variables, account: account)
        let IDs = try RedditGraphQLCodec.feedPostIDs(data: feedData)
        let selected = Array(IDs.prefix(request.limit))
        guard !selected.isEmpty else { return Listing(items: []) }
        var postVariables = Self.postsByIDsVariables
        postVariables["ids"] = .array(selected.map(GraphQLValue.string))
        let postData = try await execute(.postsByIDs, variables: postVariables, account: account)
        let posts = try RedditGraphQLCodec.posts(data: postData, orderedIDs: selected)
        return Listing(items: posts, after: selected.last)
    }

    func search(_ request: RedditSearchRequest, account: AccountID?) async throws -> Listing<Post> {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
        let sort = try searchSort(request.sort)
        var variables = Self.postFragmentVariables
        variables["query"] = .string(request.query)
        variables["productSurface"] = .string("android")
        variables["pageSize"] = .int(request.limit)
        variables["sort"] = .string(sort)
        if let after = request.after { variables["afterCursor"] = .string(after) }
        var filters: [GraphQLValue] = []
        if let time = request.timeRange {
            filters.append(.object(["key": .string("time_range"), "value": .string(time.rawValue)]))
        }
        if let community = request.community {
            let name = community.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^/?r/", with: "", options: [.regularExpression, .caseInsensitive])
            if !name.isEmpty && name.lowercased() != "all" && name.lowercased() != "popular" {
                filters.append(.object(["key": .string("subreddit_names"), "value": .string(name)]))
            }
        }
        if !filters.isEmpty { variables["filters"] = .array(filters) }
        return try RedditGraphQLCodec.searchPosts(data: await execute(.searchPosts, variables: variables, account: account))
    }

    func communities(_ request: RedditCommunitySearchRequest, account: AccountID?) async throws -> Listing<Community> {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
        var variables: [String: GraphQLValue] = [
            "query": .string(request.query.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "^/?r/", with: "", options: [.regularExpression, .caseInsensitive])),
            "productSurface": .string("android"), "first": .int(request.limit)
        ]
        if let after = request.after { variables["after"] = .string(after) }
        return try RedditGraphQLCodec.communities(data: await execute(.searchCommunities, variables: variables, account: account))
    }

    func users(_ request: RedditUserSearchRequest, account: AccountID?) async throws -> Listing<UserProfile> {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
        let variables: [String: GraphQLValue] = ["query": .string(request.query), "productSurface": .string("android"),
                                                 "pageSize": .int(request.limit)]
        return try RedditGraphQLCodec.users(data: await execute(.searchPeople, variables: variables, account: account))
    }

    private func execute(_ operation: GraphQLOperation, variables: [String: GraphQLValue], account: AccountID?) async throws -> Data {
        guard let account else { throw RedditClientError.anonymousAccessBlocked }
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
        guard let root = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let data = root["data"] as? [String: Any], !data.isEmpty else {
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
        if let existing = refreshTasks[account] { return try await existing.task.value }
        do { try await confirmSession(account: account, digest: digest) }
        catch {
            if let existing = refreshTasks[account] { return try await existing.task.value }
            throw error
        }
        if let existing = refreshTasks[account] { return try await existing.task.value }
        let task = Task { try await bootstrapToken(for: account, credential: credential, digest: digest) }
        refreshTasks[account] = (digest, task)
        defer { if refreshTasks[account]?.digest == digest { refreshTasks.removeValue(forKey: account) } }
        return try await task.value
    }

    private func confirmSession(account: AccountID, digest: String) async throws {
        guard let current = try await credentialVault.credential(for: account),
              current.cookieName == "reddit_session",
              RedditSessionIdentity.digest(current.cookieValue) == digest else {
            throw RedditClientError.authenticationRequired
        }
    }

    private func bootstrapToken(for account: AccountID, credential: RedditCredential, digest: String) async throws -> WebGraphQLToken {
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
            guard try await credentialVault.replaceSessionCookie(renewed.value, expected: credential.cookieValue, for: account) else {
                throw RedditClientError.authenticationRequired
            }
            sessionValue = renewed.value
            sessionDigest = RedditSessionIdentity.digest(sessionValue)
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

    private static let postsByIDsVariables: [String: GraphQLValue] = {
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
