import Foundation

/// A deliberately tolerant JSON value. Reddit occasionally adds fields or
/// returns null where a field was present before, so transport decoding does
/// not use a rigid Codable struct for every Reddit object.
enum RedditJSONValue: Decodable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([RedditJSONValue])
    case object([String: RedditJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([RedditJSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: RedditJSONValue].self))
        }
    }

    var objectValue: [String: RedditJSONValue]? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [RedditJSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    var numberValue: Double? {
        if case .number(let value) = self { return value }
        return nil
    }
}

enum RedditGraphQLCodec {
    enum CommunityAccess {
        case available, missing, banned, privateCommunity, quarantined, gated
    }

    private struct Envelope: Decodable {
        let data: [String: RedditJSONValue]
    }

    static func payload(_ data: Data) throws -> [String: RedditJSONValue] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        return envelope.data
    }

    private static func searchConnection(_ data: Data, key: String) throws -> [String: RedditJSONValue] {
        let root = try payload(data)
        guard let connection = root["search"]?.objectValue?["general"]?.objectValue?[key]?.objectValue,
              connection["edges"]?.arrayValue != nil,
              connection["pageInfo"]?.objectValue != nil else {
            throw RedditClientError.malformedResponse
        }
        return connection
    }

    static func after(_ connection: [String: RedditJSONValue]) throws -> String? {
        guard let pageInfo = connection["pageInfo"]?.objectValue,
              let hasNextPage = pageInfo["hasNextPage"]?.boolValue else {
            throw RedditClientError.malformedResponse
        }
        guard hasNextPage else { return nil }
        guard let cursor = pageInfo["endCursor"]?.stringValue, !cursor.isEmpty else {
            throw RedditClientError.malformedResponse
        }
        return cursor
    }

    static func nodes(_ connection: [String: RedditJSONValue]) -> [[String: RedditJSONValue]] {
        connection["edges"]?.arrayValue?.compactMap {
            $0.objectValue?["node"]?.objectValue
        } ?? []
    }

    static func feedPostIDs(data: Data) throws -> [String] {
        feedPostIDs(elements: try feedElements(data))
    }

    private static func feedElements(_ data: Data) throws -> [String: RedditJSONValue] {
        let root = try payload(data)
        guard root.count == 1,
              let feed = root.values.first?.objectValue,
              let elements = feed["elements"]?.objectValue,
              elements["edges"]?.arrayValue != nil else {
            throw RedditClientError.malformedResponse
        }
        return elements
    }

    private static func feedPostIDs(elements: [String: RedditJSONValue]) -> [String] {
        var seen = Set<String>()
        return (elements["edges"]?.arrayValue ?? []).compactMap { edge -> String? in
            guard let node = edge.objectValue?["node"]?.objectValue,
                  !isAd(node),
                  let id = node["groupId"]?.stringValue ?? node["id"]?.stringValue,
                  id.hasPrefix("t3_"), id.count > 3 else { return nil }
            return seen.insert(id).inserted ? id : nil
        }
    }

    static func feedPage(data: Data) throws -> (ids: [String], after: String?) {
        let elements = try feedElements(data)
        let ids = feedPostIDs(elements: elements)
        guard let pageInfo = elements["pageInfo"]?.objectValue else { return (ids, ids.last) }
        guard let hasNext = pageInfo["hasNextPage"]?.boolValue else { throw RedditClientError.malformedResponse }
        guard hasNext else { return (ids, nil) }
        guard let encoded = pageInfo["endCursor"]?.stringValue,
              let bytes = Data(base64Encoded: encoded), let fullname = String(data: bytes, encoding: .utf8),
              fullname.range(of: "^t3_[A-Za-z0-9]+$", options: .regularExpression) != nil else {
            throw RedditClientError.malformedResponse
        }
        return (ids, fullname)
    }

    static func communityAccess(data: Data) throws -> CommunityAccess {
        let root = try payload(data)
        guard let value = root["subredditInfoByName"] else { throw RedditClientError.malformedResponse }
        if case .null = value { return .missing }
        guard let node = value.objectValue else { throw RedditClientError.malformedResponse }
        switch node["forbiddenReason"]?.stringValue {
        case "BANNED": return .banned
        case "PRIVATE", "GOLD_ONLY": return .privateCommunity
        case "QUARANTINED": return .quarantined
        case "GATED": return .gated
        default:
            if node["__typename"]?.stringValue == "Subreddit" { return .available }
            throw RedditClientError.accessDenied
        }
    }

    static func discoveryCommunities(data: Data, limit: Int) throws -> [Community] {
        let root = try payload(data)
        guard let edges = root["exploreFeedV1"]?.objectValue?["elements"]?.objectValue?["edges"]?.arrayValue else {
            throw RedditClientError.malformedResponse
        }
        let groups: [[[String: RedditJSONValue]]] = edges.compactMap { edge in
            edge.objectValue?["node"]?.objectValue?["communityRecommendations"]?.arrayValue?.compactMap {
                $0.objectValue?["subreddit"]?.objectValue
            }
        }
        var seen = Set<String>()
        var communities: [Community] = []
        for index in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where index < group.count {
                let node = group[index]
                guard let name = node["name"]?.stringValue, !name.isEmpty,
                      node["isSubscribed"]?.boolValue != true,
                      seen.insert(name.lowercased()).inserted else { continue }
                var fields: [String: RedditJSONValue] = ["display_name": .string(name), "display_name_prefixed": .string("r/\(name)")]
                fields["title"] = node["title"]
                fields["public_description"] = node["publicDescriptionText"]
                fields["subscribers"] = node["subscribersCount"]
                fields["community_icon"] = node["styles"]?.objectValue?["icon"]
                    ?? node["styles"]?.objectValue?["legacyIcon"]?.objectValue?["url"]
                fields["user_is_subscriber"] = node["isSubscribed"]
                fields["quarantine"] = node["isQuarantined"]
                if let community = RedditJSONCodec.mapCommunity(fields) { communities.append(community) }
                if communities.count >= limit { return communities }
            }
        }
        return communities
    }

    static func posts(data: Data, orderedIDs: [String], deletedPostPermalink: URL? = nil) throws -> [Post] {
        let root = try payload(data)
        guard let infos = root["postsInfoByIds"]?.arrayValue else {
            throw RedditClientError.malformedResponse
        }
        let requested = Set(orderedIDs)
        var byID: [String: Post] = [:]
        for value in infos {
            guard var node = value.objectValue else { continue }
            if node["__typename"]?.stringValue == "DeletedProfilePost" {
                guard let id = node["id"]?.stringValue ?? (orderedIDs.count == 1 ? orderedIDs.first : nil) else { continue }
                node["id"] = .string(id)
                node["title"] = .string("[deleted]")
                node["permalink"] = .string(deletedPostPermalink?.absoluteString ?? "/comments/\(id.dropFirst(3))/")
            }
            guard
                  let id = node["id"]?.stringValue,
                  requested.contains(id),
                  let post = post(node) else { continue }
            byID[id] = post
        }
        return orderedIDs.compactMap { byID[$0] }
    }

    static func searchPosts(data: Data) throws -> Listing<Post> {
        let connection = try searchConnection(data, key: "posts")
        let posts = nodes(connection).compactMap(post)
        return Listing(items: posts, after: try after(connection))
    }

    static func communities(data: Data) throws -> Listing<Community> {
        let connection = try searchConnection(data, key: "communities")
        let communities = nodes(connection).compactMap { node -> Community? in
            guard node["__typename"]?.stringValue == "Subreddit",
                  let name = node["name"]?.stringValue, !name.isEmpty else { return nil }
            var fields: [String: RedditJSONValue] = ["display_name": .string(name)]
            fields["display_name_prefixed"] = .string("r/\(name)")
            fields["title"] = node["title"]
            fields["public_description"] = node["publicDescriptionText"]
            fields["subscribers"] = node["subscribersCount"]
            fields["community_icon"] = node["styles"]?.objectValue?["icon"]
                ?? node["styles"]?.objectValue?["legacyIcon"]?.objectValue?["url"]
            fields["user_is_subscriber"] = node["isSubscribed"]
            fields["quarantine"] = node["isQuarantined"]
            return RedditJSONCodec.mapCommunity(fields)
        }
        return Listing(items: communities, after: try after(connection))
    }

    static func users(data: Data) throws -> Listing<UserProfile> {
        let connection = try searchConnection(data, key: "authors")
        let users = nodes(connection).compactMap { node -> UserProfile? in
            guard node["__typename"]?.stringValue == "Redditor",
                  let name = node["name"]?.stringValue, !name.isEmpty else { return nil }
            var fields: [String: RedditJSONValue] = ["name": .string(name)]
            fields["total_karma"] = node["karma"]?.objectValue?["total"]
            fields["created_utc"] = timestamp(node["profile"]?.objectValue?["createdAt"])
            fields["icon_img"] = node["profile"]?.objectValue?["icon"]?.stringValue.map(RedditJSONValue.string)
            fields["subreddit"] = .object(["user_is_subscriber": node["isFollowed"] ?? .bool(false)])
            return RedditJSONCodec.mapUserProfile(fields)
        }
        return Listing(items: users, after: try after(connection))
    }

    static func post(_ node: [String: RedditJSONValue]) -> Post? {
        guard ["SubredditPost", "ProfilePost", "DeletedSubredditPost", "DeletedProfilePost"].contains(node["__typename"]?.stringValue ?? ""),
              let fullname = node["id"]?.stringValue, fullname.hasPrefix("t3_"),
              let title = node["postTitle"]?.stringValue ?? node["title"]?.stringValue else { return nil }
        let id = String(fullname.dropFirst(3))
        let community = node["subreddit"]?.objectValue ?? node["profile"]?.objectValue ?? [:]
        let communityName = community["name"]?.stringValue ?? ""
        let deleted = ["DeletedSubredditPost", "DeletedProfilePost"].contains(node["__typename"]?.stringValue ?? "")
        let body = RedditGraphQLRichText.decode(node["content"]?.objectValue ?? [:], thingID: fullname)?.plainText ?? ""
        let permalink = node["permalink"]?.stringValue ?? "/r/\(communityName)/comments/\(id)/"
        var fields: [String: RedditJSONValue] = [
            "id": .string(id), "name": .string(fullname), "title": .string(title),
            "permalink": .string(permalink), "subreddit": .string(communityName),
            "subreddit_name_prefixed": .string("r/\(communityName)"),
            "author": .string(node["authorInfo"]?.objectValue?["name"]?.stringValue ?? "[deleted]"),
            "selftext": .string(deleted ? "[deleted]" : body),
            "url": node["url"] ?? .string("https://www.reddit.com\(permalink)"),
            "is_self": deleted ? .bool(true) : (node["isSelfPost"] ?? .bool(false)),
            "saved": node["isSaved"] ?? .bool(false),
            "hidden": node["isHidden"] ?? .bool(false),
            "over_18": node["isNsfw"] ?? .bool(false),
            "spoiler": node["isSpoiler"] ?? .bool(false),
            "locked": node["isLocked"] ?? .bool(false),
            "archived": node["isArchived"] ?? .bool(false),
            "stickied": node["isStickied"] ?? .bool(false)
        ]
        fields["community_icon"] = community["styles"]?.objectValue?["icon"]
            ?? community["styles"]?.objectValue?["legacyIcon"]?.objectValue?["url"]
        fields["created_utc"] = timestamp(node["createdAt"])
        fields["score"] = node["score"]
        fields["num_comments"] = node["commentCount"]
        fields["likes"] = vote(node["voteState"])
        fields["link_flair_text"] = node["flair"]?.objectValue?["text"]
        fields["link_flair_template_id"] = node["flair"]?.objectValue?["template"]?.objectValue?["id"]
        fields["author_flair_text"] = node["authorFlair"]?.objectValue?["text"]
        fields["author_flair_richtext"] = authorFlair(node["authorFlair"])
        addMedia(node, to: &fields)
        guard var result = RedditJSONCodec.mapPost(fields, kind: "t3") else { return nil }
        if let poll = node["poll"]?.objectValue,
           let options = poll["options"]?.arrayValue?.compactMap(\.objectValue), !options.isEmpty {
            result.media = .poll(Poll(
                id: fullname,
                options: options.compactMap { option in
                    guard let id = option["id"]?.stringValue,
                          let text = option["text"]?.stringValue else { return nil }
                    return Poll.Option(id: id, text: text, voteCount: option["voteCount"]?.numberValue.map(Int.init))
                },
                totalVoteCount: Int(options.compactMap { $0["voteCount"]?.numberValue }.reduce(0, +)),
                userChoice: poll["userChoice"]?.stringValue
            ))
        }
        if let parent = node["crosspostRoot"]?.objectValue?["post"]?.objectValue,
           let parentID = parent["id"]?.stringValue, parentID != fullname,
           let parentPost = post(parent) {
            result.crosspost = CrosspostReference(
                postID: parentPost.id, permalink: parentPost.permalink,
                community: parentPost.community, title: parentPost.title
            )
            switch result.media {
            case .none:
                result.media = parentPost.media
            case .link(let target, _) where RedditReportTarget.isRedditURL(target):
                result.media = parentPost.media
            default:
                break
            }
        }
        return result
    }

    private static func vote(_ value: RedditJSONValue?) -> RedditJSONValue? {
        switch value?.stringValue {
        case "UP": return .bool(true)
        case "DOWN": return .bool(false)
        default: return nil
        }
    }

    private static func isAd(_ node: [String: RedditJSONValue]) -> Bool {
        guard let value = node["adPayload"] else { return false }
        if case .null = value { return false }
        return true
    }

    static func timestamp(_ value: RedditJSONValue?) -> RedditJSONValue? {
        guard let raw = value?.stringValue else { return nil }
        let normal = raw.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: #"([+-]\d{2})(\d{2})$"#, with: "$1:$2", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: normal) ?? ISO8601DateFormatter().date(from: normal)
        return date.map { .number($0.timeIntervalSince1970) }
    }

    private static func authorFlair(_ value: RedditJSONValue?) -> RedditJSONValue? {
        guard let source = value?.objectValue?["richtext"]?.stringValue,
              let data = source.data(using: .utf8),
              let segments = try? JSONDecoder().decode([RedditJSONValue].self, from: data) else { return nil }
        return .array(segments)
    }

    private static func addMedia(_ node: [String: RedditJSONValue], to fields: inout [String: RedditJSONValue]) {
        let media = node["media"]?.objectValue ?? [:]
        let still = media["still"]?.objectValue ?? [:]
        let source = still["source"]?.objectValue ?? still["xxxlarge"]?.objectValue
            ?? still["xlarge"]?.objectValue ?? still["large"]?.objectValue
        if let source, let url = source["url"]?.stringValue {
            fields["preview"] = .object(["images": .array([.object(["source": .object([
                "url": .string(url),
                "width": source["dimensions"]?.objectValue?["width"] ?? .null,
                "height": source["dimensions"]?.objectValue?["height"] ?? .null
            ])])])])
            let target = node["url"]?.stringValue ?? ""
            if target.isEmpty || target.contains("reddit.com/r/") || target.contains("redd.it/") {
                fields["post_hint"] = .string("image")
            }
        }
        if let streaming = media["streaming"]?.objectValue,
           let hlsURL = streaming["hlsUrl"]?.stringValue {
            let dimensions = streaming["dimensions"]?.objectValue ?? [:]
            fields["secure_media"] = .object(["reddit_video": .object([
                "hls_url": .string(hlsURL), "is_gif": streaming["isGif"] ?? .bool(false),
                "width": dimensions["width"] ?? .null, "height": dimensions["height"] ?? .null
            ])])
        } else if let animated = media["animated"]?.objectValue,
                  let mp4 = animated["mp4_source"]?.objectValue ?? animated["mp4_xxxlarge"]?.objectValue,
                  let url = mp4["url"]?.stringValue {
            fields["secure_media"] = .object(["reddit_video": .object([
                "hls_url": .string(url), "is_gif": .bool(true)
            ])])
        }
        if let items = node["gallery"]?.objectValue?["items"]?.arrayValue {
            var gallery: [RedditJSONValue] = []
            var metadata: [String: RedditJSONValue] = [:]
            for (index, item) in items.enumerated() {
                guard let object = item.objectValue,
                      let asset = object["media"]?.objectValue,
                      let source = asset["url"]?.stringValue ?? asset["xxxlarge"]?.objectValue?["url"]?.stringValue
                        ?? asset["large"]?.objectValue?["url"]?.stringValue else { continue }
                let mediaID = object["id"]?.stringValue ?? "gallery-\(index)"
                gallery.append(.object(["media_id": .string(mediaID), "caption": object["caption"] ?? .null]))
                let preview = asset["small"]?.objectValue?["url"] ?? .string(source)
                metadata[mediaID] = .object([
                    "s": .object(["u": .string(source), "x": asset["width"] ?? asset["source"]?.objectValue?["dimensions"]?.objectValue?["width"] ?? .null,
                                   "y": asset["height"] ?? asset["source"]?.objectValue?["dimensions"]?.objectValue?["height"] ?? .null]),
                    "p": .array([.object(["u": preview])])
                ])
            }
            if !gallery.isEmpty {
                fields["gallery_data"] = .object(["items": .array(gallery)])
                fields["media_metadata"] = .object(metadata)
            }
        }
    }
}

