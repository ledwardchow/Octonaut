import Foundation
import Observation

extension PostMedia {
    fileprivate var thumbnailURL: URL? {
        switch self {
        case .image(_, let thumbnail, _, _): return thumbnail
        case .video(_, _, let thumbnail, _): return thumbnail
        case .gallery(let items): return items.first?.thumbnailURL
        case .link(_, let metadata): return metadata?.imageURL
        case .none, .poll, .unsupported: return nil
        }
    }

    fileprivate var galleryURLs: [URL] {
        if case .gallery(let items) = self { return items.map(\.url) }
        if let primaryURL { return [primaryURL] }
        return []
    }

    fileprivate var audioURL: URL? {
        if case .video(_, let audio, _, _) = self { return audio }
        return nil
    }
}

// MARK: - Presentation models

/// These small presentation models are deliberately independent from Reddit DTOs.
/// The Domain layer can map its Post/Comment/Community values into them, while
/// previews and the initial app shell remain usable without a network client.
struct PostCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var community: String
    var author: String
    var authorFlair: Flair?
    var title: String
    var body: String
    var flair: Flair?
    var score: Int
    var comments: Int
    var age: String
    var vote: Int
    var isSaved: Bool
    var isSeen: Bool
    var isNSFW: Bool
    var isSpoiler: Bool
    var isSticky: Bool
    var isVideo: Bool
    var hasMedia: Bool
    var mediaTitle: String
    var shareURL: URL
    var mediaURL: URL?
    var thumbnailURL: URL?
    var mediaKind: String
    var galleryURLs: [URL]
    var audioURL: URL?

    var isSensitive: Bool { isNSFW || isSpoiler }
    var fullname: String { IDNormalization.fullname(id, kind: "t3") }

    init(
        id: String,
        community: String,
        author: String,
        authorFlair: Flair? = nil,
        title: String,
        body: String,
        flair: Flair? = nil,
        score: Int,
        comments: Int,
        age: String,
        vote: Int,
        isSaved: Bool,
        isSeen: Bool,
        isNSFW: Bool,
        isSpoiler: Bool,
        isSticky: Bool,
        isVideo: Bool,
        hasMedia: Bool,
        mediaTitle: String,
        shareURL: URL,
        mediaURL: URL? = nil,
        thumbnailURL: URL? = nil,
        mediaKind: String = "none",
        galleryURLs: [URL] = [],
        audioURL: URL? = nil
    ) {
        self.id = id
        self.community = community
        self.author = author
        self.authorFlair = authorFlair
        self.title = title
        self.body = body
        self.flair = flair
        self.score = score
        self.comments = comments
        self.age = age
        self.vote = vote
        self.isSaved = isSaved
        self.isSeen = isSeen
        self.isNSFW = isNSFW
        self.isSpoiler = isSpoiler
        self.isSticky = isSticky
        self.isVideo = isVideo
        self.hasMedia = hasMedia
        self.mediaTitle = mediaTitle
        self.shareURL = shareURL
        self.mediaURL = mediaURL
        self.thumbnailURL = thumbnailURL
        self.mediaKind = mediaKind
        self.galleryURLs = galleryURLs
        self.audioURL = audioURL
    }

    init(post: Post) {
        self.init(
            id: post.id,
            community: post.community.name,
            author: post.author?.username ?? "",
            authorFlair: post.authorFlair,
            title: post.title,
            body: Self.displayBody(for: post),
            flair: post.flair,
            score: post.score ?? 0,
            comments: post.commentCount,
            age: post.createdAt.formatted(.relative(presentation: .named)),
            vote: post.vote.direction,
            isSaved: post.isSaved,
            isSeen: post.isHidden,
            isNSFW: post.isNSFW,
            isSpoiler: post.isSpoiler,
            isSticky: post.isSticky,
            isVideo: ["video", "gif", "embeddedVideo"].contains(post.media.kind),
            hasMedia: post.media.kind != "none",
            mediaTitle: post.media.kind.capitalized,
            shareURL: post.permalink,
            mediaURL: post.media.primaryURL,
            thumbnailURL: post.media.thumbnailURL,
            mediaKind: post.media.kind,
            galleryURLs: post.media.galleryURLs,
            audioURL: post.media.audioURL
        )
    }

    private static func displayBody(for post: Post) -> String {
        guard let body = post.body?.plainText else { return "" }

        if post.media.kind == "embeddedVideo" || post.media.kind == "video",
           let mediaURL = post.media.primaryURL,
           let range = body.range(of: mediaURL.absoluteString) {
            return body.replacingCharacters(in: range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard post.media.kind == "image", let mediaURL = post.media.primaryURL else {
            return body
        }

        let visibleLines = body.components(separatedBy: .newlines).filter { line in
            let candidate = line.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "&amp;", with: "&")
            return URL(string: candidate) != mediaURL
        }
        return visibleLines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Creates the small amount of identity needed to render a detail route
    /// before the Reddit transport has returned the full post. The detail
    /// task replaces this placeholder with the decoded post when available.
    init(deepLinkURL: URL) {
        let components = deepLinkURL.pathComponents
        let commentsIndex = components.firstIndex {
            $0.caseInsensitiveCompare("comments") == .orderedSame
        }
        let id =
            commentsIndex.flatMap { index in
                components.indices.contains(index + 1) ? components[index + 1] : nil
            } ?? components.last(where: { $0 != "/" && !$0.isEmpty }) ?? deepLinkURL.absoluteString
        let communityIndex = components.firstIndex { $0.caseInsensitiveCompare("r") == .orderedSame }
        let community =
            communityIndex.flatMap { index in
                components.indices.contains(index + 1) ? components[index + 1] : nil
            } ?? "reddit"

        self.init(
            id: id,
            community: community,
            author: "",
            title: "Loading post…",
            body: "",
            score: 0,
            comments: 0,
            age: "",
            vote: 0,
            isSaved: false,
            isSeen: false,
            isNSFW: false,
            isSpoiler: false,
            isSticky: false,
            isVideo: false,
            hasMedia: false,
            mediaTitle: "",
            shareURL: deepLinkURL
        )
    }

    static let sample = PostCardModel(
        id: "t3_sample-1",
        community: "apple",
        author: "example_author",
        title: "What small iOS detail makes your day better?",
        body:
            "A place for practical tips, thoughtful discussion, and the little details that make an app feel native.",
        score: 1_284,
        comments: 218,
        age: "3h",
        vote: 1,
        isSaved: false,
        isSeen: false,
        isNSFW: false,
        isSpoiler: false,
        isSticky: false,
        isVideo: false,
        hasMedia: false,
        mediaTitle: "",
        shareURL: URL(string: "https://www.reddit.com/r/apple/comments/sample")!
    )

    static let mediaSample = PostCardModel(
        id: "t3_sample-2",
        community: "iphone",
        author: "pixel_wrangler",
        title: "A quiet desk setup for a focused afternoon",
        body: "",
        score: 864,
        comments: 74,
        age: "5h",
        vote: 0,
        isSaved: true,
        isSeen: false,
        isNSFW: false,
        isSpoiler: false,
        isSticky: false,
        isVideo: false,
        hasMedia: true,
        mediaTitle: "Image preview",
        shareURL: URL(string: "https://www.reddit.com/r/iphone/comments/sample2")!
    )
}

struct CommunityCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    var iconURL: URL?
    var memberCount: Int?
    var isSubscribed: Bool
    var isFavorite: Bool

    init(
        name: String,
        iconURL: URL? = nil,
        memberCount: Int? = nil,
        isSubscribed: Bool = false,
        isFavorite: Bool = false
    ) {
        self.id = name.lowercased()
        self.name = name
        self.iconURL = iconURL
        self.memberCount = memberCount
        self.isSubscribed = isSubscribed
        self.isFavorite = isFavorite
    }

    init(community: Community) {
        self.init(
            name: community.reference.name, iconURL: community.reference.iconURL,
            memberCount: community.subscribers,
            isSubscribed: community.isSubscribed, isFavorite: community.isFavorite)
    }
}

