import Foundation

/// Keeps the account coordinator and Reddit transport on the same Keychain
/// representation. The adapter deliberately exposes only the small domain
/// secret contract to the coordinator.
actor CredentialVaultSecretStore: SecretStore {
    private let vault: any AccountCredentialVault

    init(vault: any AccountCredentialVault) {
        self.vault = vault
    }

    func read(for accountID: AccountID) async throws -> SessionSecret? {
        guard let credential = try await vault.credential(for: accountID) else { return nil }
        return SessionSecret(
            cookieName: credential.cookieName,
            cookieValue: credential.cookieValue,
            modhash: credential.modhash,
            redditUser: credential.redditUser ?? "",
            validatedAt: credential.validatedAt ?? .now
        )
    }

    func write(_ secret: SessionSecret, for accountID: AccountID) async throws {
        let credential = RedditCredential(
            cookieName: secret.cookieName,
            cookieValue: secret.cookieValue,
            modhash: secret.modhash,
            redditUser: secret.redditUser,
            validatedAt: secret.validatedAt
        )
        try await vault.save(credential, for: accountID)
    }

    func delete(for accountID: AccountID) async throws {
        try await vault.removeCredential(for: accountID)
    }

    func removeAll() async throws {
        try await vault.removeAllCredentials()
    }
}