private struct RedditRawListing: Decodable, Sendable {
    let data: RedditRawListingData
}

private struct RedditRawListingData: Decodable, Sendable {
    let after: String?
    let before: String?
    let children: [RedditRawThing]
}

private struct RedditRawThing: Decodable, Sendable {
    let kind: String
    let data: [String: RedditJSONValue]
}

enum RedditJSONCodec {
    static func decodeBlockedUsers(_ data: Data) throws -> Listing<UserReference> {
        let root = try JSONDecoder().decode(RedditJSONValue.self, from: data)
        guard let listing = root.objectValue?["data"]?.objectValue,
              let children = listing["children"]?.arrayValue else { throw RedditClientError.malformedResponse }
        var seen = Set<String>()
        let users = try children.map { child -> UserReference in
            guard let object = child.objectValue else { throw RedditClientError.malformedResponse }
            let payload = object["data"]?.objectValue ?? object
            guard let username = payload["name"]?.stringValue,
                  OctonautUserDestination.route(for: username) != nil else { throw RedditClientError.malformedResponse }
            return UserReference(username: username)
        }.filter { seen.insert($0.id).inserted }
        return Listing(items: users, after: listing["after"]?.stringValue, before: listing["before"]?.stringValue)
    }

    static func decodePosts(_ data: Data) throws -> Listing<Post> {
        let envelope = try JSONDecoder().decode(RedditRawListing.self, from: data)
        let posts = envelope.data.children.compactMap { thing -> Post? in
            guard thing.kind == "t3" else { return nil }
            return mapPost(thing.data, kind: thing.kind)
        }
        return Listing(items: posts, after: envelope.data.after, before: envelope.data.before)
    }