actor SubscribedCommunitiesCache {
    static let shared = SubscribedCommunitiesCache()

    struct Value: Sendable {
        let communities: [Community]
        let isFresh: Bool
    }

    private struct Entry: Codable {
        let storedAt: Date
        let communities: [Community]
    }

    private let directoryURL: URL
    private let freshness: TimeInterval = 15 * 60

    init(fileManager: FileManager = .default) {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        directoryURL = cachesURL.appendingPathComponent("OctonautSubscribedCommunities", isDirectory: true)
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    func value(for account: AccountID, now: Date = .now) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(for: account)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return Value(
            communities: entry.communities,
            isFresh: now.timeIntervalSince(entry.storedAt) < freshness
        )
    }

    func store(_ communities: [Community], for account: AccountID, now: Date = .now) {
        let entry = Entry(storedAt: now, communities: communities)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: account), options: .atomic)
    }

    func remove(for account: AccountID) {
        try? FileManager.default.removeItem(at: fileURL(for: account))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directoryURL)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for account: AccountID) -> URL {
        directoryURL.appendingPathComponent(account.rawValue.uuidString.lowercased()).appendingPathExtension("json")
    }
}

actor UserProfileCache {
    static let shared = UserProfileCache()

    struct Value: Sendable {
        let profile: UserProfile
        let posts: [Post]
        let comments: [UserComment]
        let isFresh: Bool
    }

    private struct Entry: Codable {
        let storedAt: Date
        let profile: UserProfile
        let posts: [Post]
        let comments: [UserComment]
    }

    private let directoryURL: URL
    private let freshness: TimeInterval

    init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        freshness: TimeInterval = 60 * 60
    ) {
        let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        self.directoryURL = directoryURL
            ?? cachesURL.appendingPathComponent("OctonautUserProfiles", isDirectory: true)
        self.freshness = freshness
        try? fileManager.createDirectory(at: self.directoryURL, withIntermediateDirectories: true)
    }

    func value(
        for username: String,
        account: AccountID?,
        now: Date = .now
    ) -> Value? {
        guard let data = try? Data(contentsOf: fileURL(for: username, account: account)),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        return Value(
            profile: entry.profile,
            posts: entry.posts,
            comments: entry.comments,
            isFresh: now.timeIntervalSince(entry.storedAt) < freshness
        )
    }

    func store(
        profile: UserProfile,
        posts: [Post],
        comments: [UserComment],
        for username: String,
        account: AccountID?,
        now: Date = .now
    ) {
        let entry = Entry(storedAt: now, profile: profile, posts: posts, comments: comments)
        let scopeDirectory = scopeDirectoryURL(for: account)
        try? FileManager.default.createDirectory(at: scopeDirectory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(for: username, account: account), options: .atomic)
    }

    func remove(for account: AccountID) {
        try? FileManager.default.removeItem(at: scopeDirectoryURL(for: account))
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directoryURL)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
    }

    private func fileURL(for username: String, account: AccountID?) -> URL {
        let normalizedUsername = username.lowercased().map { character in
            character.isLetter || character.isNumber || character == "_" || character == "-"
                ? character : "_"
        }
        return scopeDirectoryURL(for: account)
            .appendingPathComponent(String(normalizedUsername))
            .appendingPathExtension("json")
    }

    private func scopeDirectoryURL(for account: AccountID?) -> URL {
        directoryURL.appendingPathComponent(account?.description ?? "anonymous", isDirectory: true)
    }
}

