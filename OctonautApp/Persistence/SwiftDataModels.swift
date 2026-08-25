import Foundation
import SwiftData

@Model
final class AccountRecord {
    @Attribute(.unique) var id: UUID
    var username: String
    var avatarURLString: String?
    var createdAt: Date
    var lastUsedAt: Date?
    var lastValidatedAt: Date?
    var healthRawValue: String
    var transportRawValue: String

    init(account: Account) {
        id = account.id.rawValue
        username = account.username
        avatarURLString = account.avatarURL?.absoluteString
        createdAt = account.createdAt
        lastUsedAt = account.lastUsedAt
        lastValidatedAt = account.lastValidatedAt
        healthRawValue = account.health.rawValue
        transportRawValue = account.transport.rawValue
    }

    func update(from account: Account) {
        username = account.username
        avatarURLString = account.avatarURL?.absoluteString
        createdAt = account.createdAt
        lastUsedAt = account.lastUsedAt
        lastValidatedAt = account.lastValidatedAt
        healthRawValue = account.health.rawValue
        transportRawValue = account.transport.rawValue
    }

    var domainValue: Account? {
        let accountID = AccountID(rawValue: id)
        return Account(
            id: accountID,
            username: username,
            avatarURL: avatarURLString.flatMap(URL.init(string:)),
            createdAt: createdAt,
            lastUsedAt: lastUsedAt,
            lastValidatedAt: lastValidatedAt,
            health: AccountHealth(rawValue: healthRawValue) ?? .unknown,
            transport: AccountTransportKind(rawValue: transportRawValue) ?? .webSession
        )
    }
}

@Model
final class SeenPostRecord {
    @Attribute(.unique) var postID: String
    var firstSeenAt: Date
    var lastSeenAt: Date
    var source: String

    init(postID: String, seenAt: Date = .now, source: String = "detail") {
        self.postID = postID
        firstSeenAt = seenAt
        lastSeenAt = seenAt
        self.source = source
    }
}

@Model
final class DraftRecord {
    @Attribute(.unique) var id: UUID
    var kindRawValue: String
    var accountIDString: String?
    var target: String?
    var title: String
    var body: String
    var linkString: String?
    var selectedFlairData: Data?
    var createdAt: Date
    var modifiedAt: Date
    var uploadRecoveryData: Data?

    init(draft: Draft) {
        id = draft.id
        kindRawValue = draft.kind.rawValue
        accountIDString = draft.accountID?.description
        target = draft.target
        title = draft.title
        body = draft.body
        linkString = draft.link?.absoluteString
        selectedFlairData = try? JSONEncoder().encode(draft.selectedFlair)
        createdAt = draft.createdAt
        modifiedAt = draft.modifiedAt
        uploadRecoveryData = try? JSONEncoder().encode(draft.uploadRecovery)
    }

    var domainValue: Draft? {
        guard let kind = DraftKind(rawValue: kindRawValue) else { return nil }
        let accountID = accountIDString.flatMap(AccountID.init(string:))
        let flair = selectedFlairData.flatMap { try? JSONDecoder().decode(Flair.self, from: $0) }
        let uploadRecovery = uploadRecoveryData.flatMap { try? JSONDecoder().decode(Draft.UploadRecovery.self, from: $0) }
        return Draft(
            id: id,
            kind: kind,
            accountID: accountID,
            target: target,
            title: title,
            body: body,
            link: linkString.flatMap(URL.init(string:)),
            selectedFlair: flair,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            uploadRecovery: uploadRecovery
        )
    }
}

@Model
final class FavoriteCommunityRecord {
    @Attribute(.unique) var normalizedName: String
    var displayName: String
    var iconURLString: String?
    var manualPosition: Int
    var createdAt: Date

    init(normalizedName: String, displayName: String, iconURL: URL? = nil, manualPosition: Int = 0, createdAt: Date = .now) {
        self.normalizedName = IDNormalization.community(normalizedName)
        self.displayName = displayName
        iconURLString = iconURL?.absoluteString
        self.manualPosition = manualPosition
        self.createdAt = createdAt
    }
}

@Model
final class FilteredCommunityRecord {
    @Attribute(.unique) var normalizedName: String
    var createdAt: Date
    var expirationDate: Date?
    var sourcePostID: String?

    init(normalizedName: String, createdAt: Date = .now, expirationDate: Date? = nil, sourcePostID: String? = nil) {
        self.normalizedName = IDNormalization.community(normalizedName)
        self.createdAt = createdAt
        self.expirationDate = expirationDate
        self.sourcePostID = sourcePostID
    }
}

@Model
final class KeywordRuleRecord {
    @Attribute(.unique) var id: UUID
    var isEnabled: Bool
    var terms: String
    var fields: String
    var wholeWord: Bool
    var caseSensitive: Bool
    var createdAt: Date