    static func decodeCommunities(_ data: Data) throws -> Listing<Community> {
        let envelope = try JSONDecoder().decode(RedditRawListing.self, from: data)
        let communities = envelope.data.children.compactMap { thing -> Community? in
            guard thing.kind == "t5" else { return nil }
            return mapCommunity(thing.data)
        }
        return Listing(items: communities, after: envelope.data.after, before: envelope.data.before)
    }

    static func decodeUserSearch(_ data: Data) throws -> Listing<UserProfile> {
        let envelope = try JSONDecoder().decode(RedditRawListing.self, from: data)
        let users = envelope.data.children.compactMap { thing -> UserProfile? in
            switch thing.kind {
            case "t2":
                return mapUserProfile(thing.data)
            case "t5":
                return mapUserProfileSubreddit(thing.data)
            default:
                return nil
            }
        }
        return Listing(items: users, after: envelope.data.after, before: envelope.data.before)
    }

    static func decodeUserProfile(_ data: Data) throws -> UserProfile {
        let root = try JSONDecoder().decode(RedditJSONValue.self, from: data)
        let payload = root.objectValue?["data"]?.objectValue ?? root.objectValue
        guard let object = payload else {
            throw RedditClientError.malformedResponse
        }

        guard let profile = mapUserProfile(object) else { throw RedditClientError.malformedResponse }
        return profile
    }