struct CommentCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var author: String
    var authorFlair: Flair?
    var body: String
    var score: Int
    var age: String
    var vote: Int
    var depth: Int
    var isModerator: Bool
    var isCollapsed: Bool
    var children: [CommentCardModel]
    var isMoreNode: Bool
    var isDeleted: Bool
    var moreCount: Int?
    var moreFailed: Bool

    init(
        id: String,
        author: String,
        authorFlair: Flair? = nil,
        body: String,
        score: Int,
        age: String,
        vote: Int,
        depth: Int,
        isModerator: Bool,
        isCollapsed: Bool,
        children: [CommentCardModel],
        isMoreNode: Bool = false,
        isDeleted: Bool = false,
        moreCount: Int? = nil,
        moreFailed: Bool = false
    ) {
        self.id = id
        self.author = author
        self.authorFlair = authorFlair
        self.body = body
        self.score = score
        self.age = age
        self.vote = vote
        self.depth = depth
        self.isModerator = isModerator
        self.isCollapsed = isCollapsed
        self.children = children
        self.isMoreNode = isMoreNode
        self.isDeleted = isDeleted
        self.moreCount = moreCount
        self.moreFailed = moreFailed
    }

    init(comment: CommentNode, depth: Int = 0, isCollapsed: Bool = false) {
        self.init(
            id: comment.id,
            author: comment.author?.username ?? "",
            authorFlair: comment.authorFlair,
            body: comment.body?.plainText ?? "",
            score: comment.score ?? 0,
            age: comment.createdAt.formatted(.relative(presentation: .named)),
            vote: comment.vote.direction,
            depth: depth,
            isModerator: comment.isDistinguished,
            isCollapsed: isCollapsed,
            children: comment.children.map { child in
                switch child {
                case .comment(let node): return CommentCardModel(comment: node, depth: depth + 1)
                case .more(let more): return CommentCardModel.more(more, depth: depth + 1)
                case .deleted(let deleted): return CommentCardModel.deleted(deleted, depth: depth + 1)
                }
            }
        )
    }

    static func more(_ node: MoreCommentsNode, depth: Int) -> CommentCardModel {
        CommentCardModel(
            id: node.id, author: "", body: "", score: 0, age: "", vote: 0, depth: depth,
            isModerator: false, isCollapsed: false, children: [], isMoreNode: true,
            moreCount: node.count ?? node.childIDs.count)
    }

    static func deleted(_ node: DeletedCommentNode, depth: Int) -> CommentCardModel {
        CommentCardModel(
            id: node.id, author: "", body: node.reason.isEmpty ? "[deleted]" : node.reason, score: 0,
            age: "", vote: 0, depth: depth, isModerator: false, isCollapsed: false, children: [],
            isDeleted: true)
    }

    static let samples: [CommentCardModel] = [
        CommentCardModel(
            id: "t1_comment-1", author: "swift_reader",
            body:
                "The little haptic when a copy action succeeds is one of my favourites. It is quick and never gets in the way.",
            score: 523, age: "2h", vote: 1, depth: 0, isModerator: false, isCollapsed: false,
            children: [
                CommentCardModel(
                    id: "t1_comment-1a", author: "native_by_design",
                    body: "Good haptics are almost invisible until an app leaves them out.", score: 83,
                    age: "1h", vote: 0, depth: 1, isModerator: false, isCollapsed: false, children: [])
            ]),
        CommentCardModel(
            id: "t1_comment-2", author: "AutoModerator",
            body: "This is an automated message. Please read the community rules before participating.",
            score: 1, age: "5h", vote: 0, depth: 0, isModerator: true, isCollapsed: true, children: []),
        CommentCardModel(
            id: "t1_comment-3", author: "paperback",
            body:
                "For me it is being able to keep a draft around when I leave a sheet. Small, but it makes reading and replying feel connected.",
            score: 271, age: "4h", vote: 0, depth: 0, isModerator: false, isCollapsed: false, children: []
        ),
    ]
}

struct UserCommentCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var author: String
    var body: String
    var score: Int
    var age: String
    var vote: Int
    var postTitle: String
    var postURL: URL?
    var community: String

    init(comment: UserComment) {
        id = comment.id
        author = comment.author?.username ?? "[deleted]"
        body = comment.body?.plainText ?? "[deleted]"
        score = comment.score ?? 0
        age = comment.createdAt.formatted(.relative(presentation: .named))
        vote = comment.vote.direction
        postTitle = comment.postTitle ?? "Reddit post"
        postURL = comment.postPermalink
        community = comment.community?.name ?? "reddit"
    }
}

struct InboxCardModel: Identifiable, Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case reply, mention, message }
    let id: String
    var kind: Kind
    var title: String
    var subtitle: String
    var preview: String
    var author: String
    var age: String
    var score: Int?
    var isUnread: Bool
    var postURL: URL? = nil
}

struct AccountCardModel: Identifiable, Hashable, Sendable {
    let id: String
    var username: String
    var accountAge: String
    var postKarma: Int
    var commentKarma: Int
    var isActive: Bool
    var needsLogin: Bool

    init(
        id: String,
        username: String,
        accountAge: String,
        postKarma: Int,
        commentKarma: Int,
        isActive: Bool,
        needsLogin: Bool
    ) {
        self.id = id
        self.username = username
        self.accountAge = accountAge
        self.postKarma = postKarma
        self.commentKarma = commentKarma
        self.isActive = isActive
        self.needsLogin = needsLogin
    }

    init(account: Account, isActive: Bool = false) {
        self.init(
            id: account.id.rawValue.uuidString, username: account.username,
            accountAge: account.createdAt.formatted(.relative(presentation: .named)), postKarma: 0,
            commentKarma: 0, isActive: isActive, needsLogin: account.health == .needsLogin)
    }
}

struct FeedDescriptorModel: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable { case home, popular, all, community, multireddit }
    var kind: Kind
    var name: String
    var sort: String = "Best"

    static let home = FeedDescriptorModel(kind: .home, name: "Home")
    static let popular = FeedDescriptorModel(kind: .popular, name: "Popular")
    static let all = FeedDescriptorModel(kind: .all, name: "All")
}

enum ComposerKind: String, CaseIterable, Identifiable, Hashable, Sendable {
    case post
    case comment
    case message
    case edit

    var id: String { rawValue }
    var title: String {
        switch self {
        case .post: "New Post"
        case .comment: "Reply"
        case .message: "New Message"
        case .edit: "Edit"
        }
    }
}

enum SettingsDestination: String, CaseIterable, Identifiable, Hashable, Sendable {
    case general, theme, appearance, intelligence, account, dataUse, statistics, advanced, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: "General"
        case .theme: "Theme"
        case .appearance: "Appearance"
        case .intelligence: "Intelligence"
        case .account: "Account"
        case .dataUse: "Data Use"
        case .statistics: "Statistics"
        case .advanced: "Advanced"
        case .about: "About"
        }
    }
}

enum FeatureSearchScope: String, CaseIterable, Identifiable, Hashable, Sendable {
    case posts = "Posts"
    case communities = "Communities"
    case users = "Users"
    var id: String { rawValue }
}

enum FeatureRoute: Hashable {
    case feed(FeedDescriptorModel)
    case post(PostCardModel)
    case postURL(URL)
    case community(String)
    case search(String)
    case conversation(String)
    case account(String)
    case settings(SettingsDestination)
    case composer(ComposerKind)
    case gallery(FeedDescriptorModel)
    case mediaURL(URL)
    case web(URL)
}

/// Converts URLs received from Share sheets, universal links, and copied
/// Reddit links into feature routes. Keeping this parser pure makes it safe to
/// use from the app shell and straightforward to test without a network call.
enum OctonautFeatureURLRouter {
    private static let redditHosts: Set<String> = [
        "reddit.com", "www.reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com",
    ]
    private static let mediaHosts: Set<String> = [
        "i.redd.it", "preview.redd.it", "external-preview.redd.it", "v.redd.it",
    ]

