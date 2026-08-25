import Foundation

/// The feeds that can be requested from Reddit's public JSON endpoints.
public enum RedditFeed: Sendable, Hashable {
    case home
    case popular
    case all
    case community(String)
    case combinedCommunities([String])
    case custom(path: String)
}

public enum RedditSort: String, Sendable, Hashable, CaseIterable {
    case hot
    case new
    case rising
    case top
    case controversial
    case gilded
    case best
}

public enum RedditTimeRange: String, Sendable, Hashable, CaseIterable {
    case hour
    case day
    case week
    case month
    case year
    case all
}

public enum RedditCommentSort: String, Sendable, Hashable, CaseIterable {
    case confidence
    case top
    case new
    case controversial
    case old
    case qa
}

public struct RedditListingRequest: Sendable, Hashable {
    public var feed: RedditFeed
    public var sort: RedditSort
    public var timeRange: RedditTimeRange?
    public var after: String?
    public var before: String?
    public var limit: Int

    public init(
        feed: RedditFeed,
        sort: RedditSort = .hot,
        timeRange: RedditTimeRange? = nil,
        after: String? = nil,
        before: String? = nil,
        limit: Int = 30
    ) {
        self.feed = feed
        self.sort = sort
        self.timeRange = timeRange
        self.after = after
        self.before = before
        self.limit = min(max(limit, 1), 100)
    }
}

public struct RedditSearchRequest: Sendable, Hashable {
    public var query: String
    public var community: String?
    public var sort: RedditSort
    public var timeRange: RedditTimeRange?
    public var after: String?
    public var limit: Int

    public init(
        query: String,
        community: String? = nil,
        sort: RedditSort = .relevance,
        timeRange: RedditTimeRange? = nil,
        after: String? = nil,
        limit: Int = 30
    ) {
        self.query = query
        self.community = community
        self.sort = sort
        self.timeRange = timeRange
        self.after = after
        self.limit = min(max(limit, 1), 100)
    }
}

public extension RedditSort {
    static var relevance: Self { .hot }
}

public struct RedditCommunitySearchRequest: Sendable, Hashable {
    public var query: String
    public var after: String?
    public var limit: Int

    public init(query: String, after: String? = nil, limit: Int = 30) {
        self.query = query
        self.after = after
        self.limit = min(max(limit, 1), 100)
    }
}

public struct RedditListing<Item: Sendable & Hashable>: Sendable, Hashable {
    public let items: [Item]
    public let after: String?
    public let before: String?

    public init(items: [Item], after: String? = nil, before: String? = nil) {
        self.items = items
        self.after = after
        self.before = before
    }
}

public enum RedditVoteState: String, Sendable, Hashable {
    case upvoted
    case downvoted
    case notVoted
    case unknown
}

public struct RedditPost: Identifiable, Sendable, Hashable {
    public let id: String
    public let fullname: String
    public let permalink: URL
    public let communityName: String?
    public let communityDisplayName: String?
    public let author: String?
    public let title: String
    public let body: String?
    public let createdAt: Date?
    public let score: Int?
    public let commentCount: Int?
    public let vote: RedditVoteState
    public let isSaved: Bool
    public let isHidden: Bool
    public let isNSFW: Bool
    public let isSpoiler: Bool
    public let isLocked: Bool
    public let isArchived: Bool
    public let isSticky: Bool
    public let thumbnailURL: URL?
    public let mediaURL: URL?
    public let domain: String?
    public let isSelfPost: Bool
    public let rawKind: String

