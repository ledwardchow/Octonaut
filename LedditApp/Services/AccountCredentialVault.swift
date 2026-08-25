import Foundation
import Security

public struct RedditCredential: Codable, Sendable, Equatable {
    public var cookieName: String
    public var cookieValue: String
    public var modhash: String?
    public var redditUser: String?
    public var validatedAt: Date?

    public init(
        cookieName: String = "reddit_session",
        cookieValue: String,
        modhash: String? = nil,
        redditUser: String? = nil,
        validatedAt: Date? = nil
    ) {
        self.cookieName = cookieName
        self.cookieValue = cookieValue
        self.modhash = modhash
        self.redditUser = redditUser
        self.validatedAt = validatedAt
    }
}

public enum CredentialVaultError: Error, Sendable, Equatable, LocalizedError {
    case keychain(OSStatus)
    case malformedCredential

    public var errorDescription: String? {
        switch self {
        case .keychain(let status):
            return "Keychain operation failed (status \(status))."
        case .malformedCredential:
            return "The saved Reddit credential could not be read."
        }
    }
}

protocol AccountCredentialVault: Sendable {
    func credential(for accountID: AccountID) async throws -> RedditCredential?
    func save(_ credential: RedditCredential, for accountID: AccountID) async throws
    func removeCredential(for accountID: AccountID) async throws
    func removeAllCredentials() async throws
}

/// Stores one credential per local account. The keychain item is device-only and
/// is deliberately not synchronized to iCloud.
actor KeychainCredentialVault: AccountCredentialVault {
    private let service: String
    private let accessGroup: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(service: String = "com.leddit.reddit-credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func credential(for accountID: AccountID) async throws -> RedditCredential? {
        var query = baseQuery(accountID: accountID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CredentialVaultError.keychain(status) }
        guard let data = result as? Data else { throw CredentialVaultError.malformedCredential }
        do {
            return try decoder.decode(RedditCredential.self, from: data)
        } catch {
            throw CredentialVaultError.malformedCredential
        }
    }

    func save(_ credential: RedditCredential, for accountID: AccountID) async throws {
        let data: Data
        do {
            data = try encoder.encode(credential)
        } catch {
            throw CredentialVaultError.malformedCredential
        }

        var query = baseQuery(accountID: accountID)
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable as String] = false

        let updateAttributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let updateStatus = SecItemUpdate(baseQuery(accountID: accountID) as CFDictionary, updateAttributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw CredentialVaultError.keychain(updateStatus) }

        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess || addStatus == errSecDuplicateItem else {
            throw CredentialVaultError.keychain(addStatus)
        }
        if addStatus == errSecDuplicateItem {
            let retryStatus = SecItemUpdate(baseQuery(accountID: accountID) as CFDictionary, updateAttributes as CFDictionary)
            guard retryStatus == errSecSuccess else { throw CredentialVaultError.keychain(retryStatus) }
        }
    }

    func removeCredential(for accountID: AccountID) async throws {
        let status = SecItemDelete(baseQuery(accountID: accountID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status)
        }
    }

    func removeAllCredentials() async throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialVaultError.keychain(status)
        }
    }

    private func baseQuery(accountID: AccountID) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountID.rawValue.uuidString,
            kSecAttrSynchronizable as String: false
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }
}

actor InMemoryCredentialVault: AccountCredentialVault {
    private var values: [AccountID: RedditCredential]

    init(values: [AccountID: RedditCredential] = [:]) {
        self.values = values
    }

    func credential(for accountID: AccountID) async throws -> RedditCredential? {
        values[accountID]
    }

    func save(_ credential: RedditCredential, for accountID: AccountID) async throws {
        values[accountID] = credential
    }

    func removeCredential(for accountID: AccountID) async throws {
        values.removeValue(forKey: accountID)
    }

    func removeAllCredentials() async throws {
        values.removeAll()
    }
}