    static func route(_ url: URL) -> FeatureRoute? {
        guard let host = url.host?.lowercased() else { return nil }

        if url.scheme?.lowercased() == "octonaut" {
            let path = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
            switch host {
            case "feed":
                switch path.first?.lowercased() {
                case "home": return .feed(.home)
                case "all": return .feed(.all)
                default: return .feed(.popular)
                }
            case "community":
                guard let name = path.first else { return nil }
                return .community(name)
            case "post":
                guard let identifier = path.first else { return nil }
                return .postURL(URL(string: "https://www.reddit.com/comments/\(identifier)")!)
            case "user":
                guard let username = path.first else { return nil }
                return .account(username)
            case "search":
                let query =
                    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {
                        $0.name == "q"
                    })?.value
                    ?? path.first
                    ?? ""
                return .search(query)
            case "settings":
                return .settings(.general)
            default:
                return nil
            }
        }

        if host == "redd.it" {
            guard let identifier = url.pathComponents.last(where: { $0 != "/" && !$0.isEmpty }) else {
                return nil
            }
            return .postURL(URL(string: "https://www.reddit.com/comments/\(identifier)") ?? url)
        }

        if mediaHosts.contains(host) {
            return .mediaURL(url)
        }

        guard redditHosts.contains(host) else { return nil }
        let components = url.pathComponents
        let lowercased = components.map { $0.lowercased() }

        if let commentsIndex = lowercased.firstIndex(of: "comments"),
            components.indices.contains(commentsIndex + 1)
        {
            return .postURL(url)
        }

        if let galleryIndex = lowercased.firstIndex(of: "gallery"),
            components.indices.contains(galleryIndex + 1)
        {
            return .postURL(url)
        }

        if let communityIndex = lowercased.firstIndex(of: "r"),
            components.indices.contains(communityIndex + 1)
        {
            let name = components[communityIndex + 1]
            guard !name.isEmpty else { return .web(url) }
            return .community(name)
        }

        return .web(url)
    }
}

enum FeatureSheet: Identifiable, Hashable {
    case quickCommunitySearch
    case quickAccountSwitcher
    case composer(ComposerKind)

    var id: String {
        switch self {
        case .quickCommunitySearch: "quick-community-search"
        case .quickAccountSwitcher: "quick-account-switcher"
        case .composer(let kind): "composer-\(kind.rawValue)"
        }
    }
}

@MainActor
@Observable
final class OctonautFeatureStore {
    private struct FeedCacheEntry {
        let posts: [PostCardModel]
        let filteredPostCount: Int
        let nextPage: String?
        let filterRevision: Int
        let storedAt: Date
    }

    @ObservationIgnored private let reddit: (any RedditClient)?
    @ObservationIgnored private let authenticated: (any AuthenticatedRedditService)?
    @ObservationIgnored private let intelligence: (any IntelligenceService)?
    @ObservationIgnored private let settings: SettingsStore?
    @ObservationIgnored private let persistence: (any PersistenceStore)?
    @ObservationIgnored private let semanticFilter: SemanticFilterEngine?
    /// The selected account is optional because public feeds and previews do
    /// not need credentials. The app can update this value when its account
    /// coordinator changes selection.
    private var accountID: AccountID?
    private var accountGeneration: UInt = 0
    @ObservationIgnored private var nextPage: String?
    @ObservationIgnored private var loadedFeed: FeedDescriptorModel?
    @ObservationIgnored private var feedCache: [FeedDescriptorModel: FeedCacheEntry] = [:]
    @ObservationIgnored private let feedCacheFreshness: TimeInterval = 15 * 60
    @ObservationIgnored private var communitiesRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var communitiesRefreshID: UUID?
    var posts: [PostCardModel] = [
        .sample,
        .mediaSample,
        PostCardModel(
            id: "t3_sample-3", community: "swift", author: "concurrency",
            title: "Swift 6 migration: what did you change first?",
            body:
                "A practical discussion about strict concurrency, actors, and the changes that paid off.",
            score: 642, comments: 96, age: "7h", vote: 0, isSaved: false, isSeen: true, isNSFW: false,
            isSpoiler: false, isSticky: false, isVideo: false, hasMedia: false, mediaTitle: "",
            shareURL: URL(string: "https://www.reddit.com/r/swift/comments/sample3")!),
        PostCardModel(
            id: "t3_sample-4", community: "technology", author: "daylight_savings",
            title: "What are you reading this week?",
            body: "Share a useful paper, book, or long-form article.", score: 414, comments: 61,
            age: "9h", vote: -1, isSaved: false, isSeen: false, isNSFW: false, isSpoiler: false,
            isSticky: true, isVideo: false, hasMedia: false, mediaTitle: "",
            shareURL: URL(string: "https://www.reddit.com/r/technology/comments/sample4")!),
    ]
    var communities: [CommunityCardModel] = [
        CommunityCardModel(name: "apple", memberCount: 5_100_000, isSubscribed: true, isFavorite: true),
        CommunityCardModel(name: "swift", memberCount: 260_000, isSubscribed: true),
        CommunityCardModel(
            name: "iphone", memberCount: 4_300_000, isSubscribed: true, isFavorite: true),
        CommunityCardModel(name: "technology", memberCount: 16_000_000),
    ]
    var inbox: [InboxCardModel] = [
        InboxCardModel(
            id: "inbox-1", kind: .reply, title: "Re: What small iOS detail makes your day better?",
            subtitle: "r/apple • swift_reader",
            preview: "The little haptic when a copy action succeeds is one of my favourites.",
            author: "swift_reader", age: "2h", score: 523, isUnread: true),
        InboxCardModel(
            id: "inbox-2", kind: .mention, title: "You were mentioned in a comment",
            subtitle: "r/swift • native_by_design",
            preview: "I agree with @example_author on this approach.", author: "native_by_design",
            age: "5h", score: 83, isUnread: true),
        InboxCardModel(
            id: "inbox-3", kind: .message, title: "Welcome to the community", subtitle: "mod_team",
            preview: "Thanks for joining. Please take a moment to read the rules.", author: "mod_team",
            age: "1d", score: nil, isUnread: false),
    ]
    var accounts: [AccountCardModel] = [
        AccountCardModel(
            id: "account-1", username: "example_author", accountAge: "6 years", postKarma: 12_480,
            commentKarma: 48_320, isActive: true, needsLogin: false)
    ]
    var comments = CommentCardModel.samples
    var feedState: OctonautLoadState = .loaded
    var communitiesState: OctonautLoadState = .loaded
    var inboxState: OctonautLoadState = .loaded
    var searchText = ""
    var selectedSort = "Best"
    var detailState: OctonautLoadState = .idle
    var detailPost: PostCardModel?
    var moreLoadingIDs: Set<String> = []
    var moreFailedIDs: Set<String> = []
    var filteredPostCount = 0
    var userProfile: UserProfile?
    var userProfilePosts: [PostCardModel] = []
    var userProfileComments: [UserCommentCardModel] = []
    var userProfileState: OctonautLoadState = .idle
    var loadedUserProfileUsername = ""
    var loadedUserProfileAccountContext = ""
    var unreadCount: Int { inbox.filter(\.isUnread).count }
    var accountContextKey: String {
        "\(accountID?.description ?? "anonymous"):\(accountGeneration)"
    }

