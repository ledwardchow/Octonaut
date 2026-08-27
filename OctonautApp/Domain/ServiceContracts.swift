import Foundation

protocol MediaService: Sendable {
    func exportVideo(source: URL, audio: URL?, cleanupDate: Date?) async throws -> ExportJob
    func cancelExport(_ id: UUID) async
}

protocol LinkRouter: Sendable {
    func route(_ url: URL) -> AppRoute?
    func canonicalURL(for url: URL) -> URL
}

protocol PersistenceStore: Sendable {
    func loadAccounts() async throws -> [Account]
    func saveAccount(_ account: Account) async throws
    func deleteAccount(_ id: AccountID) async throws
    func loadSeenPostIDs() async throws -> [String]
    func markPostSeen(_ id: String, seenAt: Date) async throws
    func removePostSeen(_ id: String) async throws
    func clearSeenPosts() async throws
    func loadDrafts(accountID: AccountID?) async throws -> [Draft]
    func saveDraft(_ draft: Draft) async throws
    func deleteDraft(_ id: UUID) async throws
    func clearDrafts(accountID: AccountID?) async throws
    func loadUsageStatistics() async throws -> UsageStatistics
    func incrementStatistic(_ counter: UsageStatistic, by amount: Int) async throws
    func beginUsageSession() async
    func recordCommunityVisit(_ community: String) async throws
    func resetUsageStatistics() async throws
}

enum UsageStatistic: String, Codable, Hashable, Sendable {
    case postsViewed
    case feedScrollPoints
}

struct UsageStatistics: Equatable, Sendable {
    static let pointsPerMeter = 6_250.0

    var postsViewed = 0
    var communityVisits = 0
    var feedScrollPoints = 0

    var scrollDistanceMeters: Double {
        Double(feedScrollPoints) / Self.pointsPerMeter
    }
}

protocol SecretStore: Sendable {
    func read(for accountID: AccountID) async throws -> SessionSecret?
    func write(_ secret: SessionSecret, for accountID: AccountID) async throws
    func delete(for accountID: AccountID) async throws
    func removeAll() async throws
}

struct SessionSecret: Codable, Hashable, Sendable {
    var cookieName: String
    var cookieValue: String
    var modhash: String?
    var redditUser: String
    var validatedAt: Date
}

struct UnavailableServiceError: Error, Sendable {
    let service: String
}
