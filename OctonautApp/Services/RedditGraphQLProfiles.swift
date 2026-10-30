import Foundation

private struct ProfileCursor: Codable {
    let account: String
    let session: String
    let query: String
    let value: String
    let visited: [String]

    func encoded() throws -> String {
        try JSONEncoder().encode(self).base64EncodedString()
    }

    static func decode(_ raw: String?, account: AccountID, session: String, query: String) throws -> ProfileCursor? {
        guard let raw else { return nil }
        guard let data = Data(base64Encoded: raw),
              let cursor = try? JSONDecoder().decode(ProfileCursor.self, from: data),
              cursor.account == account.description, cursor.session == session,
              cursor.query == query, !cursor.value.isEmpty,
              cursor.visited.last == cursor.value, cursor.visited.count <= 64 else {
            throw RedditClientError.invalidResponse
        }
        return cursor
    }

}

private struct SubscriptionCursor: Codable {
    let account: String
    let session: String
    let subscribed: String?
    let followed: String?
    let subscribedFinished: Bool
    let followedFinished: Bool

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(self).base64EncodedString()
    }

    static func decode(_ raw: String?, account: AccountID, session: String) throws -> SubscriptionCursor {
        guard let raw else {
            return SubscriptionCursor(account: account.description, session: session, subscribed: nil,
                                      followed: nil, subscribedFinished: false, followedFinished: false)
        }
        guard let data = Data(base64Encoded: raw),
              let cursor = try? JSONDecoder().decode(SubscriptionCursor.self, from: data),
              cursor.account == account.description, cursor.session == session,
              (!cursor.subscribedFinished || cursor.subscribed == nil),
              (!cursor.followedFinished || cursor.followed == nil) else {
            throw RedditClientError.invalidResponse
        }
        return cursor
    }
}

extension RedditGraphQLClient {
    private static let getAccountOperation = GraphQLOperation(
        name: "GetAccount", hash: "b5ad6715b375f0a4c5347979f1237364025b78028b90a8a618e9b1e8036b26ef")
    private static let userProfileOperation = GraphQLOperation(
        name: "UserProfile", hash: "a05c628c5469c6b107c85988a8b1d0b79a2e7b6150ebd3a449c67e226e975ddc")
    private static let submittedPostsOperation = GraphQLOperation(
        name: "SubmittedPostsFeedSdui", hash: "d973adb1955e30c12e200bd2dbe843172276aebbae0ff1a8dda76f0ad19a0605")
    private static let submittedCommentsOperation = GraphQLOperation(
        name: "SubmittedComments", hash: "e1b37f521fb40af2120946b70e7fbf6a3d924db2abaf28ff2164d4cfacca28db")
    private static let savedPostsOperation = GraphQLOperation(
        name: "SavedPostsFeedSdui", hash: "929e762251408c04a8734d2ba51128c733dbabad9b8bbb313f919e2fd3ae54ce")
    private static let savedCommentsOperation = GraphQLOperation(
        name: "SavedComments", hash: "f59debcda8c989bcd661947fb7cb311559d1d9df8329ef000dc31817a399de81")
    private static let upvotedOperation = GraphQLOperation(
        name: "UpvotedPosts", hash: "4997de5649516763ab57f3f70eeba4c7638978c8613fc81c3212b1b5dbd0497e")
    private static let downvotedOperation = GraphQLOperation(
        name: "DownvotedPosts", hash: "8e0d27e0f698b8718928bc8ebb0c5b5690b51bceb862db7ce4c7da6c4deef0f5")
    private static let hiddenOperation = GraphQLOperation(
        name: "HiddenPosts", hash: "7548e75ad724b6888e7901b3a757d5111008c02624af20b0141b40fdca6276d2")
    private static let commentsByIDsOperation = GraphQLOperation(
        name: "LiveCommentsByIds", hash: "f6ea957fbe5df4386492b6f153c90e8f0f3d2d3556e908e4e4eb9c5afdb1ffa1")
    private static let userSubredditsOperation = GraphQLOperation(
        name: "UserSubreddits", hash: "333abc2dc448cbfa598f984225c4a05a69c70db0ed55d88a33a526d5403389ef")
    private static let postsByIDsOperation = GraphQLOperation(
        name: "PostsByIds", hash: "b210ea1d852cdc2c25d9bff2d9fa8a406e1a968f36392798812f336694ac27f4")

    func isSelectedAccountOwner(_ username: String, account: AccountID) async throws -> Bool {
        let data = try await execute(Self.getAccountOperation, variables: [
            "includePremiumAvatarTreatment": .bool(false),
            "includeBrandToolsStatus": .bool(false),
            "includePostFlairTemplates": .bool(false),
            "includeRedditHandleInfo": .bool(false),
            "includeVerificationStatus": .bool(false),
            "includeHumanVerificationActionNeeded": .bool(false)
        ], account: account)
        let root = try RedditGraphQLCodec.payload(data)
        guard let name = root["identity"]?.objectValue?["redditor"]?.objectValue?["name"]?.stringValue,
              !name.isEmpty else { throw RedditClientError.malformedResponse }
        return name.caseInsensitiveCompare(username) == .orderedSame
    }

