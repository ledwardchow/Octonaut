import XCTest

@testable import Octonaut

final class InboxRequestStateTests: XCTestCase {
    @MainActor
    func testAccountSwitchCannotMarkNewAccountRead() {
        let first = AccountSelectionToken(accountID: AccountID(), generation: 1)
        let second = AccountSelectionToken(accountID: AccountID(), generation: 2)
        let store = OctonautFeatureStore(reddit: FixtureRedditClient(), accountID: second.accountID)
        store.inbox = [row("new-account", unread: true)]
        var state = InboxRequestState()
        let scope = state.scope(for: first)
        let request = state.beginMarkAllRead()

        state.changeAccount()

        XCTAssertFalse(state.applyMarkAllRead(request, scope: scope, currentAccount: second, store: store))
        XCTAssertTrue(store.inbox[0].isUnread)
    }

    @MainActor
    func testFilterRoundTripClearsRowsAndRejectsOldFailure() {
        let account = AccountSelectionToken(accountID: AccountID(), generation: 1)
        let store = OctonautFeatureStore(reddit: FixtureRedditClient(), accountID: account.accountID)
        store.inbox = [row("previous-filter", unread: true)]
        var state = InboxRequestState()
        let oldScope = state.scope(for: account)
        let pendingRead = state.beginRead("previous-filter", read: true, account: account, store: store)

        state.changeFilter(store: store)
        XCTAssertTrue(store.inbox.isEmpty)
        state.changeFilter(store: store)
        store.inbox = [row("current-filter", unread: true)]

        XCTAssertFalse(oldScope.matches(account: account, filterGeneration: state.filterGeneration))
        XCTAssertFalse(state.failRead(pendingRead, currentAccount: account, store: store))
        XCTAssertEqual(store.inbox.map(\.id), ["current-filter"])
        XCTAssertTrue(store.inbox[0].isUnread)
    }

    @MainActor
    func testReadFailureRollsBackAndRetryDoesNotReverseExistingState() {
        let account = AccountSelectionToken(accountID: AccountID(), generation: 1)
        let store = OctonautFeatureStore(reddit: FixtureRedditClient(), accountID: account.accountID)
        store.inbox = [row("t4_message", unread: true)]
        var state = InboxRequestState()
        let first = state.beginRead("t4_message", read: true, account: account, store: store)
        XCTAssertFalse(store.inbox[0].isUnread)
        XCTAssertTrue(state.failRead(first, currentAccount: account, store: store))
        XCTAssertTrue(store.inbox[0].isUnread)

        // A refresh can show the requested state before a retry finishes.
        store.inbox[0].isUnread = false
        let retry = state.beginRead("t4_message", read: true, account: account, store: store)
        XCTAssertFalse(state.failRead(first, currentAccount: account, store: store))
        XCTAssertTrue(state.failRead(retry, currentAccount: account, store: store))
        XCTAssertFalse(store.inbox[0].isUnread)
    }

    @MainActor
    func testSuccessfulMarkAllInvalidatesPendingRowFailureAfterFilterChange() {
        let account = AccountSelectionToken(accountID: AccountID(), generation: 1)
        let store = OctonautFeatureStore(reddit: FixtureRedditClient(), accountID: account.accountID)
        store.inbox = [row("t4_message", unread: true)]
        var state = InboxRequestState()
        let scope = state.scope(for: account)
        let pendingRead = state.beginRead("t4_message", read: true, account: account, store: store)
        let markAll = state.beginMarkAllRead()
        state.changeFilter(store: store)
        store.inbox = [row("t4_message", unread: true)]

        XCTAssertTrue(state.applyMarkAllRead(markAll, scope: scope, currentAccount: account, store: store))
        XCTAssertFalse(store.inbox[0].isUnread)
        XCTAssertFalse(state.failRead(pendingRead, currentAccount: account, store: store))
        XCTAssertFalse(store.inbox[0].isUnread)
    }

    @MainActor
    func testMarkAllPreservesLaterUnreadActionAndItsFailure() {
        let account = AccountSelectionToken(accountID: AccountID(), generation: 1)
        let store = OctonautFeatureStore(reddit: FixtureRedditClient(), accountID: account.accountID)
        store.inbox = [row("t4_message", unread: false), row("t4_other", unread: true)]
        var state = InboxRequestState()
        let scope = state.scope(for: account)
        let markAll = state.beginMarkAllRead()
        let laterRead = state.beginRead("t4_message", read: false, account: account, store: store)

        XCTAssertTrue(state.applyMarkAllRead(markAll, scope: scope, currentAccount: account, store: store))
        XCTAssertTrue(store.inbox[0].isUnread)
        XCTAssertFalse(store.inbox[1].isUnread)
        XCTAssertTrue(state.failRead(laterRead, currentAccount: account, store: store))
        XCTAssertFalse(store.inbox[0].isUnread)
    }

    private func row(_ id: String, unread: Bool) -> InboxCardModel {
        InboxCardModel(
            id: id, kind: .message, title: "Message", subtitle: "", preview: "",
            author: "", age: "", score: nil, isUnread: unread
        )
    }
}
