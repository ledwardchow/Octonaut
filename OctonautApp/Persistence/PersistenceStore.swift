import Foundation
import SwiftData

actor InMemoryPersistenceStore: PersistenceStore {
    private var accounts: [AccountID: Account] = [:]
    private var seen: [String: Date] = [:]
    private var drafts: [UUID: Draft] = [:]

    func loadAccounts() async throws -> [Account] {
        accounts.values.sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    func saveAccount(_ account: Account) async throws {
        accounts[account.id] = account
    }

    func deleteAccount(_ id: AccountID) async throws {
        accounts.removeValue(forKey: id)
        drafts = drafts.filter { $0.value.accountID != id }
    }

    func loadSeenPostIDs() async throws -> [String] {
        seen.sorted { $0.value > $1.value }.map(\.key)
    }

    func markPostSeen(_ id: String, seenAt: Date = .now) async throws {
        seen[id] = seenAt
        if seen.count > 5_000 {
            let excess = seen.count - 5_000
            let oldest = seen.sorted { $0.value < $1.value }.prefix(excess).map(\.key)
            oldest.forEach { seen.removeValue(forKey: $0) }
        }
    }

    func removePostSeen(_ id: String) async throws {
        seen.removeValue(forKey: id)
    }

    func clearSeenPosts() async throws {
        seen.removeAll()
    }

    func loadDrafts(accountID: AccountID?) async throws -> [Draft] {
        drafts.values
            .filter { $0.accountID == accountID }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func saveDraft(_ draft: Draft) async throws {
        drafts[draft.id] = draft
        if drafts.count > 100 {
            let oldest = drafts.values.sorted { $0.modifiedAt < $1.modifiedAt }.prefix(drafts.count - 100).map(\.id)
            oldest.forEach { drafts.removeValue(forKey: $0) }
        }
    }

    func deleteDraft(_ id: UUID) async throws {
        drafts.removeValue(forKey: id)
    }

    func clearDrafts(accountID: AccountID?) async throws {
        drafts = drafts.filter { $0.value.accountID != accountID }
    }
}

@MainActor
final class SwiftDataPersistenceStore: PersistenceStore, @unchecked Sendable {
    let container: ModelContainer
    private let context: ModelContext

    init(container: ModelContainer) {
        self.container = container
        context = ModelContext(container)
    }

    func loadAccounts() async throws -> [Account] {
        try context.fetch(FetchDescriptor<AccountRecord>())
            .compactMap(\.domainValue)
            .sorted { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
    }

    func saveAccount(_ account: Account) async throws {
        let records = try context.fetch(FetchDescriptor<AccountRecord>())
        if let existing = records.first(where: { $0.id == account.id.rawValue }) {
            existing.update(from: account)
        } else {
            context.insert(AccountRecord(account: account))
        }
        try context.save()
    }

    func deleteAccount(_ id: AccountID) async throws {
        let records = try context.fetch(FetchDescriptor<AccountRecord>())
        records.filter { $0.id == id.rawValue }.forEach(context.delete)
        let drafts = try context.fetch(FetchDescriptor<DraftRecord>())
        drafts.filter { $0.accountIDString == id.description }.forEach(context.delete)
        try context.save()
    }

    func loadSeenPostIDs() async throws -> [String] {
        try context.fetch(FetchDescriptor<SeenPostRecord>())
            .sorted { $0.lastSeenAt > $1.lastSeenAt }
            .map(\.postID)
    }

    func markPostSeen(_ id: String, seenAt: Date = .now) async throws {
        let records = try context.fetch(FetchDescriptor<SeenPostRecord>())
        if let record = records.first(where: { $0.postID == id }) {
            record.lastSeenAt = seenAt
        } else {
            context.insert(SeenPostRecord(postID: id, seenAt: seenAt))
        }
        let refreshed = try context.fetch(FetchDescriptor<SeenPostRecord>())
        if refreshed.count > 5_000 {
            let excess = refreshed.sorted { $0.lastSeenAt < $1.lastSeenAt }.prefix(refreshed.count - 5_000)
            excess.forEach(context.delete)
        }
        try context.save()
    }

    func removePostSeen(_ id: String) async throws {
        let records = try context.fetch(FetchDescriptor<SeenPostRecord>())
        records.filter { $0.postID == id }.forEach(context.delete)
        try context.save()
    }

    func clearSeenPosts() async throws {
        try context.fetch(FetchDescriptor<SeenPostRecord>()).forEach(context.delete)
        try context.save()
    }

    func loadDrafts(accountID: AccountID?) async throws -> [Draft] {
        let accountKey = accountID?.description
        return try context.fetch(FetchDescriptor<DraftRecord>())
            .filter { $0.accountIDString == accountKey }
            .compactMap(\.domainValue)
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func saveDraft(_ draft: Draft) async throws {
        let records = try context.fetch(FetchDescriptor<DraftRecord>())
        if let existing = records.first(where: { $0.id == draft.id }) {
            context.delete(existing)
        }
        context.insert(DraftRecord(draft: draft))
        let updated = try context.fetch(FetchDescriptor<DraftRecord>())
        if updated.count > 100 {
            updated.sorted { $0.modifiedAt < $1.modifiedAt }.prefix(updated.count - 100).forEach(context.delete)
        }
        try context.save()
    }

    func deleteDraft(_ id: UUID) async throws {
        try context.fetch(FetchDescriptor<DraftRecord>()).filter { $0.id == id }.forEach(context.delete)
        try context.save()
    }

    func clearDrafts(accountID: AccountID?) async throws {
        let key = accountID?.description
        try context.fetch(FetchDescriptor<DraftRecord>()).filter { $0.accountIDString == key }.forEach(context.delete)
        try context.save()
    }
}