    /// Adapter initializer for the Domain layer. Live clients can feed their
    /// decoded values here without making SwiftUI views know about DTOs.
    init(
        domainPosts: [Post] = [],
        domainComments: [CommentTreeNode] = [],
        domainCommunities: [Community] = [],
        domainAccounts: [Account] = [],
        reddit: (any RedditClient)? = nil,
        authenticated: (any AuthenticatedRedditService)? = nil,
        accountID: AccountID? = nil,
        intelligence: (any IntelligenceService)? = nil,
        settings: SettingsStore? = nil,
        persistence: (any PersistenceStore)? = nil
    ) {
        self.reddit = reddit
        self.authenticated = authenticated
        self.accountID = accountID
        self.intelligence = intelligence
        self.settings = settings
        self.persistence = persistence
        self.semanticFilter = intelligence.map(SemanticFilterEngine.init(service:))
        if reddit != nil {
            // Live stores start empty. Sample rows are reserved for previews.
            if domainPosts.isEmpty { posts = [] }
            if domainComments.isEmpty { comments = [] }
            if domainCommunities.isEmpty { communities = [] }
        }
        if reddit != nil, domainAccounts.isEmpty {
            accounts = []
            inbox = []
        }
        if !domainPosts.isEmpty { posts = domainPosts.map(PostCardModel.init) }
        if !domainComments.isEmpty {
            comments = domainComments.compactMap { node in
                guard case .comment(let comment) = node else { return nil }
                return CommentCardModel(comment: comment)
            }
        }
        if !domainCommunities.isEmpty { communities = domainCommunities.map(CommunityCardModel.init) }
        if !domainAccounts.isEmpty {
            accounts = domainAccounts.enumerated().map { index, account in
                AccountCardModel(account: account, isActive: index == 0)
            }
            self.accountID = accountID ?? domainAccounts.first?.id
        }
    }

    /// Keeps the feature store aligned with the account coordinator. The
    /// coordinator remains the source of truth; this value binds feed reads
    /// to the selected session and lets stale responses be discarded.
    func synchronizeAccount(id: AccountID?, generation: UInt, accounts domainAccounts: [Account]) {
        let selectionChanged = accountID != id
        accountID = id
        accountGeneration = generation
        accounts = domainAccounts.map { AccountCardModel(account: $0, isActive: $0.id == id) }

        guard selectionChanged else { return }
        communitiesRefreshTask?.cancel()
        communitiesRefreshTask = nil
        communitiesRefreshID = nil
        feedCache.removeAll()
        nextPage = nil
        loadedFeed = nil
        detailPost = nil
        detailState = .idle
        moreLoadingIDs.removeAll()
        moreFailedIDs.removeAll()
        comments.removeAll()
        inbox.removeAll()
        communities.removeAll()
        communitiesState = id == nil ? .empty : .idle
        inboxState = id == nil ? .empty : .idle
        if reddit != nil {
            posts.removeAll()
            feedState = .idle
        }
    }

    private func isCurrentAccount(_ id: AccountID?, generation: UInt) -> Bool {
        accountID == id && accountGeneration == generation
    }

    func refreshPosts(for descriptor: FeedDescriptorModel = .popular, forceRefresh: Bool = false) async {
        let filterRevision = Int(settings?.filterRevision ?? 0)
        var hasWarmContent = loadedFeed == descriptor && !posts.isEmpty
        if !forceRefresh,
           let cached = feedCache[descriptor],
           cached.filterRevision == filterRevision {
            posts = cached.posts
            filteredPostCount = cached.filteredPostCount
            nextPage = cached.nextPage
            loadedFeed = descriptor
            feedState = posts.isEmpty ? .empty : .loaded
            hasWarmContent = !posts.isEmpty
            if Date.now.timeIntervalSince(cached.storedAt) < feedCacheFreshness {
                return
            }
        }

        feedState = hasWarmContent ? .loaded : .loading
        if !hasWarmContent { filteredPostCount = 0 }
        guard let reddit else {
            try? await Task.sleep(for: .milliseconds(240))
            guard !Task.isCancelled else { return }
            feedState = posts.isEmpty ? .empty : .loaded
            return
        }

        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        do {
            let listing = try await reddit.listing(
                ListingRequest(
                    feed: domainFeed(for: descriptor),
                    limit: 35,
                    accountScope: selectedAccountID.map(AccountScope.account) ?? .anonymous,
                    responseCachePolicy: forceRefresh ? .reloadIgnoringCache : .useCache
                ),
                account: selectedAccountID
            )
            guard !Task.isCancelled, isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            let filtered = await applyFilters(to: listing.items)
            guard !Task.isCancelled, isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            posts = filtered.posts.map(PostCardModel.init)
            filteredPostCount = filtered.removedCount
            nextPage = listing.after
            loadedFeed = descriptor
            feedState = posts.isEmpty ? .empty : .loaded
            feedCache[descriptor] = FeedCacheEntry(
                posts: posts,
                filteredPostCount: filteredPostCount,
                nextPage: nextPage,
                filterRevision: filterRevision,
                storedAt: .now
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            nextPage = nil
            feedState = hasWarmContent ? .loaded : .failed(error.localizedDescription)
        }
    }

    func refreshCommunities(forceRefresh: Bool = false) async {
        if !forceRefresh, let communitiesRefreshTask {
            await communitiesRefreshTask.value
            return
        }

        if forceRefresh {
            communitiesRefreshTask?.cancel()
        }

        let refreshID = UUID()
        communitiesRefreshID = refreshID
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performCommunitiesRefresh(forceRefresh: forceRefresh)
            if self.communitiesRefreshID == refreshID {
                self.communitiesRefreshTask = nil
                self.communitiesRefreshID = nil
            }
        }
        communitiesRefreshTask = task
        await task.value
    }

