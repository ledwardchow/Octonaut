import Foundation

/// The local identifier for one saved Reddit account.
struct AccountID: Hashable, Codable, Sendable, Identifiable, CustomStringConvertible {
    let rawValue: UUID

    init() {
        rawValue = UUID()
    }

    init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        rawValue = uuid
    }

    var id: UUID { rawValue }
    var description: String { rawValue.uuidString }
}

enum AccountScope: Hashable, Codable, Sendable {
    case anonymous
    case account(AccountID)
}

enum IDNormalization {
    static func community(_ name: String) -> String {
        name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^r/", with: "", options: .regularExpression)
            .lowercased()
    }

    static func fullname(_ value: String, kind: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if trimmed.hasPrefix("t") && trimmed.contains("_") { return trimmed }
        return "\(kind)_\(trimmed)"
    }
}
