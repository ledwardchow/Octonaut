import Foundation

extension RedditGraphQLCodec {
    static func userProfile(data: Data) throws -> UserProfile {
        let root = try payload(data)
        guard let node = root["redditorInfoByName"]?.objectValue else {
            throw RedditClientError.notFound
        }
        guard node["__typename"]?.stringValue == "Redditor",
              let name = node["name"]?.stringValue, !name.isEmpty else {
            throw RedditClientError.accessDenied
        }
        let profile = node["profile"]?.objectValue ?? [:]
        let karma = node["karma"]?.objectValue ?? [:]
        let fields: [String: RedditJSONValue] = [
            "name": .string(name),
            "total_karma": karma["total"] ?? .number(
                (karma["fromPosts"]?.numberValue ?? 0) + (karma["fromComments"]?.numberValue ?? 0)
            ),
            "created_utc": timestamp(profile["createdAt"]) ?? .null,
            "icon_img": profile["icon"] ?? profile["avatar"] ?? .null,
            "subreddit": .object([
                "public_description": profile["publicDescriptionText"] ?? .null,
                "user_is_subscriber": profile["isSubscribed"] ?? .bool(false)
            ]),
            "is_blocked": node["isBlocked"] ?? .bool(false)
        ]
        guard let mapped = RedditJSONCodec.mapUserProfile(fields) else {
            throw RedditClientError.malformedResponse
        }
        return mapped
    }

    static func profilePostIDs(data: Data, section: UserSection) throws -> (ids: [String], after: String?) {
        let root = try payload(data)
        let elements: [String: RedditJSONValue]?
        switch section {
        case .overview, .submitted:
            elements = root["profileFeed"]?.objectValue?["elements"]?.objectValue
        case .saved:
            elements = root["savedV3"]?.objectValue?["elements"]?.objectValue
        default:
            throw RedditClientError.malformedResponse
        }
        guard let elements, elements["edges"]?.arrayValue != nil else {
            throw RedditClientError.malformedResponse
        }
        var seen = Set<String>()
        let ids = nodes(elements).compactMap { node -> String? in
            guard node["adPayload"]?.objectValue == nil,
                  let id = node["groupId"]?.stringValue ?? node["id"]?.stringValue,
                  id.hasPrefix("t3_"), seen.insert(id).inserted else { return nil }
            return id
        }
        return (ids, try after(elements))
    }

    static func identityPosts(data: Data, field: String) throws -> Listing<Post> {
        let root = try payload(data)
        guard let list = root["identity"]?.objectValue?[field]?.objectValue,
              list["edges"]?.arrayValue != nil else { throw RedditClientError.malformedResponse }
        return Listing(items: nodes(list).compactMap(post), after: try after(list))
    }

    struct CommentEdge: Sendable {
        let id: String
        let postTitle: String?
    }

    static func commentEdges(data: Data, section: UserSection) throws -> (edges: [CommentEdge], after: String?) {
        let root = try payload(data)
        let list: [String: RedditJSONValue]?
        switch section {
        case .overview, .submitted, .comments:
            guard let user = root["redditorInfoByName"]?.objectValue else { throw RedditClientError.notFound }
            list = user["comments"]?.objectValue
        case .saved:
            list = root["identity"]?.objectValue?["savedComments"]?.objectValue
        default:
            throw RedditClientError.malformedResponse
        }
        guard let list, list["edges"]?.arrayValue != nil else { throw RedditClientError.malformedResponse }
        let edges = nodes(list).compactMap { node -> CommentEdge? in
            guard node["__typename"]?.stringValue == "Comment",
                  let id = node["id"]?.stringValue, id.hasPrefix("t1_") else { return nil }
            return CommentEdge(id: id, postTitle: node["postInfo"]?.objectValue?["title"]?.stringValue)
        }
        return (edges, try after(list))
    }