    private func performCommunitiesRefresh(forceRefresh: Bool) async {
        guard let reddit else {
            communitiesState = communities.isEmpty ? .empty : .loaded
            return
        }
        guard let selectedAccountID = accountID else {
            communities = []
            communitiesState = .empty
            return
        }

        let selectedGeneration = accountGeneration
        let favorites = localFavoriteCommunityNames(accountID: selectedAccountID)
        if communities.isEmpty {
            communities = favorites.sorted().map {
                CommunityCardModel(name: $0, isSubscribed: true, isFavorite: true)
            }
        }

        if !forceRefresh {
            let cached = await SubscribedCommunitiesCache.shared.value(for: selectedAccountID)
            guard !Task.isCancelled,
                  isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            if let cached {
                applyCommunities(cached.communities, favorites: favorites)
                communitiesState = communities.isEmpty ? .empty : .loaded
                if cached.isFresh { return }
            }
        }

        guard !Task.isCancelled,
              isCurrentAccount(selectedAccountID, generation: selectedGeneration)
        else { return }
        communitiesState = .loading
        do {
            var values: [Community] = []
            var after: String?
            var seenCursors = Set<String>()
            repeat {
                let page = try await reddit.subscribedCommunities(after: after, account: selectedAccountID)
                guard !Task.isCancelled,
                    isCurrentAccount(selectedAccountID, generation: selectedGeneration)
                else { return }
                values.append(contentsOf: page.items)
                guard let next = page.after, seenCursors.insert(next).inserted else {
                    after = nil
                    break
                }
                after = next
            } while after != nil

            applyCommunities(values, favorites: favorites)
            await SubscribedCommunitiesCache.shared.store(values, for: selectedAccountID)
            communitiesState = communities.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            communitiesState = .failed(error.localizedDescription)
        }
    }

    private func applyCommunities(_ values: [Community], favorites: Set<String>) {
        var seenIDs = Set<String>()
        communities =
            values
            .sorted {
                $0.reference.name.localizedCaseInsensitiveCompare($1.reference.name) == .orderedAscending
            }
            .filter { seenIDs.insert($0.id).inserted }
            .map { community in
                var model = CommunityCardModel(community: community)
                model.isSubscribed = true
                model.isFavorite = favorites.contains(model.id)
                return model
            }
    }

    func refreshInbox() async {
        guard reddit == nil else {
            inbox = []
            inboxState = .empty
            return
        }
        inboxState = .loading
        try? await Task.sleep(for: .milliseconds(240))
        guard !Task.isCancelled else { return }
        inboxState = inbox.isEmpty ? .empty : .loaded
    }