    static func decodeUserComments(_ data: Data) throws -> Listing<UserComment> {
        let envelope = try JSONDecoder().decode(RedditRawListing.self, from: data)
        let comments = envelope.data.children.compactMap { thing -> UserComment? in
            guard thing.kind == "t1" else { return nil }
            return mapUserComment(thing.data)
        }
        return Listing(items: comments, after: envelope.data.after, before: envelope.data.before)
    }

    static func decodeThread(_ data: Data) throws -> PostThread {
        let values = try JSONDecoder().decode([RedditRawListing].self, from: data)
        guard let first = values.first else { throw RedditClientError.malformedResponse }

        let post = first.data.children.first(where: { $0.kind == "t3" }).flatMap {
            mapPost($0.data, kind: $0.kind)
        }
        guard let post else { throw RedditClientError.malformedResponse }

        let commentListing = values.dropFirst().first
        var comments: [CommentTreeNode] = []
        var moreIDs: [String] = []
        for child in commentListing?.data.children ?? [] {
            let mapped = mapCommentTree(child.data, kind: child.kind)
            comments.append(mapped.node)
            moreIDs.append(contentsOf: mapped.moreIDs)
        }
        _ = moreIDs // The nodes carry their own IDs; this keeps decoding tolerant.
        return PostThread(post: post, comments: comments)
    }

    static func decodeMoreComments(
        _ data: Data,
        parentFullname: String
    ) throws -> [CommentTreeNode] {
        let root = try JSONDecoder().decode(RedditJSONValue.self, from: data)
        guard let things = root.objectValue?["json"]?.objectValue?["data"]?.objectValue?["things"]?.arrayValue else {
            throw RedditClientError.malformedResponse
        }

        let nodes = things.compactMap { value -> CommentTreeNode? in
            guard let thing = value.objectValue,
                  let kind = thing["kind"]?.stringValue,
                  let object = thing["data"]?.objectValue else { return nil }
            return mapCommentTree(object, kind: kind).node
        }
        return assembleCommentTree(nodes, parentFullname: parentFullname)
    }

    static func decodeActionResult(_ data: Data) throws -> ActionResult {
        let root = try JSONDecoder().decode(RedditJSONValue.self, from: data)
        let errors = extractErrors(root)
        return ActionResult(succeeded: errors.isEmpty, message: errors.first)
    }

    static func mapPost(_ object: [String: RedditJSONValue], kind: String) -> Post? {
        guard let id = object["id"]?.stringValue,
              let permalinkString = object["permalink"]?.stringValue,
              let permalink = redditURL(permalinkString),
              let title = object["title"]?.stringValue else {
            return nil
        }

        let communityName = object["subreddit"]?.stringValue ?? ""
        let community = CommunityReference(
            name: communityName,
            displayName: object["subreddit_name_prefixed"]?.stringValue
                ?? (communityName.isEmpty ? "" : "r/\(communityName)"),
            iconURL: url(object["community_icon"]?.stringValue)
        )
        let decodedBody = richText(
            plainText: object["selftext"]?.stringValue,
            html: object["selftext_html"]?.stringValue
        )
        let bodyImageURL = directImageURL(in: decodedBody?.plainText)
        let bodyVideo = bodyVideoMedia(in: decodedBody?.plainText, thumbnailURL: thumbnail(object))
        let targetURL = url(object["url_overridden_by_dest"]?.stringValue)
            ?? url(object["url"]?.stringValue)
        let postHint = object["post_hint"]?.stringValue
        let media: PostMedia
        let mediaCandidates = mediaCandidates(object)
        let galleryItems = mediaCandidates.lazy.map(galleryItems).first { !$0.isEmpty } ?? []
        if !galleryItems.isEmpty {
            media = .gallery(items: galleryItems)
        } else if let video = videoMedia(object, targetURL: targetURL) {
            media = video
        } else if let animated = animatedImageMedia(object, targetURL: targetURL) {
            media = animated
        } else if let bodyVideo {
            media = bodyVideo
        } else if let image = imageMedia(object, targetURL: targetURL, postHint: postHint) {
            media = image
        } else if let bodyImageURL {
            media = .image(url: bodyImageURL, thumbnailURL: thumbnail(object), width: nil, height: nil)
        } else if let targetURL, !isSelfPost(object) {
            media = .link(url: targetURL, metadata: linkMetadata(object, targetURL: targetURL))
        } else {
            media = .none
        }
        let body: RichText?
        if let bodyImageURL,
           decodedBody?.plainText.trimmingCharacters(in: .whitespacesAndNewlines) == bodyImageURL.absoluteString {
            body = nil
        } else {
            body = decodedBody
        }

        return Post(
            id: id,
            fullname: object["name"]?.stringValue ?? IDNormalization.fullname(id, kind: kind),
            permalink: permalink,
            community: community,
            author: object["author"]?.stringValue.map(UserReference.init(username:)),
            authorFlair: mapAuthorFlair(object),
            title: title,
            body: body,
            flair: mapFlair(object),
            createdAt: date(object["created_utc"]),
            score: score(object),
            commentCount: int(object["num_comments"]) ?? 0,
            vote: voteState(object),
            isSaved: object["saved"]?.boolValue ?? false,
            isHidden: object["hidden"]?.boolValue ?? false,
            isNSFW: object["over_18"]?.boolValue ?? false,
            isSpoiler: object["spoiler"]?.boolValue ?? false,
            isLocked: object["locked"]?.boolValue ?? false,
            isArchived: object["archived"]?.boolValue ?? false,
            isSticky: object["stickied"]?.boolValue ?? false,
            media: media
        )
    }

