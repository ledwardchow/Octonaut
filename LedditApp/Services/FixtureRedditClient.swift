import Foundation

/// Fixture-backed client used by previews, UI tests, and offline development.
/// It never creates a URLSession and therefore cannot contact Reddit.
actor FixtureRedditClient: RedditClient {
    private let listingData: Data?
    private let postData: Data?
    private let searchData: Data?
    private let communitiesData: Data?
    private let actionResult: ActionResult

    init(
        listingData: Data? = nil,
        postData: Data? = nil,
        searchData: Data? = nil,
        communitiesData: Data? = nil,
        actionResult: ActionResult = ActionResult(succeeded: true)
    ) {
        self.listingData = listingData
        self.postData = postData
        self.searchData = searchData
        self.communitiesData = communitiesData
        self.actionResult = actionResult
    }

    init(directoryURL: URL) throws {
        func read(_ name: String) throws -> Data? {
            let url = directoryURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        }
        self.listingData = try read("listing.json")
        self.postData = try read("post.json")
        self.searchData = try read("search.json")
        self.communitiesData = try read("communities.json")
        self.actionResult = ActionResult(succeeded: true)
    }

    func listing(_ request: ListingRequest, account: AccountID? = nil) async throws -> Listing<Post> {
        guard let listingData else { return Listing(items: []) }
        return try RedditJSONCodec.decodePosts(listingData)
    }

    func post(_ permalink: URL, sort: CommentSort, account: AccountID? = nil) async throws -> PostThread {
        guard let postData else { throw RedditClientError.notFound }
        return try RedditJSONCodec.decodeThread(postData)
    }

    func search(_ request: RedditSearchRequest, account: AccountID? = nil) async throws -> Listing<Post> {
        guard let searchData else { return Listing(items: []) }
        return try RedditJSONCodec.decodePosts(searchData)
    }

    func communities(_ request: RedditCommunitySearchRequest, account: AccountID? = nil) async throws -> Listing<Community> {
        guard let communitiesData else { return Listing(items: []) }
        return try RedditJSONCodec.decodeCommunities(communitiesData)
    }

    func subscribedCommunities(after: String? = nil, account: AccountID) async throws -> Listing<Community> {
        guard let communitiesData else { return Listing(items: []) }
        return try RedditJSONCodec.decodeCommunities(communitiesData)
    }

    func userProfile(_ username: String, account: AccountID? = nil) async throws -> UserProfile {
        UserProfile(
            reference: UserReference(username: username),
            avatarURL: nil,
            createdAt: .now.addingTimeInterval(-6 * 365 * 24 * 60 * 60),
            karma: 60_800,
            about: RichText(plainText: "A fixture profile for offline previews."),
            isBlocked: false,
            isFollowing: false
        )
    }

    func userComments(_ username: String, after: String? = nil, account: AccountID? = nil) async throws -> Listing<UserComment> {
        Listing(items: [])
    }

    func perform(_ action: RedditAction, account: AccountID) async throws -> ActionResult {
        actionResult
    }
}
