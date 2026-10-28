import Foundation
import Security
import CryptoKit

public struct WebGraphQLToken: Codable, Sendable, Equatable {
    public let value: String
    public let sourceSessionDigest: String
    public let expiresAt: Date

    public init(value: String, sourceSessionDigest: String, expiresAt: Date) {
        self.value = value
        self.sourceSessionDigest = sourceSessionDigest
        self.expiresAt = expiresAt
    }
}

enum RedditSessionIdentity {
    static func digest(_ session: String) -> String {
        SHA256.hash(data: Data(session.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public struct RedditCredential: Codable, Sendable, Equatable {
    public var cookieName: String
    public var cookieValue: String
    public var modhash: String?
    public var redditUser: String?
    public var validatedAt: Date?
    public var webGraphQLToken: WebGraphQLToken?

    public init(
        cookieName: String = "reddit_session",
        cookieValue: String,
        modhash: String? = nil,
        redditUser: String? = nil,
        validatedAt: Date? = nil,
        webGraphQLToken: WebGraphQLToken? = nil
    ) {
        self.cookieName = cookieName
        self.cookieValue = cookieValue
        self.modhash = modhash
        self.redditUser = redditUser
        self.validatedAt = validatedAt
        self.webGraphQLToken = webGraphQLToken
    }
}

public enum CredentialVaultError: Error, Sendable, Equatable, LocalizedError {
    case keychain(OSStatus)
    case malformedCredential

    public var errorDescription: String? {
        switch self {
        case .keychain(let status) where status == errSecMissingEntitlement:
            return "This build of Octonaut cannot access Keychain. Install an updated build and try again."
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
    /// Saves a token only while the original account session still exists.
    func saveWebGraphQLToken(_ token: WebGraphQLToken, for accountID: AccountID) async throws -> Bool
    func replaceSessionCookie(_ newValue: String, expected oldValue: String, for accountID: AccountID) async throws -> Bool
    func updateModhash(_ modhash: String, expectedSession: String, for accountID: AccountID) async throws -> Bool
}

/// Stores one credential per local account. The keychain item is device-only and
/// is deliberately not synchronized to iCloud.
actor KeychainCredentialVault: AccountCredentialVault {
    private let service: String
    private let accessGroup: String?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(service: String = "com.octonaut.reddit-credentials", accessGroup: String? = nil) {
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
        // Match both device-only items and any credentials left by an older
        // iCloud Keychain configuration.
        for serviceName in Set([service, "com.ledwardchow.Octonaut.reddit-session"]) {
            var query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: serviceName,
                kSecAttrSynchronizable as String: kSecAttrSynchronizableAny
            ]
            if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialVaultError.keychain(status)
            }
        }
    }

    func saveWebGraphQLToken(_ token: WebGraphQLToken, for accountID: AccountID) async throws -> Bool {
        var readQuery = baseQuery(accountID: accountID)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecItemNotFound { return false }
        guard readStatus == errSecSuccess else { throw CredentialVaultError.keychain(readStatus) }
        guard let data = result as? Data,
              var credential = try? decoder.decode(RedditCredential.self, from: data) else {
            throw CredentialVaultError.malformedCredential
        }
        guard RedditSessionIdentity.digest(credential.cookieValue) == token.sourceSessionDigest else { return false }
        credential.webGraphQLToken = token
        guard let updated = try? encoder.encode(credential) else { throw CredentialVaultError.malformedCredential }
        let updateStatus = SecItemUpdate(baseQuery(accountID: accountID) as CFDictionary, [kSecValueData as String: updated] as CFDictionary)
        if updateStatus == errSecItemNotFound { return false }
        guard updateStatus == errSecSuccess else { throw CredentialVaultError.keychain(updateStatus) }
        return true
    }

    func replaceSessionCookie(_ newValue: String, expected oldValue: String, for accountID: AccountID) async throws -> Bool {
        var readQuery = baseQuery(accountID: accountID)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecItemNotFound { return false }
        guard readStatus == errSecSuccess else { throw CredentialVaultError.keychain(readStatus) }
        guard let data = result as? Data,
              var credential = try? decoder.decode(RedditCredential.self, from: data) else {
            throw CredentialVaultError.malformedCredential
        }
        guard credential.cookieName == "reddit_session", credential.cookieValue == oldValue else { return false }
        credential.cookieValue = newValue
        credential.webGraphQLToken = nil
        guard let updated = try? encoder.encode(credential) else { throw CredentialVaultError.malformedCredential }
        let updateStatus = SecItemUpdate(baseQuery(accountID: accountID) as CFDictionary, [kSecValueData as String: updated] as CFDictionary)
        if updateStatus == errSecItemNotFound { return false }
        guard updateStatus == errSecSuccess else { throw CredentialVaultError.keychain(updateStatus) }
        return true
    }

    func updateModhash(_ modhash: String, expectedSession: String, for accountID: AccountID) async throws -> Bool {
        var readQuery = baseQuery(accountID: accountID)
        readQuery[kSecReturnData as String] = true
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let readStatus = SecItemCopyMatching(readQuery as CFDictionary, &result)
        if readStatus == errSecItemNotFound { return false }
        guard readStatus == errSecSuccess else { throw CredentialVaultError.keychain(readStatus) }
        guard let data = result as? Data,
              var credential = try? decoder.decode(RedditCredential.self, from: data) else {
            throw CredentialVaultError.malformedCredential
        }
        guard credential.cookieName == "reddit_session", credential.cookieValue == expectedSession else { return false }
        credential.modhash = modhash
        guard let updated = try? encoder.encode(credential) else { throw CredentialVaultError.malformedCredential }
        let updateStatus = SecItemUpdate(baseQuery(accountID: accountID) as CFDictionary, [kSecValueData as String: updated] as CFDictionary)
        if updateStatus == errSecItemNotFound { return false }
        guard updateStatus == errSecSuccess else { throw CredentialVaultError.keychain(updateStatus) }
        return true
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

    func saveWebGraphQLToken(_ token: WebGraphQLToken, for accountID: AccountID) async throws -> Bool {
        guard var credential = values[accountID],
              RedditSessionIdentity.digest(credential.cookieValue) == token.sourceSessionDigest else { return false }
        credential.webGraphQLToken = token
        values[accountID] = credential
        return true
    }

    func replaceSessionCookie(_ newValue: String, expected oldValue: String, for accountID: AccountID) async throws -> Bool {
        guard var credential = values[accountID], credential.cookieName == "reddit_session",
              credential.cookieValue == oldValue else { return false }
        credential.cookieValue = newValue
        credential.webGraphQLToken = nil
        values[accountID] = credential
        return true
    }

    func updateModhash(_ modhash: String, expectedSession: String, for accountID: AccountID) async throws -> Bool {
        guard var credential = values[accountID], credential.cookieName == "reddit_session",
              credential.cookieValue == expectedSession else { return false }
        credential.modhash = modhash
        values[accountID] = credential
        return true
    }
}