    func loadUserProfile(username: String, forceRefresh: Bool = false) async {
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty else {
            userProfileState = .failed("A username is required.")
            return
        }
        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        let currentAccountContext = accountContextKey
        let isSameProfile =
            loadedUserProfileUsername.caseInsensitiveCompare(normalizedUsername) == .orderedSame
            && loadedUserProfileAccountContext == currentAccountContext
        loadedUserProfileUsername = normalizedUsername
        loadedUserProfileAccountContext = currentAccountContext

        if !forceRefresh,
           let cached = await UserProfileCache.shared.value(
               for: normalizedUsername,
               account: selectedAccountID
           ),
           !Task.isCancelled,
           isCurrentAccount(selectedAccountID, generation: selectedGeneration),
           loadedUserProfileUsername.caseInsensitiveCompare(normalizedUsername) == .orderedSame {
            applyUserProfileCache(cached)
            if cached.isFresh { return }
        } else if !isSameProfile || userProfile == nil {
            userProfile = nil
            userProfilePosts.removeAll()
            userProfileComments.removeAll()
            userProfileState = .loading
        }

        guard let reddit else {
            userProfile = UserProfile(
                reference: UserReference(username: normalizedUsername),
                avatarURL: nil,
                createdAt: .now.addingTimeInterval(-6 * 365 * 24 * 60 * 60),
                karma: 60_800,
                about: RichText(plainText: "A fixture profile for offline previews."),
                isBlocked: false,
                isFollowing: false
            )
            userProfilePosts = posts.filter {
                $0.author.caseInsensitiveCompare(normalizedUsername) == .orderedSame
            }
            userProfileComments = []
            userProfileState = .loaded
            return
        }

        let hasCachedContent = userProfile != nil
        if !hasCachedContent { userProfileState = .loading }
        do {
            async let profileRequest = reddit.userProfile(normalizedUsername, account: selectedAccountID)
            async let postsRequest = reddit.listing(
                ListingRequest(
                    feed: FeedDescriptor(
                        destination: .user(username: normalizedUsername, section: .submitted),
                        sort: .new
                    ),
                    limit: 50,
                    accountScope: selectedAccountID.map(AccountScope.account) ?? .anonymous,
                    responseCachePolicy: forceRefresh ? .reloadIgnoringCache : .useCache
                ),
                account: selectedAccountID
            )
            async let commentsRequest = reddit.userComments(
                normalizedUsername, after: nil, account: selectedAccountID)
            let (profile, submitted, comments) = try await (profileRequest, postsRequest, commentsRequest)
            guard !Task.isCancelled,
                isCurrentAccount(selectedAccountID, generation: selectedGeneration),
                loadedUserProfileUsername == normalizedUsername
            else { return }
            userProfile = profile
            userProfilePosts = submitted.items.map(PostCardModel.init)
            userProfileComments = comments.items.map(UserCommentCardModel.init)
            userProfileState = .loaded
            await UserProfileCache.shared.store(
                profile: profile,
                posts: submitted.items,
                comments: comments.items,
                for: normalizedUsername,
                account: selectedAccountID
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            if !hasCachedContent {
                userProfileState = .failed(error.localizedDescription)
            }
        }
    }

    private func applyUserProfileCache(_ cached: UserProfileCache.Value) {
        userProfile = cached.profile
        userProfilePosts = cached.posts.map(PostCardModel.init)
        userProfileComments = cached.comments.map(UserCommentCardModel.init)
        userProfileState = .loaded
    }

    func loadPostDetail(for post: PostCardModel, sort: String = "Best") async {
        detailState = .loading
        detailPost = post
        guard let reddit else {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            detailState = .loaded
            return
        }
        comments = []

        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        do {
            let thread = try await reddit.post(
                post.shareURL,
                sort: CommentSort(rawValue: sort.lowercased()),
                account: selectedAccountID
            )
            guard !Task.isCancelled, isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            detailPost = PostCardModel(post: thread.post)
            comments = thread.comments.map { node in
                switch node {
                case .comment(let comment): return CommentCardModel(comment: comment)
                case .more(let more): return CommentCardModel.more(more, depth: 0)
                case .deleted(let deleted): return CommentCardModel.deleted(deleted, depth: 0)
                }
            }
            moreFailedIDs.removeAll()
            detailState = .loaded
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            detailState = .failed(error.localizedDescription)
        }
    }

    /// Reddit's read client exposes a complete post/thread request rather than
    /// a separate child-expansion endpoint. Retrying the thread request keeps
    /// the `more` row recoverable without inventing a transport API here.
    func loadMoreComments(_ commentID: String, for post: PostCardModel, sort: String = "Best") async {
        guard !moreLoadingIDs.contains(commentID) else { return }
        moreLoadingIDs.insert(commentID)
        moreFailedIDs.remove(commentID)
        defer { moreLoadingIDs.remove(commentID) }
        await loadPostDetail(for: post, sort: sort)
        if case .failed = detailState { moreFailedIDs.insert(commentID) }
    }

    func loadMorePosts(for descriptor: FeedDescriptorModel = .popular) async {
        guard feedState == .loaded else { return }
        guard let reddit else {
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let nextIndex = posts.count
            let copies = posts.prefix(2).map { post in
                PostCardModel(
                    id: "\(post.id)-\(nextIndex)", community: post.community, author: post.author,
                    authorFlair: post.authorFlair, title: post.title, body: post.body,
                    flair: post.flair, score: post.score,
                    comments: post.comments,
                    age: post.age, vote: post.vote, isSaved: post.isSaved, isSeen: post.isSeen,
                    isNSFW: post.isNSFW, isSpoiler: post.isSpoiler, isSticky: post.isSticky,
                    isVideo: post.isVideo, hasMedia: post.hasMedia, mediaTitle: post.mediaTitle,
                    shareURL: post.shareURL, mediaURL: post.mediaURL, thumbnailURL: post.thumbnailURL,
                    mediaKind: post.mediaKind, galleryURLs: post.galleryURLs, audioURL: post.audioURL)
            }
            posts.append(contentsOf: copies)
            return
        }

        guard loadedFeed == descriptor, let nextPage else { return }
        let selectedAccountID = accountID
        let selectedGeneration = accountGeneration
        do {
            let listing = try await reddit.listing(
                ListingRequest(
                    feed: domainFeed(for: descriptor),
                    limit: 35,
                    after: nextPage,
                    accountScope: selectedAccountID.map(AccountScope.account) ?? .anonymous
                ),
                account: selectedAccountID
            )
            guard !Task.isCancelled, isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            let filtered = await applyFilters(to: listing.items)
            guard !Task.isCancelled, isCurrentAccount(selectedAccountID, generation: selectedGeneration)
            else { return }
            let existing = Set(posts.map(\.id))
            posts.append(
                contentsOf: filtered.posts.filter { !existing.contains($0.id) }.map(PostCardModel.init))
            filteredPostCount += filtered.removedCount
            self.nextPage = listing.after
            feedCache[descriptor] = FeedCacheEntry(
                posts: posts,
                filteredPostCount: filteredPostCount,
                nextPage: self.nextPage,
                filterRevision: Int(settings?.filterRevision ?? 0),
                storedAt: .now
            )
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentAccount(selectedAccountID, generation: selectedGeneration) else { return }
            feedState = .failed(error.localizedDescription)
        }
    }

    private func applyFilters(to values: [Post]) async -> (posts: [Post], removedCount: Int) {
        var seenIDs = Set<String>()
        let hideSeen = settings?.hideSeenPosts ?? false
        if hideSeen, let persistence {
            seenIDs = Set((try? await persistence.loadSeenPostIDs()) ?? [])
        }

        let keywordTerms =
            UserDefaults.standard.string(forKey: "filters.keywordTerms")?.split(separator: ",").map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty } ?? []
        let blockedCommunities = Set(
            (UserDefaults.standard.string(forKey: "filters.blockedCommunities") ?? "")
                .split(separator: ",")
                .map { IDNormalization.community(String($0)) }
                .filter { !$0.isEmpty })
        let deterministic = DeterministicPostFilter.apply(
            values,
            configuration: DeterministicFilterConfiguration(
                blockedCommunities: blockedCommunities,
                keywordRules: keywordTerms.isEmpty ? [] : [KeywordFilterRule(terms: keywordTerms)],
                seenPostIDs: seenIDs,
                hideSeen: hideSeen
            )
        )

        guard UserDefaults.standard.bool(forKey: "filters.semantic.enabled"),
            let semanticFilter,
            let instruction = UserDefaults.standard.string(forKey: "filters.semantic.instruction"),
            !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return (deterministic.visible, deterministic.removedCount)
        }

