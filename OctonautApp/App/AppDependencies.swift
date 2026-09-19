import Foundation
import Observation

@MainActor
@Observable
final class AppDependencies {
    let router: AppRouter
    let accounts: AccountCoordinator
    let reddit: any RedditClient
    let authenticated: any AuthenticatedRedditService
    let persistence: any PersistenceStore
    let media: any MediaService
    let intelligence: any IntelligenceService
    let summaryAPIKeyStore: any SummaryAPIKeyStore
    let links: any LinkRouter
    let settings: SettingsStore
    private(set) var resetGeneration: UInt = 0

    init(
        router: AppRouter = AppRouter(),
        accounts: AccountCoordinator,
        reddit: any RedditClient,
        authenticated: any AuthenticatedRedditService,
        persistence: any PersistenceStore,
        media: any MediaService,
        intelligence: any IntelligenceService,
        summaryAPIKeyStore: any SummaryAPIKeyStore,
        links: any LinkRouter,
        settings: SettingsStore
    ) {
        self.router = router
        self.accounts = accounts
        self.reddit = reddit
        self.authenticated = authenticated
        self.persistence = persistence
        self.media = media
        self.intelligence = intelligence
        self.summaryAPIKeyStore = summaryAPIKeyStore
        self.links = links
        self.settings = settings
    }

    func resetAllData() async throws {
        var failedAreas: [String] = []

        do {
            try await accounts.removeAll()
        } catch {
            failedAreas.append("Reddit credentials")
        }
        do {
            try await summaryAPIKeyStore.removeAPIKey()
        } catch {
            failedAreas.append("summary API key")
        }
        do {
            try await persistence.removeAllData()
        } catch {
            failedAreas.append("saved app data")
        }

        settings.removeAllData()
        RedditResponseCache.removeAll()
        URLCache.shared.removeAllCachedResponses()
        await SubscribedCommunitiesCache.shared.removeAll()
        await UserProfileCache.shared.removeAll()
#if os(iOS)
        await OctonautImageCache.removeAll()
#endif
        await accounts.load()

        if !failedAreas.isEmpty {
            throw AppResetError(failedAreas: failedAreas)
        }
        resetGeneration &+= 1
    }

    static func live() -> AppDependencies {
        let persistence: any PersistenceStore
        if let container = try? PersistenceSchema.makeContainer() {
            persistence = SwiftDataPersistenceStore(container: container)
        } else {
            persistence = InMemoryPersistenceStore()
        }
        let vault = KeychainCredentialVault()
        let accounts = AccountCoordinator(persistence: persistence, secrets: CredentialVaultSecretStore(vault: vault))
        let reddit = URLSessionRedditClient(credentialVault: vault)
        let authenticated = LiveAuthenticatedRedditService(credentialVault: vault, reddit: reddit)
        let onDeviceIntelligence: any IntelligenceService
        if #available(iOS 27.0, macOS 26.0, *) {
            onDeviceIntelligence = AppleIntelligenceService()
        } else {
            onDeviceIntelligence = UnavailableIntelligenceService()
        }
        let settings = SettingsStore()
        settings.startCustomFeedSync()
        let summaryAPIKeyStore = KeychainSummaryAPIKeyStore()
        let intelligence: any IntelligenceService = ConfiguredIntelligenceService(
            onDevice: onDeviceIntelligence,
            apiKeyStore: summaryAPIKeyStore
        ) {
            (
                settings.summaryProvider,
                OpenAICompatibleSummaryConfiguration(
                    endpoint: settings.summaryEndpoint,
                    model: settings.summaryModel
                )
            )
        }
        let dependencies = AppDependencies(
            router: AppRouter(),
            accounts: accounts,
            reddit: reddit,
            authenticated: authenticated,
            persistence: persistence,
            media: AVFoundationMediaService(),
            intelligence: intelligence,
            summaryAPIKeyStore: summaryAPIKeyStore,
            links: DefaultLinkRouter(),
            settings: settings
        )
        Task {
            let modelAvailable = await intelligence.summaryAvailability == .available
            settings.applySummaryVisibilityDefaults(
                modelAvailable: modelAvailable || settings.summaryProvider == .openAICompatible
            )
        }
        return dependencies
    }

    static func preview() -> AppDependencies {
        let persistence = InMemoryPersistenceStore()
        let vault = InMemoryCredentialVault()
        let accounts = AccountCoordinator(persistence: persistence, secrets: CredentialVaultSecretStore(vault: vault))
        let reddit = FixtureRedditClient()
        let summaryAPIKeyStore = InMemorySummaryAPIKeyStore()
        return AppDependencies(
            router: AppRouter(),
            accounts: accounts,
            reddit: reddit,
            authenticated: FixtureAuthenticatedRedditService(),
            persistence: persistence,
            media: UnavailableMediaService(),
            intelligence: UnavailableIntelligenceService(),
            summaryAPIKeyStore: summaryAPIKeyStore,
            links: DefaultLinkRouter(),
            settings: SettingsStore(defaults: UserDefaults(suiteName: "com.ledwardchow.Octonaut.preview") ?? .standard)
        )
    }
}

struct AppResetError: LocalizedError, Equatable {
    let failedAreas: [String]

    var errorDescription: String? {
        "Octonaut could not remove: \(failedAreas.joined(separator: ", ")). Try the reset again."
    }
}