    public init(
        id: String,
        fullname: String,
        permalink: URL,
        communityName: String? = nil,
        communityDisplayName: String? = nil,
        author: String? = nil,
        title: String,
        body: String? = nil,
        createdAt: Date? = nil,
        score: Int? = nil,
        commentCount: Int? = nil,
        vote: RedditVoteState = .unknown,
        isSaved: Bool = false,
        isHidden: Bool = false,
        isNSFW: Bool = false,
        isSpoiler: Bool = false,
        isLocked: Bool = false,
        isArchived: Bool = false,
        isSticky: Bool = false,
        thumbnailURL: URL? = nil,
        mediaURL: URL? = nil,
        domain: String? = nil,
        isSelfPost: Bool = false,
        rawKind: String = "t3"
    ) {
        self.id = id
        self.fullname = fullname
        self.permalink = permalink
        self.communityName = communityName
        self.communityDisplayName = communityDisplayName
        self.author = author
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.score = score
        self.commentCount = commentCount
        self.vote = vote
        self.isSaved = isSaved
        self.isHidden = isHidden
        self.isNSFW = isNSFW
        self.isSpoiler = isSpoiler
        self.isLocked = isLocked
        self.isArchived = isArchived
        self.isSticky = isSticky
        self.thumbnailURL = thumbnailURL
        self.mediaURL = mediaURL
        self.domain = domain
        self.isSelfPost = isSelfPost
        self.rawKind = rawKind
    }
}

public struct RedditComment: Identifiable, Sendable, Hashable {
    public let id: String
    public let fullname: String
    public let parentFullname: String?
    public let author: String?
    public let body: String?
    public let createdAt: Date?
    public let score: Int?
    public let vote: RedditVoteState
    public let isSaved: Bool
    public let isLocked: Bool
    public let isDistinguished: Bool
    public let children: [RedditComment]
    public let moreChildren: [String]

    public init(
        id: String,
        fullname: String,
        parentFullname: String? = nil,
        author: String? = nil,
        body: String? = nil,
        createdAt: Date? = nil,
        score: Int? = nil,
        vote: RedditVoteState = .unknown,
        isSaved: Bool = false,
        isLocked: Bool = false,
        isDistinguished: Bool = false,
        children: [RedditComment] = [],
        moreChildren: [String] = []
    ) {
        self.id = id
        self.fullname = fullname
        self.parentFullname = parentFullname
        self.author = author
        self.body = body
        self.createdAt = createdAt
        self.score = score
        self.vote = vote
        self.isSaved = isSaved
        self.isLocked = isLocked
        self.isDistinguished = isDistinguished
        self.children = children
        self.moreChildren = moreChildren
    }
}

public struct RedditPostThread: Sendable, Hashable {
    public let post: RedditPost?
    public let comments: [RedditComment]
    public let moreCommentIDs: [String]

    public init(post: RedditPost?, comments: [RedditComment], moreCommentIDs: [String] = []) {
        self.post = post
        self.comments = comments
        self.moreCommentIDs = moreCommentIDs
    }
}

public struct RedditCommunity: Identifiable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let displayName: String
    public let title: String?
    public let description: String?
    public let subscribers: Int?
    public let activeUsers: Int?
    public let iconURL: URL?
    public let bannerURL: URL?
    public let isNSFW: Bool

    public init(
        id: String,
        name: String,
        displayName: String? = nil,
        title: String? = nil,
        description: String? = nil,
        subscribers: Int? = nil,
        activeUsers: Int? = nil,
        iconURL: URL? = nil,
        bannerURL: URL? = nil,
        isNSFW: Bool = false
    ) {
        self.id = id
        self.name = name
        self.displayName = displayName ?? name
        self.title = title
        self.description = description
        self.subscribers = subscribers
        self.activeUsers = activeUsers
        self.iconURL = iconURL
        self.bannerURL = bannerURL
        self.isNSFW = isNSFW
    }
}

public struct RedditSearchResult: Sendable, Hashable {
    public let posts: RedditListing<RedditPost>
    public let communities: RedditListing<RedditCommunity>?

    public init(posts: RedditListing<RedditPost>, communities: RedditListing<RedditCommunity>? = nil) {
        self.posts = posts
        self.communities = communities
    }
}

public struct RedditActionResult: Sendable, Hashable {
    public let succeeded: Bool
    public let errors: [String]

    public init(succeeded: Bool, errors: [String] = []) {
        self.succeeded = succeeded
        self.errors = errors
    }
}
