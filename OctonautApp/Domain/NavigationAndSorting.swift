import Foundation

enum PostSort: Hashable, Codable, Sendable {
    case `default`
    case best
    case hot
    case new
    case top
    case rising
    case controversial
    case unknown(String)

    var rawValue: String {
        switch self {
        case .default: return "default"
        case .best: return "best"
        case .hot: return "hot"
        case .new: return "new"
        case .top: return "top"
        case .rising: return "rising"
        case .controversial: return "controversial"
        case .unknown(let value): return value
        }
    }

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "default": self = .default
        case "best": self = .best
        case "hot": self = .hot
        case "new": self = .new
        case "top": self = .top
        case "rising": self = .rising
        case "controversial": self = .controversial
        default: self = .unknown(rawValue)
        }
    }
}

enum CommentSort: Hashable, Codable, Sendable {
    case best
    case new
    case top
    case controversial
    case old
    case qa
    case unknown(String)

    var rawValue: String {
        switch self {
        case .best: return "best"
        case .new: return "new"
        case .top: return "top"
        case .controversial: return "controversial"
        case .old: return "old"
        case .qa: return "qa"
        case .unknown(let value): return value
        }
    }

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "best": self = .best
        case "new": self = .new
        case "top": self = .top
        case "controversial": self = .controversial
        case "old": self = .old
        case "qa", "q&a": self = .qa
        default: self = .unknown(rawValue)
        }
    }
}

enum TopTime: String, Codable, Hashable, Sendable, CaseIterable {
    case hour
    case day
    case week
    case month
    case year
    case all
}

enum UserSection: String, Codable, Hashable, Sendable, CaseIterable {
    case overview
    case submitted
    case comments
    case saved
    case upvoted
    case downvoted
    case hidden
}

enum SearchScope: String, Codable, Hashable, Sendable, CaseIterable {
    case posts
    case communities
    case users
}

enum FeedDestination: Hashable, Codable, Sendable {
    case home
    case popular
    case all
    case community(String)
    case combined([String])
    case multireddit(owner: String, name: String)
    case user(username: String, section: UserSection)
    case search(query: String, community: String?)
    case url(URL)

    var normalizedKey: String {
        switch self {
        case .home: return "home"
        case .popular: return "popular"
        case .all: return "all"
        case .community(let name): return "community:\(IDNormalization.community(name))"
        case .combined(let names):
            let normalized = names.map(IDNormalization.community).filter { !$0.isEmpty }
            return "combined:\(normalized.joined(separator: "+"))"
        case .multireddit(let owner, let name): return "multi:\(owner.lowercased())/\(name.lowercased())"
        case .user(let username, let section): return "user:\(username.lowercased()):\(section.rawValue)"
        case .search(let query, let community): return "search:\(community.map(IDNormalization.community) ?? ""):\(query.folding(options: .diacriticInsensitive, locale: .current).lowercased())"
        case .url(let url): return "url:\(url.absoluteString)"
        }
    }
}

struct FeedDescriptor: Hashable, Codable, Sendable, Identifiable {
    var destination: FeedDestination
    var sort: PostSort
    var topTime: TopTime?

    init(destination: FeedDestination, sort: PostSort = .default, topTime: TopTime? = nil) {
        self.destination = destination
        self.sort = sort
        self.topTime = topTime
    }

    var id: String { "\(destination.normalizedKey):\(sort.rawValue):\(topTime?.rawValue ?? "")" }
    var normalizedKey: String { destination.normalizedKey }
}

enum AppTab: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case posts
    case inbox
    case account
    case search
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .posts: return "Posts"
        case .inbox: return "Inbox"
        case .account: return "Account"
        case .search: return "Search"
        case .settings: return "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .posts: return "rectangle.stack"
        case .inbox: return "tray"
        case .account: return "person.crop.circle"
        case .search: return "magnifyingglass"
        case .settings: return "gearshape"
        }
    }
}

enum AppRoute: Hashable, Codable, Sendable {
    case feed(FeedDescriptor)
    case post(URL)
    case community(String)
    case user(String)
    case inbox
    case message(String)
    case search(query: String?, scope: SearchScope)
    case settings
    case account(AccountID?)
    case web(URL)
}

enum SheetRoute: Hashable, Codable, Sendable, Identifiable {
    case accountPicker
    case login
    case composePost(community: String?)
    case composeComment(postID: String, parentID: String?)
    case composeMessage(username: String?)
    case sort(feed: FeedDescriptor)
    case filters
    case share(URL)
    case error(DisplayableError)

    var id: String {
        switch self {
        case .accountPicker: return "account-picker"
        case .login: return "login"
        case .composePost(let community): return "compose-post:\(community ?? "")"
        case .composeComment(let postID, let parentID): return "compose-comment:\(postID):\(parentID ?? "")"
        case .composeMessage(let username): return "compose-message:\(username ?? "")"
        case .sort(let feed): return "sort:\(feed.id)"
        case .filters: return "filters"
        case .share(let url): return "share:\(url.absoluteString)"
        case .error(let error): return "error:\(error.title):\(error.message)"
        }
    }
}

struct ListingRequest: Hashable, Codable, Sendable {
    enum ResponseCachePolicy: String, Codable, Sendable {
        case useCache
        case reloadIgnoringCache
    }

    var feed: FeedDescriptor
    var limit: Int
    var after: String?
    var before: String?
    var accountScope: AccountScope
    var responseCachePolicy: ResponseCachePolicy

    init(
        feed: FeedDescriptor,
        limit: Int = 35,
        after: String? = nil,
        before: String? = nil,
        accountScope: AccountScope = .anonymous,
        responseCachePolicy: ResponseCachePolicy = .useCache
    ) {
        self.feed = feed
        self.limit = min(max(limit, 1), 100)
        self.after = after
        self.before = before
        self.accountScope = accountScope
        self.responseCachePolicy = responseCachePolicy
    }
}

enum RedditAction: Hashable, Codable, Sendable {
    case vote(fullname: String, direction: Int)
    case save(fullname: String, saved: Bool)
    case hide(fullname: String, hidden: Bool)
    case subscribe(community: String, subscribed: Bool)
    case comment(thingID: String, text: String)
    case edit(thingID: String, text: String)
    case delete(fullname: String)
    case markRead(fullname: String, read: Bool)
    case markAllRead
    case composeMessage(to: String, subject: String, text: String)
    case submitPost(community: String, title: String, text: String?, link: URL?, sendReplies: Bool)
    case crosspost(community: String, title: String, sourceFullname: String, sendReplies: Bool)
    case block(username: String, blocked: Bool)
    case follow(username: String, following: Bool)
}

struct ActionResult: Hashable, Codable, Sendable {
    var succeeded: Bool
    var message: String?
    var updatedPost: Post?
    var updatedComment: CommentNode?
    var updatedInboxItem: InboxItem?
}