    static func mapCommunity(_ object: [String: RedditJSONValue]) -> Community? {
        guard let name = object["display_name"]?.stringValue ?? object["name"]?.stringValue else {
            return nil
        }
        let reference = CommunityReference(
            name: name,
            displayName: object["display_name_prefixed"]?.stringValue,
            iconURL: url(object["community_icon"]?.stringValue)
                ?? url(object["icon_img"]?.stringValue)
        )
        return Community(
            reference: reference,
            title: object["title"]?.stringValue,
            description: richText(
                plainText: object["public_description"]?.stringValue
                    ?? object["description"]?.stringValue,
                html: nil
            ),
            subscribers: int(object["subscribers"]),
            isSubscribed: object["user_is_subscriber"]?.boolValue ?? false,
            isFavorite: false,
            isQuarantined: object["quarantine"]?.boolValue ?? false,
            isPrivate: object["subreddit_type"]?.stringValue == "private",
            isBanned: false,
            rules: [],
            moderators: []
        )
    }

    static func mapUserProfile(_ object: [String: RedditJSONValue]) -> UserProfile? {
        guard let username = object["name"]?.stringValue, !username.isEmpty else { return nil }
        let linkKarma = int(object["link_karma"])
        let commentKarma = int(object["comment_karma"])
        let totalKarma = int(object["total_karma"])
            ?? [linkKarma, commentKarma].compactMap { $0 }.reduce(0, +)
        let about = object["subreddit"]?.objectValue.flatMap { subreddit in
            richText(plainText: subreddit["public_description"]?.stringValue, html: nil)
        }

        return UserProfile(
            reference: UserReference(username: username),
            avatarURL: url(object["icon_img"]?.stringValue),
            createdAt: object["created_utc"].map { date($0) },
            karma: totalKarma,
            about: about,
            isBlocked: object["is_blocked"]?.boolValue ?? object["block"]?.boolValue ?? false,
            isFollowing: object["subreddit"]?.objectValue?["user_is_subscriber"]?.boolValue ?? false
        )
    }

    /// `/users/search.json` returns user-profile subreddits (`t5`) rather than
    /// account things (`t2`). Keep that transport detail out of feature code.
    private static func mapUserProfileSubreddit(_ object: [String: RedditJSONValue]) -> UserProfile? {
        let prefixedName = object["display_name_prefixed"]?.stringValue.flatMap { value in
            value.lowercased().hasPrefix("u/") ? String(value.dropFirst(2)) : nil
        }
        let pathName = object["url"]?.stringValue.flatMap { value -> String? in
            let parts = value.split(separator: "/")
            guard let userIndex = parts.firstIndex(where: { $0.lowercased() == "user" }),
                  parts.indices.contains(userIndex + 1) else { return nil }
            return String(parts[userIndex + 1])
        }
        guard let username = prefixedName ?? pathName ?? object["title"]?.stringValue,
              !username.isEmpty else { return nil }

        return UserProfile(
            reference: UserReference(username: username),
            avatarURL: url(object["icon_img"]?.stringValue)
                ?? url(object["community_icon"]?.stringValue),
            createdAt: nil,
            karma: nil,
            about: richText(plainText: object["public_description"]?.stringValue, html: nil),
            isBlocked: false,
            isFollowing: object["user_is_subscriber"]?.boolValue ?? false
        )
    }

