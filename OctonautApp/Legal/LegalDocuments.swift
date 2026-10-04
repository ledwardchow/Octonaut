import Foundation

enum LegalDocuments {
    // Bump this when the policy or the terms presented before login change.
    static let consentVersion = "1"
    static let acceptedVersionKey = "legal.acceptedConsentVersion"
    static let redditRulesURL = URL(string: "https://redditinc.com/policies/reddit-rules")!
    static let eulaURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!

    static func requiresConsent(acceptedVersion: String) -> Bool {
        acceptedVersion != consentVersion
    }

    static func privacyPolicy(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: "PRIVACY", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    static func allowsNavigation(_ url: URL?, for document: LegalDocument) -> Bool {
        guard let url, url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        switch document {
        case .privacy: return false
        case .eula: return host == "www.apple.com"
        case .redditRules:
            return ["redditinc.com", "www.redditinc.com", "www.reddit.com", "support.reddithelp.com"].contains(host)
        }
    }
}

enum LegalDocument: String, Identifiable {
    case privacy, eula, redditRules
    var id: String { rawValue }
    var title: String {
        switch self {
        case .privacy: "Privacy Policy"
        case .eula: "End User License Agreement"
        case .redditRules: "Reddit Rules"
        }
    }
    var remoteURL: URL? {
        switch self {
        case .privacy: nil
        case .eula: LegalDocuments.eulaURL
        case .redditRules: LegalDocuments.redditRulesURL
        }
    }
}
