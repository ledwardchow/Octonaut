import XCTest
@testable import Octonaut

final class PersistenceTests: XCTestCase {
    func testSeenPostsAreCappedAndNewestAreReturnedFirst() async throws {
        let store = InMemoryPersistenceStore()
        for index in 0..<5_010 {
            try await store.markPostSeen("post-\(index)", seenAt: Date(timeIntervalSince1970: TimeInterval(index)))
        }

        let ids = try await store.loadSeenPostIDs()
        XCTAssertEqual(ids.count, 5_000)
        XCTAssertEqual(ids.first, "post-5009")
        XCTAssertFalse(ids.contains("post-0"))
    }

    func testDraftsAreScopedToAccount() async throws {
        let store = InMemoryPersistenceStore()
        let first = AccountID()
        let second = AccountID()
        try await store.saveDraft(FixtureData.draft(accountID: first))
        try await store.saveDraft(FixtureData.draft(accountID: second))
        let firstDrafts = try await store.loadDrafts(accountID: first)
        let secondDrafts = try await store.loadDrafts(accountID: second)
        let anonymousDrafts = try await store.loadDrafts(accountID: nil)
        XCTAssertEqual(firstDrafts.count, 1)
        XCTAssertEqual(secondDrafts.count, 1)
        XCTAssertEqual(anonymousDrafts.count, 0)
    }

    func testDeletingAccountRemovesItsDrafts() async throws {
        let store = InMemoryPersistenceStore()
        let account = Account(username: "reader")
        try await store.saveAccount(account)
        try await store.saveDraft(FixtureData.draft(accountID: account.id))
        try await store.deleteAccount(account.id)
        let drafts = try await store.loadDrafts(accountID: account.id)
        XCTAssertTrue(drafts.isEmpty)
    }

    func testUsageStatisticsIncrementAndReset() async throws {
        let store = InMemoryPersistenceStore()
        try await store.incrementStatistic(.postsViewed, by: 2)
        try await store.incrementStatistic(.feedScrollPoints, by: 625)
        try await store.recordCommunityVisit("Swift")
        try await store.recordCommunityVisit("r/swift")
        try await store.recordCommunityVisit("iPhone")

        let values = try await store.loadUsageStatistics()
        XCTAssertEqual(values.postsViewed, 2)
        XCTAssertEqual(values.communityVisits, 2)
        XCTAssertEqual(values.scrollDistanceMeters, 0.1, accuracy: 0.0001)

        await store.beginUsageSession()
        try await store.recordCommunityVisit("swift")
        let nextSessionValues = try await store.loadUsageStatistics()
        XCTAssertEqual(nextSessionValues.communityVisits, 3)

        try await store.resetUsageStatistics()
        let resetValues = try await store.loadUsageStatistics()
        XCTAssertEqual(resetValues, UsageStatistics())
    }

    func testRemoveAllDataClearsEveryInMemoryCollection() async throws {
        let store = InMemoryPersistenceStore()
        let account = Account(username: "reader")
        try await store.saveAccount(account)
        try await store.saveDraft(FixtureData.draft(accountID: account.id))
        try await store.markPostSeen("post", seenAt: .now)
        try await store.incrementStatistic(.postsViewed, by: 1)
        try await store.recordCommunityVisit("swift")

        try await store.removeAllData()

        let accounts = try await store.loadAccounts()
        let drafts = try await store.loadDrafts(accountID: account.id)
        let seenPosts = try await store.loadSeenPostIDs()
        let statistics = try await store.loadUsageStatistics()
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(drafts.isEmpty)
        XCTAssertTrue(seenPosts.isEmpty)
        XCTAssertEqual(statistics, UsageStatistics())
    }

    @MainActor
    func testRemoveAllDataClearsSwiftDataStore() async throws {
        let store = SwiftDataPersistenceStore(container: try PersistenceSchema.makeContainer(inMemory: true))
        let account = Account(username: "reader")
        try await store.saveAccount(account)
        try await store.saveDraft(FixtureData.draft(accountID: account.id))
        try await store.markPostSeen("post", seenAt: .now)
        try await store.incrementStatistic(.postsViewed, by: 1)

        try await store.removeAllData()

        let accounts = try await store.loadAccounts()
        let drafts = try await store.loadDrafts(accountID: account.id)
        let seenPosts = try await store.loadSeenPostIDs()
        let statistics = try await store.loadUsageStatistics()
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertTrue(drafts.isEmpty)
        XCTAssertTrue(seenPosts.isEmpty)
        XCTAssertEqual(statistics, UsageStatistics())
    }

    @MainActor
    func testLogoutDeletesSelectedSwiftDataAccountAndDrafts() async throws {
        let store = SwiftDataPersistenceStore(container: try PersistenceSchema.makeContainer(inMemory: true))
        let vault = InMemoryCredentialVault()
        let coordinator = AccountCoordinator(persistence: store, secrets: CredentialVaultSecretStore(vault: vault))
        let remaining = Account(username: "remaining", health: .healthy)
        let selected = Account(username: "selected", health: .healthy)
        let secret = SessionSecret(
            cookieName: "reddit_session", cookieValue: "synthetic-session",
            modhash: "synthetic-modhash", redditUser: "selected", validatedAt: .now
        )
        try await coordinator.add(remaining, secret: secret)
        try await coordinator.add(selected, secret: secret)
        try await store.saveDraft(FixtureData.draft(accountID: remaining.id))
        try await store.saveDraft(FixtureData.draft(accountID: selected.id))

        try await coordinator.logOut()
        await coordinator.load()
        let savedAccounts = try await store.loadAccounts()
        let removedDrafts = try await store.loadDrafts(accountID: selected.id)
        let remainingDrafts = try await store.loadDrafts(accountID: remaining.id)
        let removedCredential = try await vault.credential(for: selected.id)
        let remainingCredential = try await vault.credential(for: remaining.id)

        XCTAssertNil(coordinator.selectedAccountID)
        XCTAssertEqual(coordinator.accounts.map(\.id), [remaining.id])
        XCTAssertEqual(savedAccounts.map(\.id), [remaining.id])
        XCTAssertTrue(removedDrafts.isEmpty)
        XCTAssertEqual(remainingDrafts.count, 1)
        XCTAssertNil(removedCredential)
        XCTAssertNotNil(remainingCredential)
    }

    @MainActor
    func testSwiftDataUsageStatisticsPersist() async throws {
        let container = try PersistenceSchema.makeContainer(inMemory: true)
        let store = SwiftDataPersistenceStore(container: container)
        try await store.incrementStatistic(.postsViewed, by: 3)
        try await store.recordCommunityVisit("swift")

        let values = try await store.loadUsageStatistics()
        XCTAssertEqual(values.postsViewed, 3)
        XCTAssertEqual(values.communityVisits, 1)
    }

    @MainActor
    func testAccountSurvivesReopeningDiskStore() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("accounts.store")
        let account = Account(username: "persistent-reader")
        do {
            let container = try PersistenceSchema.makeContainer(storeURL: url)
            let store = SwiftDataPersistenceStore(container: container)
            try await store.saveAccount(account)
        }
        let reopened = try PersistenceSchema.makeContainer(storeURL: url)
        let restored = try await SwiftDataPersistenceStore(container: reopened).loadAccounts()
        XCTAssertEqual(restored.map(\.id), [account.id])
        XCTAssertEqual(restored.first?.username, account.username)
    }

}