    private static func mapCommentTree(
        _ object: [String: RedditJSONValue],
        kind: String
    ) -> (node: CommentTreeNode, moreIDs: [String]) {
        if kind == "more" {
            let id = object["id"]?.stringValue ?? UUID().uuidString
            let parent = object["parent_id"]?.stringValue ?? ""
            let childIDs = object["children"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return (
                .more(MoreCommentsNode(id: id, parentFullname: parent, childIDs: childIDs, count: int(object["count"]))),
                childIDs
            )
        }

        let id = object["id"]?.stringValue ?? UUID().uuidString
        let fullname = object["name"]?.stringValue ?? IDNormalization.fullname(id, kind: "t1")
        let parent = object["parent_id"]?.stringValue ?? ""
        let body = richText(plainText: object["body"]?.stringValue, html: object["body_html"]?.stringValue)
        if body == nil && object["author"]?.stringValue == nil {
            return (
                .deleted(DeletedCommentNode(id: id, parentFullname: parent, reason: "Comment unavailable")),
                []
            )
        }

        let children = object["replies"]?.objectValue.flatMap { repliesObject -> [CommentTreeNode]? in
            guard let data = repliesObject["data"]?.objectValue else { return nil }
            return data["children"]?.arrayValue?.compactMap { value in
                guard let childObject = value.objectValue else { return nil }
                let childKind = childObject["kind"]?.stringValue ?? "t1"
                let childData = childObject["data"]?.objectValue ?? [:]
                return mapCommentTree(childData, kind: childKind).node
            }
        } ?? []

        var moreIDs: [String] = []
        for value in object["replies"]?.objectValue?["data"]?.objectValue?["children"]?.arrayValue ?? [] {
            guard let child = value.objectValue,
                  child["kind"]?.stringValue == "more",
                  let childData = child["data"]?.objectValue else { continue }
            moreIDs.append(contentsOf: childData["children"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }

        let node = CommentNode(
            id: id,
            fullname: fullname,
            parentFullname: parent,
            author: object["author"]?.stringValue.map(UserReference.init(username:)),
            authorFlair: mapAuthorFlair(object),
            body: body,
            createdAt: date(object["created_utc"]),
            score: score(object),
            vote: voteState(object),
            isSaved: object["saved"]?.boolValue ?? false,
            isLocked: object["locked"]?.boolValue ?? false,
            isDistinguished: object["distinguished"]?.stringValue != nil,
            children: children
        )
        return (.comment(node), moreIDs)
    }

    private static func assembleCommentTree(
        _ nodes: [CommentTreeNode],
        parentFullname: String
    ) -> [CommentTreeNode] {
        let returnedCommentFullnames = Set(nodes.compactMap { node -> String? in
            if case .comment(let comment) = node { return comment.fullname }
            return nil
        })
        let childrenByParent = Dictionary(grouping: nodes, by: commentParentFullname)

        func attachChildren(
            to node: CommentTreeNode,
            ancestors: Set<String> = []
        ) -> CommentTreeNode {
            guard case .comment(var comment) = node,
                  !ancestors.contains(comment.fullname) else { return node }
            let nextAncestors = ancestors.union([comment.fullname])
            let existingIDs = Set(comment.children.map(\.id))
            let returnedChildren = (childrenByParent[comment.fullname] ?? []).filter {
                !existingIDs.contains($0.id)
            }
            comment.children = (comment.children + returnedChildren).map {
                attachChildren(to: $0, ancestors: nextAncestors)
            }
            return .comment(comment)
        }

        var roots = childrenByParent[parentFullname] ?? []
        if roots.isEmpty {
            roots = nodes.filter { !returnedCommentFullnames.contains(commentParentFullname($0)) }
        }
        return roots.map { attachChildren(to: $0) }
    }

    private static func commentParentFullname(_ node: CommentTreeNode) -> String {
        switch node {
        case .comment(let comment): return comment.parentFullname
        case .more(let more): return more.parentFullname
        case .deleted(let deleted): return deleted.parentFullname
        }
    }

    static func mapUserComment(_ object: [String: RedditJSONValue]) -> UserComment? {
        guard let id = object["id"]?.stringValue else { return nil }
        let communityName = object["subreddit"]?.stringValue
        let community = communityName.map {
            CommunityReference(
                name: $0,
                displayName: object["subreddit_name_prefixed"]?.stringValue
            )
        }
        return UserComment(
            id: id,
            fullname: object["name"]?.stringValue,
            parentFullname: object["parent_id"]?.stringValue ?? "",
            author: object["author"]?.stringValue.map(UserReference.init(username:)),
            body: richText(plainText: object["body"]?.stringValue, html: object["body_html"]?.stringValue),
            createdAt: date(object["created_utc"]),
            score: score(object),
            vote: voteState(object),
            isSaved: object["saved"]?.boolValue ?? false,
            isLocked: object["locked"]?.boolValue ?? false,
            isDistinguished: object["distinguished"]?.stringValue != nil,
            postTitle: object["link_title"]?.stringValue,
            postPermalink: redditURL(object["link_permalink"]?.stringValue ?? ""),
            community: community
        )
    }

    private static func mapFlair(_ object: [String: RedditJSONValue]) -> Flair? {
        guard let text = object["link_flair_text"]?.stringValue, !text.isEmpty else { return nil }
        return Flair(
            id: object["link_flair_template_id"]?.stringValue ?? text,
            text: text,
            backgroundColor: object["link_flair_background_color"]?.stringValue,
            textColor: object["link_flair_text_color"]?.stringValue
        )
    }

    private static func mapAuthorFlair(_ object: [String: RedditJSONValue]) -> Flair? {
        let richSegments = object["author_flair_richtext"]?.arrayValue ?? []
        let richText = richSegments
            .compactMap { value in
                let segment = value.objectValue
                guard segment?["e"]?.stringValue == "text" else { return nil }
                return segment?["t"]?.stringValue
            }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let emojiURLs = richSegments.compactMap { value -> URL? in
            let segment = value.objectValue
            guard segment?["e"]?.stringValue == "emoji" else { return nil }
            return url(segment?["u"]?.stringValue)
        }
        let plainText = object["author_flair_text"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let text = richSegments.isEmpty ? (plainText ?? "") : richText
        guard !text.isEmpty || !emojiURLs.isEmpty else { return nil }
        let identifier = object["author_flair_template_id"]?.stringValue
            ?? plainText.flatMap { $0.isEmpty ? nil : $0 }
            ?? text
        return Flair(
            id: identifier,
            text: stripHTML(text),
            backgroundColor: object["author_flair_background_color"]?.stringValue,
            textColor: object["author_flair_text_color"]?.stringValue,
            emojiURLs: emojiURLs
        )
    }

    /// Every request sends `raw_json=1`, so plain fields are already unescaped
    /// markdown. Only the HTML fallback is stripped; stripping markdown would
    /// delete text such as `a < b > c` and turn a literal `\n` into a newline.
    private static func richText(plainText: String?, html: String?) -> RichText? {
        if let plainText, !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Keep leading indentation so a body that opens with a code block survives.
            var end = plainText.endIndex
            while end > plainText.startIndex,
                  plainText[plainText.index(before: end)].isWhitespace {
                end = plainText.index(before: end)
            }
            return RichText(plainText: String(plainText[..<end]))
        }
        guard let html else { return nil }
        let stripped = stripHTML(html)
        return stripped.isEmpty ? nil : RichText(plainText: stripped)
    }

    private static let htmlTagRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: "<[^>]+>", options: [])
        } catch {
            fatalError("Invalid htmlTagRegex: \(error)")
        }
    }()

