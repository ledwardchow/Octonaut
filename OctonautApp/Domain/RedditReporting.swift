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

struct RedditReportOptions: Sendable {
    var rules: [RedditReportRule]
    var siteReasons: [RedditSiteReportReason]
}

/// One selectable Reddit-wide reason, flattened from `site_rules_flow` in a
/// community's `about/rules.json`. Nested steps become a single label such as
/// "This is abusive or harassing › It's targeted harassment › At me".
struct RedditSiteReportReason: Hashable, Identifiable, Sendable {
    enum Handling: Hashable, Sendable {
        /// Sent with `/api/report`.
        case report
        /// Reddit only accepts these through its own complaint form.
        case complaint(URL)
        /// Needs details Octonaut does not collect, so it goes to Reddit in the browser.
        case browser
    }

    let label: String
    let reasonText: String
    let handling: Handling
    var id: String { label }

    /// Never throws: a response without `site_rules_flow` simply has no site reasons.
    static func decode(_ data: Data) -> [Self] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flow = root["site_rules_flow"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return flatten(flow, path: []).filter { seen.insert($0.id).inserted }
    }

    private static func flatten(_ steps: [[String: Any]], path: [String]) -> [Self] {
        steps.flatMap { step -> [Self] in
            guard let shown = (step["reasonTextToShow"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !shown.isEmpty else { return [] }
            let labelPath = path + [shown]
            if let next = step["nextStepReasons"] as? [[String: Any]], !next.isEmpty {
                return flatten(next, path: labelPath)
            }
            guard let reason = (step["reasonText"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reason.isEmpty, reason.count <= 100 else { return [] }
            let handling: Handling
            if step["fileComplaint"] as? Bool == true {
                guard let raw = step["complaintUrl"] as? String,
                      let url = URL(string: raw.replacingOccurrences(of: "&amp;", with: "&")),
                      RedditReportTarget.isRedditURL(url) else { return [] }
                handling = .complaint(url)
            } else if step["canSpecifyUsernames"] as? Bool == true || step["requestCrisisSupport"] as? Bool == true {
                handling = .browser
            } else {
                handling = .report
            }
            return [Self(label: labelPath.joined(separator: " › "), reasonText: reason, handling: handling)]
        }
    }

    /// Reddit's complaint links carry a `%(thing)s` placeholder for the reported item.
    static func complaintURL(_ template: URL, fullname: String) -> URL? {
        let filled = template.absoluteString
            .replacingOccurrences(of: "%25%28thing%29s", with: fullname)
            .replacingOccurrences(of: "%(thing)s", with: fullname)
        guard let url = URL(string: filled), RedditReportTarget.isRedditURL(url) else { return nil }
        return url
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
