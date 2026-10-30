import Foundation

private enum CommentQuery {
    static let operation = GraphQLOperation(
        name: "PostComments",
        hash: "8a25ae56c1d4813102f4eded0c427b99f46f6a63f77630e78767f27ef5186f1f"
    )

    static let fragment: [String: GraphQLValue] = [
        "includeAwards": .bool(false),
        "includeCommentsHtmlField": .bool(false),
        "includeIsGildable": .bool(false),
        "includeModerationInfo": .bool(false),
        "subredditUserPostEditingAllowed": .bool(false),
        "includeExtendedVideoAsset": .bool(true),
        "includePlaybackMp4s": .bool(true),
        "includeMuxedMp4s": .bool(true),
        "includeVideoPlaybackInComments": .bool(false),
        "includeCommentViewStats": .bool(false),
        "includePremiumAvatarTreatment": .bool(false),
        "includeCommentFollowedForNotificationsStatus": .bool(false),
        "includeCommentEntityHighlights": .bool(false),
        "includeRedditHandleInfo": .bool(false),
        "includeVerificationStatus": .bool(false),
        "maxDepth": .int(10),
        "count": .int(200),
        "includeAdEligibility": .bool(false),
        "isUserMod": .bool(false),
        "skipPostInfoFragment": .bool(true),
        "includeConsistencyToken": .bool(false),
        "callerContext": .object(["referrer": .string("FEED")])
    ]

    static func variables(postID: String, sort: CommentSort, after: String? = nil, focusedID: String? = nil, context: Int = 0) throws -> [String: GraphQLValue] {
        var values = fragment
        values["id"] = .string(postID)
        switch sort {
        case .best: values["sortType"] = .string("CONFIDENCE")
        case .new: values["sortType"] = .string("NEW")
        case .top: values["sortType"] = .string("TOP")
        case .controversial: values["sortType"] = .string("CONTROVERSIAL")
        case .old: values["sortType"] = .string("OLD")
        case .qa: values["sortType"] = .string("QA")
        case .unknown: throw RedditClientError.invalidURL
        }
        if let after { values["after"] = .string(after) }
        if let focusedID {
            values["focusedCommentContext"] = .object([
                "commentId": .string(focusedID),
                "isFocusedThreadOnly": .bool(true),
                "minDeepCommentParents": .int(context)
            ])
            values["numParents"] = .int(context)
        }
        return values
    }
}

extension RedditGraphQLClient {
    func post(_ permalink: URL, sort: CommentSort, account: AccountID) async throws -> PostThread {
        guard let route = CommentRoute(permalink) else { throw RedditClientError.invalidURL }
        var postVariables = Self.postsByIDsVariables
        postVariables["ids"] = .array([.string(route.postFullname)])
        let commentVariables = try CommentQuery.variables(
            postID: route.postFullname, sort: sort,
            focusedID: route.focusedFullname, context: route.context
        )
        async let postData = execute(GraphQLOperation(
            name: "PostsByIds",
            hash: "b210ea1d852cdc2c25d9bff2d9fa8a406e1a968f36392798812f336694ac27f4"
        ), variables: postVariables, account: account)
        async let commentData = execute(CommentQuery.operation, variables: commentVariables, account: account)
        let (rawPost, rawComments) = try await (postData, commentData)
        guard let post = try RedditGraphQLCodec.posts(data: rawPost, orderedIDs: [route.postFullname], deletedPostPermalink: permalink).first else {
            throw RedditClientError.notFound
        }
        let parts = permalink.pathComponents
        if let index = parts.firstIndex(of: "r"), parts.indices.contains(index + 1) {
            try await checkCommunityAccess(name: parts[index + 1], account: account)
        } else if !post.community.name.isEmpty && !post.community.name.hasPrefix("u_") {
            try await checkCommunityAccess(name: post.community.name, account: account)
        }
        let generation = try await sessionGeneration(for: account)
        let nodes = try RedditGraphQLComments.decode(
            rawComments, postFullname: route.postFullname, parentFullname: route.postFullname,
            sort: sort, account: account, sessionGeneration: generation
        )
        return PostThread(post: post, comments: nodes)
    }