    func userProfile(_ username: String, account: AccountID) async throws -> UserProfile {
        let data = try await execute(Self.userProfileOperation, variables: [
            "name": .string(username), "includePremiumAvatarTreatment": .bool(false)
        ], account: account)
        return try RedditGraphQLCodec.userProfile(data: data)
    }

    func userPosts(_ request: ListingRequest, username: String, section: UserSection,
                   account: AccountID) async throws -> Listing<Post> {
        guard request.before == nil else { throw RedditClientError.invalidResponse }
        if section.isPrivateToOwner {
            guard request.feed.sort == .default || request.feed.sort == .new,
                  request.feed.topTime == nil else { throw RedditClientError.invalidResponse }
        }
        let session = try await sessionGeneration(for: account)
        let query = "posts:\(username.lowercased()):\(section.rawValue):\(request.feed.sort.rawValue):\(request.feed.topTime?.rawValue ?? "")"
        let cursor = try ProfileCursor.decode(request.after, account: account, session: session, query: query)
        let operation: GraphQLOperation
        var variables: [String: GraphQLValue] = [:]
        switch section {
        case .overview, .submitted:
            operation = Self.submittedPostsOperation
            variables["username"] = .string(username)
            variables["sort"] = .string(try userSort(request.feed.sort))
            if let time = request.feed.topTime { variables["time"] = .string(time.rawValue.uppercased()) }
        case .saved:
            operation = Self.savedPostsOperation
        case .upvoted, .downvoted, .hidden:
            operation = switch section {
            case .upvoted: Self.upvotedOperation
            case .downvoted: Self.downvotedOperation
            default: Self.hiddenOperation
            }
            variables = Self.profilePostFragmentVariables
            variables["pageSize"] = .int(min(max(request.limit, 1), 100))
        case .comments:
            throw RedditClientError.invalidResponse
        }
        if let cursor { variables["after"] = .string(cursor.value) }
        var seen = cursor?.visited ?? []
        var emptyHops = 0
        while true {
            let data = try await execute(operation, variables: variables, account: account)
            let serverAfter: String?
            let posts: [Post]
            switch section {
            case .overview, .submitted, .saved:
                let page = try RedditGraphQLCodec.profilePostIDs(data: data, section: section)
                serverAfter = page.after
                if page.ids.isEmpty {
                    posts = []
                } else {
                    var hydration = Self.postsByIDsVariables
                    hydration["ids"] = .array(page.ids.map(GraphQLValue.string))
                    let hydrated = try await execute(Self.postsByIDsOperation, variables: hydration, account: account)
                    posts = try RedditGraphQLCodec.posts(data: hydrated, orderedIDs: page.ids)
                }
            default:
                let field = switch section {
                case .upvoted: "upvotedPosts"
                case .downvoted: "downvotedPosts"
                default: "hiddenPosts"
                }
                let page = try RedditGraphQLCodec.identityPosts(data: data, field: field)
                serverAfter = page.after
                posts = page.items
            }
            let next = serverAfter.flatMap { seen.contains($0) ? nil : $0 }
            if let next { seen.append(next) }
            if posts.isEmpty, let next, emptyHops < 3 {
                variables["after"] = .string(next)
                emptyHops += 1
                continue
            }
            return Listing(items: posts, after: try scopedAfter(next, seen: seen,
                account: account, session: session, query: query))
        }
    }

    func userComments(_ username: String, section: UserSection, after: String?,
                      account: AccountID) async throws -> Listing<UserComment> {
        guard [.overview, .submitted, .comments, .saved].contains(section) else {
            return Listing(items: [])
        }
        let session = try await sessionGeneration(for: account)
        let query = "comments:\(username.lowercased()):\(section.rawValue)"
        let cursor = try ProfileCursor.decode(after, account: account, session: session, query: query)
        let operation = section == .saved ? Self.savedCommentsOperation : Self.submittedCommentsOperation
        var variables: [String: GraphQLValue] = [:]
        if section != .saved {
            variables["name"] = .string(username)
            variables["sort"] = .string("NEW")
            variables["pageSize"] = .int(25)
        }
        if let cursor { variables["after"] = .string(cursor.value) }
        var seen = cursor?.visited ?? []
        var emptyHops = 0
        while true {
            let data = try await execute(operation, variables: variables, account: account)
            let page = try RedditGraphQLCodec.commentEdges(data: data, section: section)
            let comments: [UserComment]
            if page.edges.isEmpty {
                comments = []
            } else {
                var hydration = Self.commentFragmentVariables
                hydration["ids"] = .array(page.edges.map { .string($0.id) })
                let full = try await execute(Self.commentsByIDsOperation, variables: hydration, account: account)
                comments = try RedditGraphQLCodec.hydratedUserComments(data: full, edges: page.edges)
            }
            let next = page.after.flatMap { seen.contains($0) ? nil : $0 }
            if let next { seen.append(next) }
            if comments.isEmpty, let next, emptyHops < 3 {
                variables["after"] = .string(next)
                emptyHops += 1
                continue
            }
            return Listing(items: comments, after: try scopedAfter(next, seen: seen,
                account: account, session: session, query: query))
        }
    }

