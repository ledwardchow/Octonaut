import Foundation

struct RedditReportRule: Decodable, Hashable, Identifiable, Sendable {
    let shortName: String
    let violationReason: String
    let kind: String
    var id: String { violationReason }

    enum CodingKeys: String, CodingKey {
        case shortName = "short_name"
        case violationReason = "violation_reason"
        case kind
    }

    func applies(to fullname: String) -> Bool {
        kind == "all" || (kind == "link" && fullname.hasPrefix("t3_"))
            || (kind == "comment" && fullname.hasPrefix("t1_"))
    }

    static func validCommunity(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95
        }
    }

    static func decode(_ data: Data) throws -> [Self] {
        struct Envelope: Decodable { let rules: [RedditReportRule] }
        let rules = try JSONDecoder().decode(Envelope.self, from: data).rules
        var seen = Set<String>()
        return rules.filter {
            !$0.violationReason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && $0.violationReason.count <= 100 && seen.insert($0.id).inserted
        }
    }

    static func decodeSubmission(_ data: Data) throws -> ActionResult {
        // Require the requested JSON envelope before acknowledging a report.
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let json = root["json"] as? [String: Any],
              json["errors"] is [[Any]] else { throw RedditClientError.malformedResponse }
        return try RedditJSONCodec.decodeActionResult(data)
    }
}

struct RedditReportTarget: Identifiable, Sendable {
    let fullname: String
    let community: String
    let permalink: URL
    var id: String { fullname }

    init(post: PostCardModel) {
        fullname = post.fullname
        community = post.community
        permalink = post.shareURL
    }

    init(commentID: String, post: PostCardModel) {
        fullname = IDNormalization.fullname(commentID, kind: "t1")
        community = post.community
        var components = URLComponents(url: post.shareURL, resolvingAgainstBaseURL: false)!
        let postPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + postPath + "/" + String(fullname.dropFirst(3)) + "/"
        components.query = nil
        components.fragment = nil
        permalink = components.url ?? post.shareURL
    }

    static func validFullname(_ value: String) -> Bool {
        (value.hasPrefix("t1_") || value.hasPrefix("t3_")) && value.count > 3
            && value.dropFirst(3).utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) }
    }

    static func isRedditURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.user == nil && url.password == nil
            && (url.port == nil || url.port == 443)
            && ["www.reddit.com", "reddit.com", "old.reddit.com", "new.reddit.com", "m.reddit.com"].contains(url.host?.lowercased() ?? "")
    }

    var browserURL: URL? {
        guard Self.isRedditURL(permalink), Self.validFullname(fullname) else { return nil }
        guard var components = URLComponents(url: permalink, resolvingAgainstBaseURL: false),
              components.path.contains("/comments/") else { return nil }
        components.host = "www.reddit.com"
        components.queryItems = fullname.hasPrefix("t1_") ? [URLQueryItem(name: "context", value: "3")] : nil
        components.fragment = nil
        return components.url
    }
}
