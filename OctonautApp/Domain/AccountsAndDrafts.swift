import Foundation

enum AccountHealth: String, Codable, Hashable, Sendable {
    case unknown
    case healthy
    case needsLogin
    case validating
    case unavailable
}

enum AccountTransportKind: String, Codable, Hashable, Sendable {
    case webSession
    case oauth
}

enum InboxSection: String, Codable, Hashable, Sendable, CaseIterable {
    case all = "inbox"
    case unread
    case replies = "comments"
    case postReplies = "selfreply"
    case mentions
    case messages
}

struct Account: Codable, Hashable, Sendable, Identifiable {
    let id: AccountID
    var username: String
    var avatarURL: URL?
    var createdAt: Date
    var lastUsedAt: Date?
    var lastValidatedAt: Date?
    var health: AccountHealth
    var transport: AccountTransportKind

    init(
        id: AccountID = AccountID(),
        username: String,
        avatarURL: URL? = nil,
        createdAt: Date = .now,
        lastUsedAt: Date? = nil,
        lastValidatedAt: Date? = nil,
        health: AccountHealth = .unknown,
        transport: AccountTransportKind = .webSession
    ) {
        self.id = id
        self.username = username
        self.avatarURL = avatarURL
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.lastValidatedAt = lastValidatedAt
        self.health = health
        self.transport = transport
    }
}

enum DraftKind: String, Codable, Hashable, Sendable {
    case post
    case comment
    case message
}

struct Draft: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    var kind: DraftKind
    var accountID: AccountID?
    var target: String?
    var title: String
    var body: String
    var link: URL?
    var selectedFlair: Flair?
    var createdAt: Date
    var modifiedAt: Date
    var uploadRecovery: UploadRecovery?

    struct UploadRecovery: Codable, Hashable, Sendable {
        var localFileName: String
        var contentType: String?
        var createdAt: Date
    }

    init(
        id: UUID = UUID(),
        kind: DraftKind,
        accountID: AccountID?,
        target: String? = nil,
        title: String = "",
        body: String = "",
        link: URL? = nil,
        selectedFlair: Flair? = nil,
        createdAt: Date = .now,
        modifiedAt: Date = .now,
        uploadRecovery: UploadRecovery? = nil
    ) {
        self.id = id
        self.kind = kind
        self.accountID = accountID
        self.target = target
        self.title = title
        self.body = body
        self.link = link
        self.selectedFlair = selectedFlair
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.uploadRecovery = uploadRecovery
    }
}

struct ExportJob: Hashable, Codable, Sendable, Identifiable {
    let id: UUID
    var progress: Double
    var outputURL: URL?
    var isComplete: Bool
    var cleanupDate: Date?
}