    func moreComments(postFullname: String, parentFullname: String, continuation: CommentContinuation, sort: CommentSort, account: AccountID) async throws -> [CommentTreeNode] {
        guard case .page(let token) = continuation,
              token.account == account,
              token.postFullname == postFullname,
              token.parentFullname == parentFullname,
              token.sort == sort,
              !token.cursor.isEmpty else { throw RedditClientError.invalidURL }
        let generation = try await sessionGeneration(for: account)
        guard token.sessionGeneration == generation else {
            throw RedditClientError.authenticationRequired
        }
        let variables = try CommentQuery.variables(postID: postFullname, sort: sort, after: token.cursor)
        let data = try await execute(CommentQuery.operation, variables: variables, account: account)
        guard generation == (try await sessionGeneration(for: account)) else {
            throw RedditClientError.authenticationRequired
        }
        return try RedditGraphQLComments.decode(
            data, postFullname: postFullname, parentFullname: parentFullname,
            sort: sort, account: account, sessionGeneration: generation,
            visitedCursors: token.visitedCursors
        )
    }
}

private struct CommentRoute {
    let postFullname: String
    let focusedFullname: String?
    let context: Int

    init?(_ url: URL) {
        guard url.scheme == "https", ["www.reddit.com", "reddit.com", "old.reddit.com"].contains(url.host?.lowercased() ?? "") else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard let index = parts.firstIndex(of: "comments"), parts.indices.contains(index + 1) else { return nil }
        let postID = parts[index + 1]
        guard postID.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) != nil else { return nil }
        postFullname = "t3_\(postID)"
        let trailing = Array(parts.dropFirst(index + 2))
        let focus = trailing.last.flatMap { $0.range(of: "^[A-Za-z0-9]+$", options: .regularExpression) == nil ? nil : $0 }
        focusedFullname = trailing.count >= 2 && focus != "_" ? focus.map { "t1_\($0)" } : nil
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        context = min(max(Int(query.first(where: { $0.name == "context" })?.value ?? "0") ?? 0, 0), 20)
    }
}

enum RedditGraphQLComments {
    static func decode(_ data: Data, postFullname: String, parentFullname: String, sort: CommentSort, account: AccountID, sessionGeneration: String, visitedCursors: [String] = []) throws -> [CommentTreeNode] {
        let payload = try RedditGraphQLCodec.payload(data)
        guard let forest = payload["postInfoById"]?.objectValue?["commentForest"]?.objectValue,
              let trees = forest["trees"]?.arrayValue else { throw RedditClientError.malformedResponse }
        let raw = trees.compactMap(\.objectValue)
        let baseDepth = raw.compactMap { $0["depth"]?.numberValue.map(Int.init) }.min() ?? 0
        var result: [CommentTreeNode] = []
        var ancestors: [(id: String, path: [Int])] = []
        var seen = Set<String>()
        for (index, tree) in raw.enumerated() {
            let depth = max(0, Int(tree["depth"]?.numberValue ?? Double(baseDepth)) - baseDepth)
            guard depth == 0 || ancestors.indices.contains(depth - 1) else { continue }
            let parent = depth == 0 ? parentFullname : ancestors[depth - 1].id
            let parentPath = depth == 0 ? [] : ancestors[depth - 1].path
            let node: CommentTreeNode
            if let more = tree["more"]?.objectValue,
               let cursor = more["cursor"]?.stringValue, !cursor.isEmpty,
               !visitedCursors.contains(cursor) {
                let token = CommentPageToken(cursor: cursor, account: account, postFullname: postFullname,
                                             parentFullname: parent, sort: sort, sessionGeneration: sessionGeneration,
                                             visitedCursors: Array((visitedCursors + [cursor]).suffix(64)))
                node = .more(MoreCommentsNode(
                    id: "more-\(postFullname)-\(parent)-\(cursor)", parentFullname: parent,
                    continuation: .page(token), count: more["count"]?.numberValue.map(Int.init)
                ))
            } else if let value = tree["node"]?.objectValue {
                let treeDepth = Int(tree["depth"]?.numberValue ?? Double(baseDepth))
                var childParentID: String?
                var hasChildren = false
                for descendant in raw.dropFirst(index + 1) {
                    let descendantDepth = Int(descendant["depth"]?.numberValue ?? Double(baseDepth))
                    if descendantDepth <= treeDepth { break }
                    if descendantDepth == treeDepth + 1 {
                        hasChildren = true
                        childParentID = descendant["parentId"]?.stringValue ?? childParentID
                        if childParentID != nil { break }
                    }
                }
                node = mapComment(value, parent: parent, index: index, inferredID: childParentID, hasChildren: hasChildren)
            } else { continue }
            guard seen.insert(node.id).inserted else { continue }
            let path = append(node, to: &result, under: parentPath)
            if case .comment(let comment) = node {
                ancestors = Array(ancestors.prefix(depth))
                ancestors.append((comment.fullname, path))
            } else if case .deleted(let deleted) = node {
                ancestors = Array(ancestors.prefix(depth))
                ancestors.append((deleted.id, path))
            }
        }
        return result
    }

