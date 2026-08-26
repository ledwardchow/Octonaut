import Foundation

/// A deliberately tolerant JSON value. Reddit occasionally adds fields or
/// returns null where a field was present before, so transport decoding does
/// not use a rigid Codable struct for every Reddit object.
private enum RedditJSONValue: Decodable, Sendable {
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

    static func decodeUserProfile(_ data: Data) throws -> UserProfile {
        let root = try JSONDecoder().decode(RedditJSONValue.self, from: data)
        let payload = root.objectValue?["data"]?.objectValue ?? root.objectValue
        guard let object = payload,
              let username = object["name"]?.stringValue,
              !username.isEmpty else {
            throw RedditClientError.malformedResponse
        }

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
            isBlocked: object["block"]?.boolValue ?? false,
            isFollowing: object["is_friend"]?.boolValue ?? false
        )
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

    static func decodeActionResult(_ data: Data) throws -> ActionResult {
        let root = try JSONDecoder().decode(RedditJSONValue.self, from: data)
        let errors = extractErrors(root)
        return ActionResult(succeeded: errors.isEmpty, message: errors.first)
    }

    private static func mapPost(_ object: [String: RedditJSONValue], kind: String) -> Post? {
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

    private static func mapCommunity(_ object: [String: RedditJSONValue]) -> Community? {
        guard let name = object["display_name"]?.stringValue ?? object["name"]?.stringValue else {
            return nil
        }
        let reference = CommunityReference(
            name: name,
            displayName: object["display_name_prefixed"]?.stringValue,
            iconURL: url(object["icon_img"]?.stringValue)
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

    private static func mapUserComment(_ object: [String: RedditJSONValue]) -> UserComment? {
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
        let richText = object["author_flair_richtext"]?.arrayValue?
            .compactMap { value in
                let segment = value.objectValue
                return segment?["t"]?.stringValue ?? segment?["a"]?.stringValue
            }
            .joined()
        let plainText = object["author_flair_text"]?.stringValue
        guard let text = plainText.flatMap({ $0.isEmpty ? nil : $0 }) ?? richText,
              !text.isEmpty else { return nil }
        return Flair(
            id: object["author_flair_template_id"]?.stringValue ?? text,
            text: stripHTML(text),
            backgroundColor: object["author_flair_background_color"]?.stringValue,
            textColor: object["author_flair_text_color"]?.stringValue
        )
    }

    private static func richText(plainText: String?, html: String?) -> RichText? {
        let source = plainText ?? html.map(stripHTML)
        guard let source, !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return RichText(plainText: stripHTML(source))
    }

    private static func stripHTML(_ string: String) -> String {
        var value = string
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
        if let expression = try? NSRegularExpression(pattern: "<[^>]+>", options: []) {
            value = expression.stringByReplacingMatches(
                in: value,
                range: NSRange(value.startIndex..., in: value),
                withTemplate: ""
            )
        }
        return value
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
                return .image(
                    url: candidateURL,
                    thumbnailURL: thumbnail(candidate),
                    width: nil,
                    height: nil
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
            guard let videoURL = fallbackURL ?? hlsURL else { continue }

            let isGIF = redditVideo["is_gif"]?.boolValue ?? false
            let hasAudio = redditVideo["has_audio"]?.boolValue ?? false
            let audioURL = hasAudio && !isGIF
                ? fallbackURL.flatMap(redditAudioURL(for:))
                : nil
            return .video(
                url: videoURL,
                audioURL: audioURL,
                thumbnailURL: thumbnail(candidate) ?? thumbnail(object),
                isGIF: isGIF
            )
        }

        guard let targetURL else { return nil }
        if targetURL.host?.lowercased() == "v.redd.it" {
            return .video(
                url: redditHLSURL(for: targetURL),
                audioURL: nil,
                thumbnailURL: thumbnail(object),
                isGIF: false
            )
        }
        guard isDirectVideoURL(targetURL) else { return nil }
        return .video(
            url: targetURL,
            audioURL: nil,
            thumbnailURL: thumbnail(object),
            isGIF: false
        )
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
                    isGIF: false
                )
            }
            if EmbeddedVideoURL.embedURL(for: candidate) != nil {
                return .link(url: candidate, metadata: nil)
            }
        }
        return nil
    }

    private static func URLs(in text: String?) -> [URL] {
        guard let text, !text.isEmpty,
              let expression = try? NSRegularExpression(pattern: #"https?://[^\s<>]+"#) else {
            return []
        }

        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap { match in
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
