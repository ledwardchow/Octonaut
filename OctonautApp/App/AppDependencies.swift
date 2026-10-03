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
    let summaryCache = InMemorySummaryCache(lifetime: 24 * 60 * 60, capacity: 100)
    let summaryAPIKeyStore: any SummaryAPIKeyStore
    let links: any LinkRouter
    let settings: SettingsStore
    /// Why the on-device database could not be opened, when it could not.
    ///
    /// The app falls back to an in-memory store so it still runs, but that
    /// store forgets everything on quit. Silently, this is indistinguishable
    /// from working: posts mark as read, the count climbs, and the whole lot
    /// is gone next launch. Surfaced in Settings so it can be told apart
    /// from a bug in the seen record itself.
    let persistenceFailure: String?
    var summaryCacheModelFamily: String {
        switch settings.summaryProvider {
        case .onDevice: "on-device"
        case .openAICompatible: "\(settings.summaryEndpoint)|\(settings.summaryModel)"
        }
    }
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
        settings: SettingsStore,
        persistenceFailure: String? = nil
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
        self.persistenceFailure = persistenceFailure
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
        await summaryCache.removeAll()
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
        var persistenceFailure: String?
        do {
            persistence = SwiftDataPersistenceStore(container: try PersistenceSchema.makeContainer())
        } catch {
            // Keep running, but say so: everything written from here is lost
            // when the app quits.
            persistence = InMemoryPersistenceStore()
            persistenceFailure = error.localizedDescription
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
            settings: settings,
            persistenceFailure: persistenceFailure
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