        let rule = SemanticRule(
            id: "default",
            instruction: instruction,
            revision: Int(settings?.filterRevision ?? 0)
        )
        let decisions = await semanticFilter.classify(posts: deterministic.visible, rule: rule)
        let hiddenIDs = Set(decisions.filter(\.shouldHide).map(\.itemID))
        let visible = deterministic.visible.filter { !hiddenIDs.contains($0.id) }
        return (visible, values.count - visible.count)
    }

    /// Updates the account used by subsequent reads. Callers should refresh
    /// the visible feed or detail after changing it.
    func setAccountID(_ accountID: AccountID?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        accountGeneration &+= 1
        feedCache.removeAll()
        nextPage = nil
        loadedFeed = nil
        detailPost = nil
        detailState = .idle
        comments.removeAll()
        inbox.removeAll()
        inboxState = accountID == nil ? .empty : .idle
    }

    private func domainFeed(for descriptor: FeedDescriptorModel) -> FeedDescriptor {
        let destination: FeedDestination
        switch descriptor.kind {
        case .home: destination = .home
        case .popular: destination = .popular
        case .all: destination = .all
        case .community: destination = .community(descriptor.name)
        case .multireddit: destination = .url(URL(string: "https://www.reddit.com")!)
        }
        return FeedDescriptor(
            destination: destination, sort: PostSort(rawValue: selectedSort.lowercased()))
    }

    func vote(postID: String, value: Int) {
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            let oldVote = posts[index].vote
            posts[index].vote = value
            posts[index].score += value - oldVote
        }
        if detailPost?.id == postID {
            let oldDetailVote = detailPost?.vote ?? 0
            detailPost?.vote = value
            detailPost?.score += value - oldDetailVote
        }
        updateLoadedFeedCache()
    }

    /// Applies a vote immediately, then sends it for the selected account.
    /// The previous value is restored when Reddit rejects the mutation.
    func performVote(postID: String, value: Int, accountID: AccountID) async throws {
        guard self.accountID == accountID else { return }
        let oldVote: Int
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            oldVote = posts[index].vote
        } else if let detailPost, detailPost.id == postID {
            oldVote = detailPost.vote
        } else {
            return
        }
        let generation = accountGeneration
        vote(postID: postID, value: value)
        do {
            let action = RedditAction.vote(
                fullname: IDNormalization.fullname(postID, kind: "t3"), direction: value)
            if let authenticated {
                _ = try await authenticated.perform(action, accountID: accountID)
            } else if let reddit {
                _ = try await reddit.perform(action, account: accountID)
            }
        } catch {
            if isCurrentAccount(accountID, generation: generation) {
                vote(postID: postID, value: oldVote)
            }
            throw error
        }
    }

    func save(postID: String) {
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            posts[index].isSaved.toggle()
        }
        if detailPost?.id == postID { detailPost?.isSaved.toggle() }
        updateLoadedFeedCache()
    }

    /// Applies a save change immediately, then sends it for the selected
    /// account. The previous value is restored when Reddit rejects it.
    func performSave(postID: String, accountID: AccountID) async throws {
        guard self.accountID == accountID else { return }
        let oldSaved: Bool
        if let index = posts.firstIndex(where: { $0.id == postID }) {
            oldSaved = posts[index].isSaved
        } else if let detailPost, detailPost.id == postID {
            oldSaved = detailPost.isSaved
        } else {
            return
        }
        let generation = accountGeneration
        save(postID: postID)
        do {
            let action = RedditAction.save(
                fullname: IDNormalization.fullname(postID, kind: "t3"), saved: !oldSaved)
            if let authenticated {
                _ = try await authenticated.perform(action, accountID: accountID)
            } else if let reddit {
                _ = try await reddit.perform(action, account: accountID)
            }
        } catch {
            if isCurrentAccount(accountID, generation: generation) {
                save(postID: postID)
            }
            throw error
        }
    }

    func markSeen(postID: String) {
        guard let index = posts.firstIndex(where: { $0.id == postID }) else { return }
        posts[index].isSeen.toggle()
        if detailPost?.id == postID { detailPost?.isSeen.toggle() }
        updateLoadedFeedCache()
        guard let persistence else { return }
        let isSeen = posts[index].isSeen
        Task {
            if isSeen {
                try? await persistence.markPostSeen(postID, seenAt: .now)
            } else {
                try? await persistence.removePostSeen(postID)
            }
        }
    }

    func recordPostViewed() async {
        guard settings?.collectLocalUsageStatistics != false, let persistence else { return }
        try? await persistence.incrementStatistic(.postsViewed, by: 1)
    }

    func recordCommunityVisit(_ community: String) async {
        guard settings?.collectLocalUsageStatistics != false, let persistence else { return }
        try? await persistence.recordCommunityVisit(community)
    }

    func recordFeedScroll(points: Int) async {
        guard points > 0, settings?.collectLocalUsageStatistics != false, let persistence else { return }
        try? await persistence.incrementStatistic(.feedScrollPoints, by: points)
    }

    func toggleFavorite(communityID: String) {
        guard let index = communities.firstIndex(where: { $0.id == communityID }) else { return }
        communities[index].isFavorite.toggle()
        guard let accountID else { return }
        let favorites = communities.filter(\.isFavorite).map(\.id).sorted()
        UserDefaults.standard.set(favorites, forKey: favoriteCommunitiesKey(accountID: accountID))
    }

    func toggleSubscribe(communityID: String) {
        guard let index = communities.firstIndex(where: { $0.id == communityID }) else { return }
        communities[index].isSubscribed.toggle()
    }

    private func updateLoadedFeedCache() {
        guard let loadedFeed else { return }
        feedCache[loadedFeed] = FeedCacheEntry(
            posts: posts,
            filteredPostCount: filteredPostCount,
            nextPage: nextPage,
            filterRevision: Int(settings?.filterRevision ?? 0),
            storedAt: feedCache[loadedFeed]?.storedAt ?? .now
        )
    }

    func markRead(itemID: String) {
        guard let index = inbox.firstIndex(where: { $0.id == itemID }) else { return }
        inbox[index].isUnread = false
    }

    func markAllRead() {
        for index in inbox.indices { inbox[index].isUnread = false }
    }

    func toggleComment(id: String) {
        func updated(_ values: [CommentCardModel]) -> [CommentCardModel] {
            values.map { comment in
                var comment = comment
                if comment.id == id {
                    comment.isCollapsed.toggle()
                } else {
                    comment.children = updated(comment.children)
                }
                return comment
            }
        }
        comments = updated(comments)
    }

    func voteComment(id: String, value: Int) {
        func update(_ values: inout [CommentCardModel]) {
            for index in values.indices {
                if values[index].id == id {
                    let oldVote = values[index].vote
                    values[index].vote = value
                    values[index].score += value - oldVote
                    return
                }
                update(&values[index].children)
            }
        }
        update(&comments)
    }

    func performCommentVote(id: String, value: Int, accountID: AccountID) async throws {
        guard self.accountID == accountID, let oldVote = commentVote(id: id, in: comments) else {
            return
        }
        let generation = accountGeneration
        voteComment(id: id, value: value)
        do {
            let action = RedditAction.vote(
                fullname: IDNormalization.fullname(id, kind: "t1"), direction: value)
            if let authenticated {
                _ = try await authenticated.perform(action, accountID: accountID)
            } else if let reddit {
                _ = try await reddit.perform(action, account: accountID)
            }
        } catch {
            if isCurrentAccount(accountID, generation: generation) {
                voteComment(id: id, value: oldVote)
            }
            throw error
        }
    }

    private func commentVote(id: String, in values: [CommentCardModel]) -> Int? {
        for value in values {
            if value.id == id { return value.vote }
            if let nested = commentVote(id: id, in: value.children) { return nested }
        }
        return nil
    }

    private func localFavoriteCommunityNames(accountID: AccountID) -> Set<String> {
        Set(
            (UserDefaults.standard.stringArray(forKey: favoriteCommunitiesKey(accountID: accountID)) ?? [])
                .map(IDNormalization.community))
    }

    private func favoriteCommunitiesKey(accountID: AccountID) -> String {
        "communities.favorites.\(accountID.description)"
    }

    static let preview = OctonautFeatureStore()
}
