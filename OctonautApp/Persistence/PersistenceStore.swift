import Foundation
import SwiftData

actor InMemoryPersistenceStore: PersistenceStore {
    private var accounts: [AccountID: Account] = [:]
    private var seen: [String: Date] = [:]
    private var drafts: [UUID: Draft] = [:]
    private var statistics: [UsageStatistic: Int] = [:]
    private var communityVisits: [String: Int] = [:]
    private var communitiesVisitedThisSession: Set<String> = []
    private var feedPreferences: [String: FeedSortPreference] = [:]

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

    func loadFeedPreference(feedKey: String, accountScope: String) async throws -> FeedSortPreference? {
        feedPreferences["\(accountScope)|\(feedKey)"]
    }

    func saveFeedPreference(_ preference: FeedSortPreference, feedKey: String, accountScope: String) async throws {
        feedPreferences["\(accountScope)|\(feedKey)"] = preference
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

    func loadUsageStatistics() async throws -> UsageStatistics {
        UsageStatistics(
            postsViewed: statistics[.postsViewed, default: 0],
            communityVisits: communityVisits.values.reduce(0, +),
            feedScrollPoints: statistics[.feedScrollPoints, default: 0]
        )
    }

    func incrementStatistic(_ counter: UsageStatistic, by amount: Int = 1) async throws {
        guard amount > 0 else { return }
        statistics[counter, default: 0] += amount
    }

    func beginUsageSession() async {
        communitiesVisitedThisSession.removeAll()
    }

    func recordCommunityVisit(_ community: String) async throws {
        let normalized = IDNormalization.community(community)
        guard !normalized.isEmpty, communitiesVisitedThisSession.insert(normalized).inserted else { return }
        communityVisits[normalized, default: 0] += 1
    }

    func resetUsageStatistics() async throws {
        statistics.removeAll()
        communityVisits.removeAll()
        communitiesVisitedThisSession.removeAll()
    }

    func removeAllData() async throws {
        accounts.removeAll()
        seen.removeAll()
        drafts.removeAll()
        statistics.removeAll()
        communityVisits.removeAll()
        communitiesVisitedThisSession.removeAll()
    }
}

@MainActor
final class SwiftDataPersistenceStore: PersistenceStore, @unchecked Sendable {
    let container: ModelContainer
    private let context: ModelContext
    private var communitiesVisitedThisSession: Set<String> = []
    private var seenIDsCache: Set<String>?
    private var seenCount: Int?

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
        let targetID = account.id.rawValue
        var descriptor = FetchDescriptor<AccountRecord>(
            predicate: #Predicate<AccountRecord> { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        let records = try context.fetch(descriptor)
        if let existing = records.first {
            existing.update(from: account)
        } else {
            context.insert(AccountRecord(account: account))
        }
        try context.save()
    }

    func deleteAccount(_ id: AccountID) async throws {
        let targetID = id.rawValue
        let accountDescriptor = FetchDescriptor<AccountRecord>(
            predicate: #Predicate<AccountRecord> { $0.id == targetID }
        )
        try context.fetch(accountDescriptor).forEach(context.delete)
        let accountKey = id.description
        let draftDescriptor = FetchDescriptor<DraftRecord>(
            predicate: #Predicate<DraftRecord> { $0.accountIDString == accountKey }
        )
        try context.fetch(draftDescriptor).forEach(context.delete)
        try context.save()
    }

    func loadSeenPostIDs() async throws -> [String] {
        var descriptor = FetchDescriptor<SeenPostRecord>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse)]
        )
        let records = try context.fetch(descriptor)
        let ids = records.map(\.postID)
        seenIDsCache = Set(ids)
        seenCount = ids.count
        return ids
    }

    func markPostSeen(_ id: String, seenAt: Date = .now) async throws {
        var descriptor = FetchDescriptor<SeenPostRecord>(
            predicate: #Predicate<SeenPostRecord> { $0.postID == id }
        )
        descriptor.fetchLimit = 1
        let records = try context.fetch(descriptor)
        if let record = records.first {
            record.lastSeenAt = seenAt
        } else {
            context.insert(SeenPostRecord(postID: id, seenAt: seenAt))
            seenIDsCache?.insert(id)
            if let count = seenCount {
                seenCount = count + 1
            }
        }
        let currentCount = seenCount ?? (try? context.fetchCount(FetchDescriptor<SeenPostRecord>())) ?? 0
        seenCount = currentCount
        if currentCount > 5_000 {
            let excess = currentCount - 5_000
            var pruneDescriptor = FetchDescriptor<SeenPostRecord>(
                sortBy: [SortDescriptor(\.lastSeenAt, order: .forward)]
            )
            pruneDescriptor.fetchLimit = excess
            let oldest = try context.fetch(pruneDescriptor)
            for record in oldest {
                seenIDsCache?.remove(record.postID)
                context.delete(record)
            }
            seenCount = 5_000
        }
        try context.save()
    }

    func removePostSeen(_ id: String) async throws {
        let descriptor = FetchDescriptor<SeenPostRecord>(
            predicate: #Predicate<SeenPostRecord> { $0.postID == id }
        )
        let records = try context.fetch(descriptor)
        records.forEach(context.delete)
        seenIDsCache?.remove(id)
        if let count = seenCount {
            seenCount = max(0, count - records.count)
        }
        try context.save()
    }

    func clearSeenPosts() async throws {
        try context.fetch(FetchDescriptor<SeenPostRecord>()).forEach(context.delete)
        seenIDsCache?.removeAll()
        seenCount = 0
        try context.save()
    }

    func loadFeedPreference(feedKey: String, accountScope: String) async throws -> FeedSortPreference? {
        var descriptor = FetchDescriptor<FeedPreferenceRecord>(
            predicate: #Predicate<FeedPreferenceRecord> {
                $0.feedKey == feedKey && $0.accountScopeKey == accountScope
            }
        )
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else { return nil }
        return FeedSortPreference(
            sort: PostSort(rawValue: record.sortRawValue),
            topTime: record.topTimeRawValue.flatMap(TopTime.init(rawValue:))
        )
    }

    func saveFeedPreference(_ preference: FeedSortPreference, feedKey: String, accountScope: String) async throws {
        var descriptor = FetchDescriptor<FeedPreferenceRecord>(
            predicate: #Predicate<FeedPreferenceRecord> {
                $0.feedKey == feedKey && $0.accountScopeKey == accountScope
            }
        )
        descriptor.fetchLimit = 1
        if let record = try context.fetch(descriptor).first {
            record.sortRawValue = preference.sort.rawValue
            record.topTimeRawValue = preference.topTime?.rawValue
        } else {
            context.insert(FeedPreferenceRecord(
                accountScopeKey: accountScope,
                feedKey: feedKey,
                sort: preference.sort,
                topTime: preference.topTime
            ))
        }
        try context.save()
    }

    func loadDrafts(accountID: AccountID?) async throws -> [Draft] {
        let accountKey = accountID?.description
        var descriptor = FetchDescriptor<DraftRecord>(
            predicate: #Predicate<DraftRecord> { $0.accountIDString == accountKey },
            sortBy: [SortDescriptor(\.modifiedAt, order: .reverse)]
        )
        return try context.fetch(descriptor)
            .compactMap(\.domainValue)
    }

    func saveDraft(_ draft: Draft) async throws {
        let targetID = draft.id
        var descriptor = FetchDescriptor<DraftRecord>(
            predicate: #Predicate<DraftRecord> { $0.id == targetID }
        )
        descriptor.fetchLimit = 1
        let records = try context.fetch(descriptor)
        if let existing = records.first {
            context.delete(existing)
        }
        context.insert(DraftRecord(draft: draft))
        let totalDrafts = (try? context.fetchCount(FetchDescriptor<DraftRecord>())) ?? 0
        if totalDrafts > 100 {
            let excess = totalDrafts - 100
            var pruneDescriptor = FetchDescriptor<DraftRecord>(
                sortBy: [SortDescriptor(\.modifiedAt, order: .forward)]
            )
            pruneDescriptor.fetchLimit = excess
            try context.fetch(pruneDescriptor).forEach(context.delete)
        }
        try context.save()
    }

    func deleteDraft(_ id: UUID) async throws {
        let descriptor = FetchDescriptor<DraftRecord>(
            predicate: #Predicate<DraftRecord> { $0.id == id }
        )
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func clearDrafts(accountID: AccountID?) async throws {
        let key = accountID?.description
        let descriptor = FetchDescriptor<DraftRecord>(
            predicate: #Predicate<DraftRecord> { $0.accountIDString == key }
        )
        try context.fetch(descriptor).forEach(context.delete)
        try context.save()
    }

    func loadUsageStatistics() async throws -> UsageStatistics {
        let counters = try context.fetch(FetchDescriptor<StatisticRecord>())
        let values = Dictionary(uniqueKeysWithValues: counters.map { ($0.counterName, $0.value) })
        let visits = try context.fetch(FetchDescriptor<CommunityVisitRecord>())
        return UsageStatistics(
            postsViewed: values[UsageStatistic.postsViewed.rawValue, default: 0],
            communityVisits: visits.reduce(0) { $0 + $1.visitCount },
            feedScrollPoints: values[UsageStatistic.feedScrollPoints.rawValue, default: 0]
        )
    }

    func incrementStatistic(_ counter: UsageStatistic, by amount: Int = 1) async throws {
        guard amount > 0 else { return }
        let records = try context.fetch(FetchDescriptor<StatisticRecord>())
        if let existing = records.first(where: { $0.counterName == counter.rawValue }) {
            existing.value += amount
        } else {
            context.insert(StatisticRecord(counterName: counter.rawValue, value: amount))
        }
        try context.save()
    }

    func beginUsageSession() async {
        communitiesVisitedThisSession.removeAll()
    }

    func recordCommunityVisit(_ community: String) async throws {
        let normalized = IDNormalization.community(community)
        guard !normalized.isEmpty, communitiesVisitedThisSession.insert(normalized).inserted else { return }
        var descriptor = FetchDescriptor<CommunityVisitRecord>(
            predicate: #Predicate<CommunityVisitRecord> { $0.normalizedCommunity == normalized }
        )
        descriptor.fetchLimit = 1
        let records = try context.fetch(descriptor)
        if let existing = records.first {
            existing.visitCount += 1
        } else {
            context.insert(CommunityVisitRecord(normalizedCommunity: normalized, visitCount: 1))
        }
        try context.save()
    }

    func resetUsageStatistics() async throws {
        try context.fetch(FetchDescriptor<StatisticRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CommunityVisitRecord>()).forEach(context.delete)
        communitiesVisitedThisSession.removeAll()
        try context.save()
    }

    func removeAllData() async throws {
        try context.fetch(FetchDescriptor<AccountRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<SeenPostRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<DraftRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<FavoriteCommunityRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<FilteredCommunityRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<KeywordRuleRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<SemanticRuleRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<FeedPreferenceRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CustomThemeRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<StatisticRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<CommunityVisitRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<SummaryCacheRecord>()).forEach(context.delete)
        try context.fetch(FetchDescriptor<HelpIndexRecord>()).forEach(context.delete)
        communitiesVisitedThisSession.removeAll()
        seenIDsCache = nil
        seenCount = 0
        try context.save()
    }
}