    init(id: UUID = UUID(), isEnabled: Bool = true, terms: String = "", fields: String = "title,author,community,selfText,linkDescription", wholeWord: Bool = false, caseSensitive: Bool = false, createdAt: Date = .now) {
        self.id = id
        self.isEnabled = isEnabled
        self.terms = terms
        self.fields = fields
        self.wholeWord = wholeWord
        self.caseSensitive = caseSensitive
        self.createdAt = createdAt
    }
}

@Model
final class SemanticRuleRecord {
    @Attribute(.unique) var id: String
    var name: String
    var instruction: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    init(rule: SemanticRule) {
        id = rule.id
        name = rule.instruction.prefix(80).description
        instruction = rule.instruction
        isEnabled = true
        createdAt = .now
        updatedAt = .now
    }
}

@Model
final class FeedPreferenceRecord {
    @Attribute(.unique) var id: UUID
    var accountScopeKey: String
    var feedKey: String
    var sortRawValue: String
    var topTimeRawValue: String?
    var urlRewriteOverride: String?

    init(id: UUID = UUID(), accountScopeKey: String, feedKey: String, sort: PostSort, topTime: TopTime? = nil, urlRewriteOverride: String? = nil) {
        self.id = id
        self.accountScopeKey = accountScopeKey
        self.feedKey = feedKey
        sortRawValue = sort.rawValue
        topTimeRawValue = topTime?.rawValue
        self.urlRewriteOverride = urlRewriteOverride
    }
}

@Model
final class CustomThemeRecord {
    @Attribute(.unique) var id: UUID
    var name: String
    var tokenPayloadVersion: Int
    var lightTokenPayload: Data
    var darkTokenPayload: Data?
    var modifiedAt: Date

    init(id: UUID = UUID(), name: String, tokenPayloadVersion: Int = 1, lightTokenPayload: Data, darkTokenPayload: Data? = nil, modifiedAt: Date = .now) {
        self.id = id
        self.name = name
        self.tokenPayloadVersion = tokenPayloadVersion
        self.lightTokenPayload = lightTokenPayload
        self.darkTokenPayload = darkTokenPayload
        self.modifiedAt = modifiedAt
    }
}

@Model
final class StatisticRecord {
    @Attribute(.unique) var counterName: String
    var value: Int

    init(counterName: String, value: Int = 0) {
        self.counterName = counterName
        self.value = value
    }
}

@Model
final class CommunityVisitRecord {
    @Attribute(.unique) var normalizedCommunity: String
    var visitCount: Int

    init(normalizedCommunity: String, visitCount: Int = 0) {
        self.normalizedCommunity = IDNormalization.community(normalizedCommunity)
        self.visitCount = visitCount
    }
}

@Model
final class SummaryCacheRecord {
    @Attribute(.unique) var id: UUID
    var contentKind: String
    var contentID: String
    var inputHash: String
    var promptVersion: String
    var modelFamily: String?
    var generatedText: String
    var createdAt: Date
    var lastUsedAt: Date

    init(id: UUID = UUID(), contentKind: String, contentID: String, inputHash: String, promptVersion: String, modelFamily: String? = nil, generatedText: String, createdAt: Date = .now, lastUsedAt: Date = .now) {
        self.id = id
        self.contentKind = contentKind
        self.contentID = contentID
        self.inputHash = inputHash
        self.promptVersion = promptVersion
        self.modelFamily = modelFamily
        self.generatedText = generatedText
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }
}

@Model
final class HelpIndexRecord {
    @Attribute(.unique) var id: UUID
    var documentID: String
    var sectionID: String
    var title: String
    var normalizedText: String
    var bundleVersion: String
    var lexicalTerms: String

    init(id: UUID = UUID(), documentID: String, sectionID: String, title: String, normalizedText: String, bundleVersion: String, lexicalTerms: String = "") {
        self.id = id
        self.documentID = documentID
        self.sectionID = sectionID
        self.title = title
        self.normalizedText = normalizedText
        self.bundleVersion = bundleVersion
        self.lexicalTerms = lexicalTerms
    }
}

enum PersistenceSchema {
    @MainActor
    static func makeContainer(inMemory: Bool = false) throws -> ModelContainer {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        return try ModelContainer(
            for: AccountRecord.self,
            SeenPostRecord.self,
            DraftRecord.self,
            FavoriteCommunityRecord.self,
            FilteredCommunityRecord.self,
            KeywordRuleRecord.self,
            SemanticRuleRecord.self,
            FeedPreferenceRecord.self,
            CustomThemeRecord.self,
            StatisticRecord.self,
            CommunityVisitRecord.self,
            SummaryCacheRecord.self,
            HelpIndexRecord.self,
            configurations: configuration
        )
    }
}