    private static func append(_ node: CommentTreeNode, to values: inout [CommentTreeNode], under path: [Int]) -> [Int] {
        guard let head = path.first, values.indices.contains(head) else {
            values.append(node)
            return [values.count - 1]
        }
        if case .comment(var parent) = values[head] {
            let childPath = append(node, to: &parent.children, under: Array(path.dropFirst()))
            values[head] = .comment(parent)
            return [head] + childPath
        }
        values.append(node)
        return [values.count - 1]
    }

    private static func mapComment(_ value: [String: RedditJSONValue], parent: String, index: Int, inferredID: String?, hasChildren: Bool) -> CommentTreeNode {
        let removed = value["__typename"]?.stringValue != "Comment" || value["isRemoved"]?.boolValue == true || value["content"]?.objectValue == nil
        let fullname = value["id"]?.stringValue ?? inferredID ?? "deleted-\(parent)-\(index)"
        let reason = value["removedByCategory"]?.stringValue.map { $0 == "DELETED" ? "[deleted]" : "[removed]" } ?? "[deleted]"
        if removed && !hasChildren {
            return .deleted(DeletedCommentNode(id: fullname, parentFullname: parent, reason: reason))
        }
        let text = removed ? RichText(plainText: reason) : RedditGraphQLRichText.decode(value["content"]?.objectValue ?? [:], thingID: fullname)
        let date = timestamp(value["createdAt"])
        let vote: VoteState
        switch value["voteState"]?.stringValue {
        case "UP": vote = .upvoted
        case "DOWN": vote = .downvoted
        default: vote = .unknown
        }
        return .comment(CommentNode(
            id: String(fullname.removingPrefix("t1_")), fullname: fullname, parentFullname: parent,
            author: removed ? nil : value["authorInfo"]?.objectValue?["name"]?.stringValue.map(UserReference.init(username:)),
            authorFlair: removed ? nil : flair(value["authorFlair"]),
            body: text, createdAt: date,
            score: removed || value["isScoreHidden"]?.boolValue == true ? nil : value["score"]?.numberValue.map(Int.init), vote: vote,
            isSaved: value["isSaved"]?.boolValue ?? false, isLocked: value["isLocked"]?.boolValue ?? false,
            isDistinguished: value["distinguishedAs"]?.stringValue == "MODERATOR", children: []
        ))
    }

    private static func timestamp(_ value: RedditJSONValue?) -> Date {
        if let seconds = value?.numberValue ?? value?.stringValue.flatMap(Double.init) {
            return Date(timeIntervalSince1970: seconds > 100_000_000_000 ? seconds / 1000 : seconds)
        }
        guard let string = value?.stringValue else { return Date(timeIntervalSince1970: 0) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: string) { return date }
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"
        if let date = fallback.date(from: string) { return date }
        fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return fallback.date(from: string) ?? Date(timeIntervalSince1970: 0)
    }

    private static func flair(_ value: RedditJSONValue?) -> Flair? {
        guard let object = value?.objectValue else { return nil }
        let text = object["text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let segments: [RedditJSONValue] = {
            guard let source = object["richtext"]?.stringValue,
                  let data = source.data(using: .utf8) else { return [] }
            return (try? JSONDecoder().decode([RedditJSONValue].self, from: data)) ?? []
        }()
        let emojiURLs = segments.compactMap { segment -> URL? in
            guard let item = segment.objectValue, item["e"]?.stringValue == "emoji",
                  let url = URL(string: item["u"]?.stringValue ?? ""), url.scheme == "https" else { return nil }
            return url
        }
        let richText = segments.compactMap { segment -> String? in
            guard let item = segment.objectValue, item["e"]?.stringValue == "text" else { return nil }
            return item["t"]?.stringValue
        }.joined()
        let displayText = richText.isEmpty ? text : richText
        guard !displayText.isEmpty || !emojiURLs.isEmpty else { return nil }
        return Flair(id: object["template"]?.objectValue?["id"]?.stringValue ?? text, text: displayText,
                     backgroundColor: object["backgroundColor"]?.stringValue,
                     textColor: object["textColor"]?.stringValue, emojiURLs: emojiURLs)
    }
}

private extension String {
    func removingPrefix(_ prefix: String) -> String { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self }
}
