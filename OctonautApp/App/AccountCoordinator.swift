import Foundation
import Observation

@MainActor
@Observable
final class AccountCoordinator {
    private let persistence: any PersistenceStore
    private let secrets: any SecretStore
    private let selectionDefaults: UserDefaults?
    private var hasResolvedSelection = false
    @ObservationIgnored var accountSelectionDidChange: ((Account?) -> Void)?
    private static let selectionKey = "accounts.selectedAccount"

    private(set) var accounts: [Account] = []
    private(set) var selectedAccountID: AccountID?
    private(set) var selectionGeneration: UInt = 0
    private(set) var isLoading = false
    private(set) var lastError: DisplayableError?

    init(persistence: any PersistenceStore, secrets: any SecretStore, selectionDefaults: UserDefaults? = nil) {
        self.persistence = persistence
        self.secrets = secrets
        self.selectionDefaults = selectionDefaults
    }

    private func saveSelection() {
        accountSelectionDidChange?(selectedAccount)
        // Only the local account ID is stored here. Session secrets stay in Keychain.
        selectionDefaults?.set(selectedAccountID?.description ?? "anonymous", forKey: Self.selectionKey)
    }

    var showingLoginRequired = false

    /// Call before opening a screen or sending an action that needs a session.
    @discardableResult
    func requireLogin() -> Bool {
        guard selectedAccount?.health == .healthy else {
            showingLoginRequired = true
            return false
        }
        return true
    }

    var selectedAccount: Account? {
        guard let selectedAccountID else { return nil }
        return accounts.first { $0.id == selectedAccountID }
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            accounts = try await persistence.loadAccounts()
            if !hasResolvedSelection {
                let savedSelection = selectionDefaults?.string(forKey: Self.selectionKey)
                let restoredID: AccountID?
                if let savedSelection {
                    restoredID = accounts.first { $0.id.description == savedSelection }?.id
                } else {
                    restoredID = accounts.first?.id
                }
                hasResolvedSelection = true
                if selectedAccountID != restoredID {
                    selectionGeneration &+= 1
                    selectedAccountID = restoredID
                }
                saveSelection()
            } else if let selectedAccountID, !accounts.contains(where: { $0.id == selectedAccountID }) {
                clearSelection()
            }
            accountSelectionDidChange?(selectedAccount)
        } catch {
            lastError = DisplayableError(error: error)
        }
    }

    func add(_ account: Account, secret: SessionSecret) async throws {
        let existing = accounts.first { $0.username.caseInsensitiveCompare(account.username) == .orderedSame }
        let accountToSave = existing.map {
            Account(
                id: $0.id,
                username: account.username,
                avatarURL: account.avatarURL,
                createdAt: $0.createdAt,
                lastUsedAt: account.lastUsedAt,
                lastValidatedAt: account.lastValidatedAt,
                health: account.health,
                transport: account.transport
            )
        } ?? account
        try await secrets.write(secret, for: accountToSave.id)
        try await persistence.saveAccount(accountToSave)
        accounts.removeAll { $0.id == accountToSave.id }
        accounts.append(accountToSave)
        accounts.sort { ($0.lastUsedAt ?? $0.createdAt) > ($1.lastUsedAt ?? $1.createdAt) }
        try await select(accountToSave.id)
    }

    func select(_ id: AccountID?) async throws {
        hasResolvedSelection = true
        selectionGeneration &+= 1
        selectedAccountID = id.flatMap { candidate in accounts.first { $0.id == candidate }?.id }
        saveSelection()
        guard let id = selectedAccountID,
              var account = accounts.first(where: { $0.id == id }) else { return }
        account.lastUsedAt = .now
        if account.health == .needsLogin {
            // Selecting an expired account is still allowed so the UI can offer reauthentication.
        }
        try await persistence.saveAccount(account)
        accounts = try await persistence.loadAccounts()
    }

    func remove(_ id: AccountID) async throws {
        if selectedAccountID == id {
            let replacement = accounts.first(where: { $0.id != id })?.id
            try await select(replacement)
        }
        try await secrets.delete(for: id)
        try await persistence.deleteAccount(id)
        await SubscribedCommunitiesCache.shared.remove(for: id)
        await UserProfileCache.shared.remove(for: id)
        accounts.removeAll { $0.id == id }
        if selectedAccountID == id { selectedAccountID = accounts.first?.id }
    }

    func markNeedsLogin(_ id: AccountID) async {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.health = .needsLogin
        do {
            try await persistence.saveAccount(account)
            accounts = try await persistence.loadAccounts()
            accountSelectionDidChange?(selectedAccount)
        } catch {
            lastError = DisplayableError(error: error)
        }
    }

    func updateHealth(_ health: AccountHealth, for id: AccountID) async {
        guard var account = accounts.first(where: { $0.id == id }) else { return }
        account.health = health
        account.lastValidatedAt = health == .healthy ? .now : account.lastValidatedAt
        do {
            try await persistence.saveAccount(account)
            accounts = try await persistence.loadAccounts()
            accountSelectionDidChange?(selectedAccount)
        } catch {
            lastError = DisplayableError(error: error)
        }
    }

    func token(for accountID: AccountID? = nil) -> AccountSelectionToken {
        AccountSelectionToken(accountID: accountID ?? selectedAccountID, generation: selectionGeneration)
    }

    func isCurrent(_ token: AccountSelectionToken) -> Bool {
        token.generation == selectionGeneration && token.accountID == selectedAccountID
    }

    func logOut() async throws {
        let accountID = selectedAccountID
        clearSelection()
        if let accountID {
            try await remove(accountID)
        }
    }

    private func clearSelection() {
        hasResolvedSelection = true
        selectionGeneration &+= 1
        selectedAccountID = nil
        saveSelection()
    }

    func removeAll() async throws {
        clearSelection()
        try await secrets.removeAll()
        for account in accounts {
            try await persistence.deleteAccount(account.id)
        }
        await SubscribedCommunitiesCache.shared.removeAll()
        await UserProfileCache.shared.removeAll()
        accounts.removeAll()
    }
}

struct AccountSelectionToken: Hashable, Sendable {
    let accountID: AccountID?
    let generation: UInt
}