    private static let urlExtractionRegex: NSRegularExpression = {
        do {
            return try NSRegularExpression(pattern: #"https?://[^\s<>]+"#)
        } catch {
            fatalError("Invalid urlExtractionRegex: \(error)")
        }
    }()

    private static func stripHTML(_ string: String) -> String {
        // Remove tags before decoding entities, so escaped text such as
        // `&lt;tag&gt;` is kept rather than mistaken for markup.
        let value = htmlTagRegex.stringByReplacingMatches(
            in: string,
            range: NSRange(string.startIndex..., in: string),
            withTemplate: ""
        )
        return value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isSelfPost(_ object: [String: RedditJSONValue]) -> Bool {
        if let value = object["is_self"]?.boolValue { return value }
        return object["selftext"]?.stringValue != nil
    }

    private static func thumbnail(_ object: [String: RedditJSONValue]) -> URL? {
        url(object["thumbnail"]?.stringValue) ?? previewImageURL(object) ?? oEmbedThumbnailURL(object)
    }

    private static func mediaCandidates(
        _ object: [String: RedditJSONValue]
    ) -> [[String: RedditJSONValue]] {
        let crossposts = object["crosspost_parent_list"]?.arrayValue?.compactMap(\.objectValue) ?? []
        return [object] + crossposts
    }

    /// Image posts do not reliably include `post_hint`. Direct image URLs are
    /// authoritative, while a Reddit wrapper URL may keep the actual image in
    /// `preview` or the crosspost parent payload.
    private static func imageMedia(
        _ object: [String: RedditJSONValue],
        targetURL: URL?,
        postHint: String?
    ) -> PostMedia? {
        let candidates = mediaCandidates(object)

        // Prefer an authoritative source URL from either the wrapper or its
        // crosspost parent before falling back to a generated preview image.
        for (index, candidate) in candidates.enumerated() {
            let candidateURL = url(candidate["url_overridden_by_dest"]?.stringValue)
                ?? url(candidate["url"]?.stringValue)
                ?? (index == 0 ? targetURL : nil)

            if let candidateURL, isDirectImageURL(candidateURL) {
                let dimensions = previewImageDimensions(candidate)
                return .image(
                    url: candidateURL,
                    thumbnailURL: thumbnail(candidate),
                    width: dimensions?.width,
                    height: dimensions?.height
                )
            }
        }

        for (index, candidate) in candidates.enumerated() {
            let candidateURL = url(candidate["url_overridden_by_dest"]?.stringValue)
                ?? url(candidate["url"]?.stringValue)
                ?? (index == 0 ? targetURL : nil)
            let candidateHint = candidate["post_hint"]?.stringValue ?? (index == 0 ? postHint : nil)

            if let previewURL = previewImageURL(candidate),
               candidateHint == "image" || candidateURL.map(isRedditPageURL) == true {
                let dimensions = previewImageDimensions(candidate)
                return .image(
                    url: previewURL,
                    thumbnailURL: thumbnail(candidate),
                    width: dimensions?.width,
                    height: dimensions?.height
                )
            }
        }
        return nil
    }

    private static func linkMetadata(
        _ object: [String: RedditJSONValue],
        targetURL: URL
    ) -> LinkMetadata? {
        let candidates = mediaCandidates(object)
        let embeddedMetadata = candidates.lazy.compactMap { oEmbed($0) }.first
        let imageURL = candidates.lazy.compactMap {
            previewImageURL($0) ?? oEmbedThumbnailURL($0)
        }.first
        let metadata = LinkMetadata(
            title: embeddedMetadata?["title"]?.stringValue,
            description: nil,
            siteName: embeddedMetadata?["provider_name"]?.stringValue ?? targetURL.host,
            imageURL: imageURL,
            canonicalURL: targetURL
        )
        return metadata.title == nil && metadata.siteName == nil && metadata.imageURL == nil ? nil : metadata
    }

    /// Native Reddit video posts expose a playable fallback under `secure_media`
    /// or `media`. Crossposts keep the same payload on their parent post.
    private static func videoMedia(
        _ object: [String: RedditJSONValue],
        targetURL: URL?
    ) -> PostMedia? {
        for candidate in mediaCandidates(object) {
            let redditVideo = candidate["secure_media"]?.objectValue?["reddit_video"]?.objectValue
                ?? candidate["media"]?.objectValue?["reddit_video"]?.objectValue
                ?? candidate["preview"]?.objectValue?["reddit_video_preview"]?.objectValue
            guard let redditVideo else { continue }

            let fallbackURL = url(redditVideo["fallback_url"]?.stringValue)
            let hlsURL = url(redditVideo["hls_url"]?.stringValue)
            // HLS first. `fallback_url` is DASH video-only, so preferring it
            // forces the audio to be guessed at `DASH_AUDIO_128.mp4`, the
            // manifest to be fetched when that misses, and the two tracks to
            // be composed -- a chain of awaits a feed row sits behind on a
            // spinner. The HLS playlist carries audio in-stream and plays
            // without any of it. DASH stays as the fallback for the posts
            // Reddit publishes without a playlist.
            guard let videoURL = hlsURL ?? fallbackURL else { continue }

            let isGIF = redditVideo["is_gif"]?.boolValue ?? false
            let hasAudio = redditVideo["has_audio"]?.boolValue ?? false
            // Only the DASH fallback needs a separate audio URL.
            let audioURL = videoURL == fallbackURL && hasAudio && !isGIF
                ? fallbackURL.flatMap(redditAudioURL(for:))
                : nil
            return .video(
                url: videoURL,
                audioURL: audioURL,
                thumbnailURL: thumbnail(candidate) ?? thumbnail(object),
                isGIF: isGIF,
                width: int(redditVideo["width"]),
                height: int(redditVideo["height"])
            )
        }

        guard let targetURL else { return nil }
        if targetURL.host?.lowercased() == "v.redd.it" {
            return .video(
                url: redditHLSURL(for: targetURL),
                audioURL: nil,
                thumbnailURL: thumbnail(object),
                isGIF: false,
                width: nil,
                height: nil
            )
        }
        guard isDirectVideoURL(targetURL) else { return nil }
        return .video(
            url: targetURL,
            audioURL: nil,
            thumbnailURL: thumbnail(object),
            isGIF: false,
            width: nil,
            height: nil
        )
    }

    /// Reddit keeps animated posts at a `.gif` URL but also generates an H.264
    /// copy under `preview.images[].variants.mp4`. `UIImage` decodes only a
    /// GIF's first frame, so the mp4 variant is what actually animates. Resolve
    /// these to looping video and let the existing video path play them.
    private static func animatedImageMedia(
        _ object: [String: RedditJSONValue],
        targetURL: URL?
    ) -> PostMedia? {
        for (index, candidate) in mediaCandidates(object).enumerated() {
            let candidateURL = url(candidate["url_overridden_by_dest"]?.stringValue)
                ?? url(candidate["url"]?.stringValue)
                ?? (index == 0 ? targetURL : nil)
            guard let candidateURL, isAnimatedImageURL(candidateURL) else { continue }

            // A post with no mp4 variant falls through to the image path, which
            // still renders the first frame rather than nothing.
            guard let playableURL = animatedVariantURL(candidate)
                ?? animatedVariantURL(object)
                ?? animatedURLBySubstitution(candidateURL) else { continue }

            return .video(
                url: playableURL,
                audioURL: nil,
                thumbnailURL: thumbnail(candidate) ?? thumbnail(object),
                isGIF: true,
                width: nil,
                height: nil
            )
        }
        return nil
    }

    private static func isAnimatedImageURL(_ url: URL) -> Bool {
        ["gif", "gifv"].contains(url.pathExtension.lowercased())
    }

    private static func animatedVariantURL(_ object: [String: RedditJSONValue]) -> URL? {
        let variants = object["preview"]?.objectValue?["images"]?.arrayValue?.first?
            .objectValue?["variants"]?.objectValue
        return url(variants?["mp4"]?.objectValue?["source"]?.objectValue?["url"]?.stringValue)
    }

    /// Imgur serves an mp4 for every animated upload at the same path.
    private static func animatedURLBySubstitution(_ url: URL) -> URL? {
        guard let host = url.host?.lowercased(),
              host == "i.imgur.com" || host == "imgur.com" else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = (url.path as NSString).deletingPathExtension + ".mp4"
        return components?.url
    }

    private static func previewImageURL(_ object: [String: RedditJSONValue]) -> URL? {
        object["preview"]?.objectValue?["images"]?.arrayValue?.first?
            .objectValue?["source"]?.objectValue?["url"]?.stringValue
            .flatMap(url)
    }

    private static func previewImageDimensions(
        _ object: [String: RedditJSONValue]
    ) -> (width: Int?, height: Int?)? {
        guard let source = object["preview"]?.objectValue?["images"]?.arrayValue?.first?
            .objectValue?["source"]?.objectValue else {
            return nil
        }
        return (int(source["width"]), int(source["height"]))
    }

    private static func oEmbed(
        _ object: [String: RedditJSONValue]
    ) -> [String: RedditJSONValue]? {
        object["secure_media"]?.objectValue?["oembed"]?.objectValue
            ?? object["media"]?.objectValue?["oembed"]?.objectValue
    }

    private static func oEmbedThumbnailURL(_ object: [String: RedditJSONValue]) -> URL? {
        url(oEmbed(object)?["thumbnail_url"]?.stringValue)
    }

    private static func isRedditPageURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "redd.it" || host == "reddit.com" || host.hasSuffix(".reddit.com")
    }

    private static func redditAudioURL(for fallbackURL: URL) -> URL? {
        guard fallbackURL.host?.lowercased() == "v.redd.it",
              fallbackURL.lastPathComponent.lowercased().hasSuffix(".mp4") else {
            return nil
        }
        var components = URLComponents(url: fallbackURL, resolvingAgainstBaseURL: false)
        let parentPath = (components?.path as NSString?)?.deletingLastPathComponent ?? ""
        components?.path = "\(parentPath)/DASH_AUDIO_128.mp4"
        return components?.url
    }

    private static func redditHLSURL(for url: URL) -> URL {
        guard url.pathExtension.isEmpty else { return url }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.path = url.path.appending("/HLSPlaylist.m3u8")
        return components?.url ?? url
    }

    private static func directImageURL(in text: String?) -> URL? {
        URLs(in: text).first(where: isDirectImageURL)
    }

    private static func bodyVideoMedia(in text: String?, thumbnailURL: URL?) -> PostMedia? {
        for candidate in URLs(in: text) {
            if isDirectVideoURL(candidate) {
                return .video(
                    url: candidate,
                    audioURL: nil,
                    thumbnailURL: thumbnailURL,
                    isGIF: false,
                    width: nil,
                    height: nil
                )
            }
            if EmbeddedVideoURL.embedURL(for: candidate) != nil {
                return .link(url: candidate, metadata: nil)
            }
        }
        return nil
    }

    private static func URLs(in text: String?) -> [URL] {
        guard let text, !text.isEmpty else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return urlExtractionRegex.matches(in: text, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            let candidate = String(text[matchRange])
                .trimmingCharacters(in: CharacterSet(charactersIn: "])}>,."))
            return url(candidate)
        }
    }

    private static func isDirectImageURL(_ url: URL) -> Bool {
        let imageHosts: Set<String> = ["i.redd.it", "preview.redd.it", "external-preview.redd.it"]
        if let host = url.host?.lowercased(), imageHosts.contains(host) { return true }
        return ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif"]
            .contains(url.pathExtension.lowercased())
    }

    private static func isDirectVideoURL(_ url: URL) -> Bool {
        ["mp4", "m3u8", "mov", "m4v"].contains(url.pathExtension.lowercased())
    }

    /// Reddit gallery post URLs point back to reddit.com. The displayable image
    /// URLs live in `media_metadata`, while `gallery_data` supplies their order.
    private static func galleryItems(_ object: [String: RedditJSONValue]) -> [GalleryItem] {
        guard let items = object["gallery_data"]?.objectValue?["items"]?.arrayValue,
              let metadata = object["media_metadata"]?.objectValue else {
            return []
        }

        return items.compactMap { value in
            guard let galleryItem = value.objectValue,
                  let mediaID = galleryItem["media_id"]?.stringValue,
                  let media = metadata[mediaID]?.objectValue else {
                return nil
            }

            let source = media["s"]?.objectValue
            let previews = media["p"]?.arrayValue?.compactMap(\.objectValue) ?? []
            let previewURL = previews.first.flatMap { url($0["u"]?.stringValue) }
            let largestPreview = previews.last
            guard let sourceURL = url(source?["u"]?.stringValue)
                ?? largestPreview.flatMap({ url($0["u"]?.stringValue) }) else {
                return nil
            }

            return GalleryItem(
                id: mediaID,
                url: sourceURL,
                thumbnailURL: previewURL,
                width: int(source?["x"]) ?? int(largestPreview?["x"]),
                height: int(source?["y"]) ?? int(largestPreview?["y"]),
                caption: galleryItem["caption"]?.stringValue
            )
        }
    }

    private static func redditURL(_ string: String) -> URL? {
        if let url = URL(string: string), url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" {
            return url
        }
        if string.hasPrefix("/") { return URL(string: "https://www.reddit.com\(string)") }
        return nil
    }

