import Foundation

struct UnavailableRedditClient: RedditClient {
    func listing(_ request: ListingRequest, account: AccountID?) async throws -> Listing<Post> {
        throw DisplayableError(title: "Reddit is not connected", message: "The Reddit transport has not been configured yet.")
    }

    func post(_ permalink: URL, sort: CommentSort, account: AccountID?) async throws -> PostThread {
        throw DisplayableError(title: "Reddit is not connected", message: "The Reddit transport has not been configured yet.")
    }

    func search(_ request: RedditSearchRequest, account: AccountID?) async throws -> Listing<Post> {
        throw DisplayableError(title: "Reddit is not connected", message: "The Reddit transport has not been configured yet.")
    }

    func communities(_ request: RedditCommunitySearchRequest, account: AccountID?) async throws -> Listing<Community> {
        throw DisplayableError(title: "Reddit is not connected", message: "The Reddit transport has not been configured yet.")
    }

    func subscribedCommunities(after: String?, account: AccountID) async throws -> Listing<Community> {
        throw DisplayableError(title: "Reddit is not connected", message: "The Reddit transport has not been configured yet.")
    }

    func userProfile(_ username: String, account: AccountID?) async throws -> UserProfile {
        throw DisplayableError(title: "Reddit is not connected", message: "The Reddit transport has not been configured yet.")
    }

    func userComments(_ username: String, after: String?, account: AccountID?) async throws -> Listing<UserComment> {
        throw DisplayableError(title: "Reddit is not connected", message: "The Reddit transport has not been configured yet.")
    }

    func perform(_ action: RedditAction, account: AccountID) async throws -> ActionResult {
        throw DisplayableError(title: "Reddit is not connected", message: "The Reddit transport has not been configured yet.")
    }
}

struct UnavailableMediaService: MediaService {
    func exportVideo(source: URL, audio: URL?, cleanupDate: Date?) async throws -> ExportJob {
        throw DisplayableError(title: "Export unavailable", message: "Media export is not configured yet.")
    }

    func cancelExport(_ id: UUID) async {}
}

struct DefaultLinkRouter: LinkRouter {
    func route(_ url: URL) -> AppRoute? {
        guard let host = url.host?.lowercased() else { return nil }
        let redditHosts = ["reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com"]
        guard redditHosts.contains(host) || host == "redd.it" else { return nil }
        if postIdentifier(from: url) != nil {
            return .post(url)
        }
        let components = url.pathComponents
        if let index = components.firstIndex(of: "r"), components.indices.contains(index + 1) {
            return .community(components[index + 1])
        }
        return .web(url)
    }

    func canonicalURL(for url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        if components.host?.lowercased() == "redd.it" { return url }
        components.scheme = "https"
        components.host = "www.reddit.com"
        components.queryItems = components.queryItems?.filter { !["utm_source", "utm_medium", "utm_campaign", "share_id"].contains($0.name.lowercased()) }
        return components.url ?? url
    }

    private func postIdentifier(from url: URL) -> String? {
        let components = url.pathComponents
        guard let commentsIndex = components.firstIndex(of: "comments"), components.indices.contains(commentsIndex + 1) else { return nil }
        return components[commentsIndex + 1]
    }
}
