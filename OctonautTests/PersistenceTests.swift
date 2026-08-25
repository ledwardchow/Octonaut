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
}