    private static func url(_ value: String?) -> URL? {
        guard let value else { return nil }
        let normalized = value.replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased()) else {
            return nil
        }
        return url
    }

    private static func int(_ value: RedditJSONValue?) -> Int? {
        guard let value else { return nil }
        if let number = value.numberValue { return Int(number) }
        if let string = value.stringValue { return Int(string) }
        return nil
    }

    private static func score(_ object: [String: RedditJSONValue]) -> Int? {
        guard object["score_hidden"]?.boolValue != true else { return nil }
        return int(object["score"])
    }

    private static func date(_ value: RedditJSONValue?) -> Date {
        guard let seconds = value?.numberValue ?? value?.stringValue.flatMap(Double.init) else { return .now }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func voteState(_ object: [String: RedditJSONValue]) -> VoteState {
        switch object["likes"] {
        case .bool(true): return .upvoted
        case .bool(false): return .downvoted
        default: return .unknown
        }
    }

    private static func extractErrors(_ root: RedditJSONValue) -> [String] {
        guard let object = root.objectValue,
              let json = object["json"]?.objectValue,
              let errors = json["errors"]?.arrayValue else { return [] }
        return errors.compactMap { error in
            guard let parts = error.arrayValue else { return error.stringValue }
            return parts.compactMap(\.stringValue).joined(separator: ": ")
        }.filter { !$0.isEmpty }
    }
}
