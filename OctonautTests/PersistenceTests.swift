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
}