    static func hydratedUserComments(data: Data, edges: [CommentEdge]) throws -> [UserComment] {
        let root = try payload(data)
        guard let values = root["commentsByIds"]?.arrayValue else { throw RedditClientError.malformedResponse }
        var byID: [String: [String: RedditJSONValue]] = [:]
        for value in values {
            guard let node = value.objectValue, node["__typename"]?.stringValue == "Comment",
                  let id = node["id"]?.stringValue else { continue }
            byID[id] = node
        }
        return edges.compactMap { edge in
            guard let node = byID[edge.id] else { return nil }
            let permalink = node["permalink"]?.stringValue ?? ""
            let pathParts = URL(string: permalink)?.pathComponents.filter { $0 != "/" } ?? []
            let fallbackCommunity: String
            if pathParts.count >= 2, pathParts[0] == "r" {
                fallbackCommunity = pathParts[1]
            } else if pathParts.count >= 2, pathParts[0] == "user" {
                fallbackCommunity = "u_\(pathParts[1])"
            } else {
                fallbackCommunity = ""
            }
            let community = node["subreddit"]?.objectValue?["name"]?.stringValue
                ?? fallbackCommunity
            let postPermalink: String
            if let commentsIndex = pathParts.firstIndex(of: "comments"),
               pathParts.count > commentsIndex + 3,
               let url = URL(string: permalink) {
                postPermalink = url.deletingLastPathComponent().absoluteString
            } else {
                postPermalink = permalink
            }
            let content = node["content"]?.objectValue ?? [:]
            let body = RedditGraphQLRichText.decode(content, thingID: edge.id)?.plainText ?? ""
            var fields: [String: RedditJSONValue] = [
                "id": .string(String(edge.id.dropFirst(3))),
                "name": .string(edge.id),
                "parent_id": node["parentId"] ?? .string(""),
                "author": node["authorInfo"]?.objectValue?["name"] ?? .string("[deleted]"),
                "body": .string(body),
                "created_utc": timestamp(node["createdAt"]) ?? .null,
                "score": node["score"] ?? .null,
                "score_hidden": node["isScoreHidden"] ?? .bool(false),
                "saved": node["isSaved"] ?? .bool(false),
                "locked": node["isLocked"] ?? .bool(false),
                "distinguished": node["distinguishedAs"]?.stringValue == "MODERATOR" ? .string("moderator") : .null,
                "subreddit": .string(community),
                "link_title": .string(edge.postTitle ?? ""),
                "link_permalink": .string(postPermalink)
            ]
            if let html = content["html"] { fields["body_html"] = html }
            switch node["voteState"]?.stringValue {
            case "UP": fields["likes"] = .bool(true)
            case "DOWN": fields["likes"] = .bool(false)
            default: break
            }
            return RedditJSONCodec.mapUserComment(fields)
        }
    }

    struct SubscriptionsPage: Sendable {
        let communities: [Community]
        let subscribedAfter: String?
        let followedAfter: String?
    }

    static func subscriptions(data: Data, fetchSubscribed: Bool, fetchFollowed: Bool) throws -> SubscriptionsPage {
        let root = try payload(data)
        guard let identity = root["identity"]?.objectValue else { throw RedditClientError.malformedResponse }
        let subscribed = identity["subscribedSubredditInfos"]?.objectValue
        let followed = identity["followedRedditorsInfo"]?.objectValue
        guard (!fetchSubscribed || subscribed?["edges"]?.arrayValue != nil),
              (!fetchFollowed || followed?["edges"]?.arrayValue != nil) else {
            throw RedditClientError.malformedResponse
        }
        let communities = nodes(subscribed ?? [:]).compactMap { node -> Community? in
            guard ["Subreddit", "UnavailableSubreddit"].contains(node["__typename"]?.stringValue ?? ""),
                  let name = node["name"]?.stringValue, !name.isEmpty else { return nil }
            return RedditJSONCodec.mapCommunity([
                "display_name": .string(name),
                "title": node["title"] ?? .null,
                "public_description": node["publicDescriptionText"] ?? .null,
                "community_icon": node["styles"]?.objectValue?["icon"]
                    ?? node["styles"]?.objectValue?["legacyIcon"]?.objectValue?["url"] ?? .null,
                "subscribers": node["subscribersCount"] ?? .null,
                "user_is_subscriber": .bool(true),
                "quarantine": node["isQuarantined"] ?? .bool(node["forbiddenReason"]?.stringValue == "QUARANTINED"),
                "subreddit_type": .string(node["forbiddenReason"]?.stringValue == "PRIVATE" ? "private" : (node["type"]?.stringValue?.lowercased() ?? ""))
            ])
        }
        let people = nodes(followed ?? [:]).compactMap { node -> Community? in
            guard let profile = node["profile"]?.objectValue,
                  let rawName = profile["redditorInfo"]?.objectValue?["prefixedName"]?.stringValue
                    ?? profile["name"]?.stringValue else { return nil }
            let name = rawName.replacingOccurrences(of: "^u[/_]", with: "", options: .regularExpression)
            guard !name.isEmpty else { return nil }
            return RedditJSONCodec.mapCommunity([
                "display_name": .string("u_\(name)"),
                "title": .string("u/\(name)"),
                "community_icon": profile["styles"]?.objectValue?["icon"] ?? .null,
                "user_is_subscriber": .bool(true)
            ])
        }
        return SubscriptionsPage(communities: communities + people,
                                 subscribedAfter: try subscribed.flatMap(after),
                                 followedAfter: try followed.flatMap(after))
    }
}