    func subscribedCommunities(after: String?, account: AccountID) async throws -> Listing<Community> {
        let session = try await sessionGeneration(for: account)
        let cursor = try SubscriptionCursor.decode(after, account: account, session: session)
        guard !cursor.subscribedFinished || !cursor.followedFinished else { return Listing(items: []) }
        let variables: [String: GraphQLValue] = [
            "fetchSubscribed": .bool(!cursor.subscribedFinished),
            "subscribedAfter": cursor.subscribed.map(GraphQLValue.string) ?? .null,
            "fetchFollowed": .bool(!cursor.followedFinished),
            "followedAfter": cursor.followed.map(GraphQLValue.string) ?? .null,
            "fetchModerated": .bool(false),
            "moderatedAfter": .null,
            "limit": .int(100),
            "includeRedditHandleInfo": .bool(false),
            "includeVerificationStatus": .bool(false)
        ]
        let data = try await execute(Self.userSubredditsOperation, variables: variables, account: account)
        let page = try RedditGraphQLCodec.subscriptions(data: data,
            fetchSubscribed: !cursor.subscribedFinished, fetchFollowed: !cursor.followedFinished)
        let nextSubscribed = page.subscribedAfter != cursor.subscribed ? page.subscribedAfter : nil
        let nextFollowed = page.followedAfter != cursor.followed ? page.followedAfter : nil
        let next = SubscriptionCursor(account: account.description, session: session,
            subscribed: nextSubscribed, followed: nextFollowed,
            subscribedFinished: nextSubscribed == nil, followedFinished: nextFollowed == nil)
        return Listing(items: page.communities,
                       after: next.subscribedFinished && next.followedFinished ? nil : try next.encoded())
    }

    private func scopedAfter(_ serverAfter: String?, seen: [String],
                             account: AccountID, session: String, query: String) throws -> String? {
        guard let serverAfter, !serverAfter.isEmpty else { return nil }
        return try ProfileCursor(account: account.description, session: session, query: query,
                                 value: serverAfter, visited: Array(seen.suffix(64))).encoded()
    }

    private func userSort(_ sort: PostSort) throws -> String {
        switch sort {
        case .default, .new: "NEW"
        case .hot: "HOT"
        case .top: "TOP"
        case .controversial: "CONTROVERSIAL"
        default: throw RedditClientError.invalidResponse
        }
    }

    private static let profilePostFragmentVariables: [String: GraphQLValue] = {
        let names = Set("includeSubredditInPosts includeAwards includePostStats includeCurrentUserAwards includeStillMediaAltText includeExtraStillResolutions includeExtendedVideoAsset includePlaybackMp4s includeMuxedMp4s includeDevvitData includeCommunityStatus includeIsModRemovedContentReadAllowed includeVideoPlaybackInComments includeSubredditBackgroundColor includeOverlayData includeCtaEnrichedPageTitle includePlaCards includePlaCardThumbnail includeWebviewPrefetchField includeAdBrowserDestinationField includeCollectionsHeroCard includeGalleryAdUrl includeCtaMediaColor includeFollowedForNotificationsStatus includePredictedRemovalReasons includeRedditHandleInfo includeVerificationStatus skipModerationInfo includeIsReceivingPostReplies includeIsActiveComments includeMediaSynthesis skipRedditPlayPlaybackMp4s includeLinkPreviewTitle".split(separator: " ").map(String.init))
        return postsByIDsVariables.filter { names.contains($0.key) }
    }()

    private static let commentFragmentVariables: [String: GraphQLValue] = {
        var values: [String: GraphQLValue] = [:]
        for name in "includeAwards includeCommentsHtmlField includeIsGildable includeModerationInfo subredditUserPostEditingAllowed includeVideoPlaybackInComments includeCommentViewStats includePremiumAvatarTreatment includeCommentFollowedForNotificationsStatus includeCommentEntityHighlights includeRedditHandleInfo includeVerificationStatus".split(separator: " ") {
            values[String(name)] = .bool(false)
        }
        for name in "includeExtendedVideoAsset includePlaybackMp4s includeMuxedMp4s".split(separator: " ") {
            values[String(name)] = .bool(true)
        }
        return values
    }()
}
