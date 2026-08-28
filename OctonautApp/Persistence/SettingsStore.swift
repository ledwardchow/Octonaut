import Foundation
import Observation

enum FeedLayout: String, Codable, Hashable, Sendable, CaseIterable {
    case full
    case compact
}

enum CompactThumbnailSide: String, Codable, Hashable, Sendable, CaseIterable {
    case left
    case right
}

enum AutoplayVideo: String, Codable, Hashable, Sendable, CaseIterable {
    case never
    case wifi
    case always

    func shouldAutoplay(isConnectedViaWiFi: Bool) -> Bool {
        switch self {
        case .never:
            false
        case .wifi:
            isConnectedViaWiFi
        case .always:
            true
        }
    }
}

enum DataMode: String, Codable, Hashable, Sendable, CaseIterable {
    case normal
    case lowData
}

enum OpenExternalLinks: String, Codable, Hashable, Sendable, CaseIterable {
    case inAppSafari
    case defaultBrowser
}

enum RefreshVisibleFeedPolicy: String, Codable, Hashable, Sendable, CaseIterable {
    case always
    case ifStale
    case manual
}

enum SummaryProvider: String, Codable, Hashable, Sendable, CaseIterable {
    case openAICompatible
    case onDevice

    var title: String {
        switch self {
        case .openAICompatible: return "OpenAI-compatible"
        case .onDevice: return "On device"
        }
    }
}

enum MediaExportCleanup: String, Codable, Hashable, Sendable, CaseIterable {
    case afterSharing
    case oneHour
    case oneDay
    case sevenDays

    var interval: TimeInterval? {
        switch self {
        case .afterSharing: return nil
        case .oneHour: return 60 * 60
        case .oneDay: return 60 * 60 * 24
        case .sevenDays: return 60 * 60 * 24 * 7
        }
    }
}

enum ThemeChoice: Hashable, Codable, Sendable {
    case system
    case light
    case dark
    case midnight
    case discord
    case spotify
    case strawberry
    case spiderman
    case gilded
    case mulberry
    case deepOcean
    case aurora
    case royal
    case custom(UUID)

    var rawValue: String {
        switch self {
        case .system: return "system"
        case .light: return "light"
        case .dark: return "dark"
        case .midnight: return "midnight"
        case .discord: return "discord"
        case .spotify: return "spotify"
        case .strawberry: return "strawberry"
        case .spiderman: return "spiderman"
        case .gilded: return "gilded"
        case .mulberry: return "mulberry"
        case .deepOcean: return "deep-ocean"
        case .aurora: return "aurora"
        case .royal: return "royal"
        case .custom(let id): return "custom:\(id.uuidString)"
        }
    }

    init(rawValue: String) {
        switch rawValue {
        case "system": self = .system
        case "light": self = .light
        case "dark": self = .dark
        case "midnight": self = .midnight
        case "discord": self = .discord
        case "spotify": self = .spotify
        case "strawberry": self = .strawberry
        case "spiderman": self = .spiderman
        case "gilded": self = .gilded
        case "mulberry": self = .mulberry
        case "deep-ocean": self = .deepOcean
        case "aurora": self = .aurora
        case "royal": self = .royal
        default:
            if let value = rawValue.split(separator: ":").dropFirst().first.flatMap({ UUID(uuidString: String($0)) }) {
                self = .custom(value)
            } else {
                self = .system
            }
        }
    }
}

@MainActor
@Observable
final class SettingsStore {
    private let defaults: UserDefaults

    var feedLayout: FeedLayout { didSet { persist(feedLayout.rawValue, key: Keys.feedLayout) } }
    var compactThumbnailSide: CompactThumbnailSide { didSet { persist(compactThumbnailSide.rawValue, key: Keys.compactThumbnailSide) } }
    var useSplitViewOnIPad: Bool { didSet { persist(useSplitViewOnIPad, key: Keys.useSplitViewOnIPad) } }
    var showCommunityHeader: Bool { didSet { persist(showCommunityHeader, key: Keys.showCommunityHeader) } }
    var showCommunityIcons: Bool { didSet { persist(showCommunityIcons, key: Keys.showCommunityIcons) } }
    var selfTextPreviewLines: Int { didSet { selfTextPreviewLines = min(max(selfTextPreviewLines, 0), 20); persist(selfTextPreviewLines, key: Keys.selfTextPreviewLines) } }
    var linkDescriptionLines: Int { didSet { linkDescriptionLines = min(max(linkDescriptionLines, 0), 20); persist(linkDescriptionLines, key: Keys.linkDescriptionLines) } }
    var showPostFlair: Bool { didSet { persist(showPostFlair, key: Keys.showPostFlair) } }
    var blurSpoilers: Bool { didSet { persist(blurSpoilers, key: Keys.blurSpoilers) } }
    var blurNSFWMedia: Bool { didSet { persist(blurNSFWMedia, key: Keys.blurNSFWMedia) } }
    var showPostSummaries: Bool { didSet { persist(showPostSummaries, key: Keys.showPostSummaries) } }
    var showCommentSummaries: Bool { didSet { persist(showCommentSummaries, key: Keys.showCommentSummaries) } }
    var automaticVisibleSummaries: Bool { didSet { persist(automaticVisibleSummaries, key: Keys.automaticVisibleSummaries) } }
    var automaticCommentSummaries: Bool { didSet { persist(automaticCommentSummaries, key: Keys.automaticCommentSummaries) } }
    var keyExcerptsFallback: Bool { didSet { persist(keyExcerptsFallback, key: Keys.keyExcerptsFallback) } }
    var cacheSummaries: Bool { didSet { persist(cacheSummaries, key: Keys.cacheSummaries) } }
    var summaryProvider: SummaryProvider { didSet { persist(summaryProvider.rawValue, key: Keys.summaryProvider); configurationRevision &+= 1 } }
    var summaryEndpoint: String { didSet { persist(summaryEndpoint, key: Keys.summaryEndpoint); configurationRevision &+= 1 } }
    var summaryModel: String { didSet { persist(summaryModel, key: Keys.summaryModel); configurationRevision &+= 1 } }
    var autoplayVideo: AutoplayVideo { didSet { persist(autoplayVideo.rawValue, key: Keys.autoplayVideo) } }
    var enableLiveText: Bool { didSet { persist(enableLiveText, key: Keys.enableLiveText) } }

    var hideSeenPosts: Bool { didSet { persist(hideSeenPosts, key: Keys.hideSeenPosts); filterRevision &+= 1 } }
    var autoMarkSeenWhileScrolling: Bool { didSet { persist(autoMarkSeenWhileScrolling, key: Keys.autoMarkSeenWhileScrolling) } }
    var showFilterCount: Bool { didSet { persist(showFilterCount, key: Keys.showFilterCount) } }

    var wifiDataMode: DataMode { didSet { persist(wifiDataMode.rawValue, key: Keys.wifiDataMode); configurationRevision &+= 1 } }
    var cellularDataMode: DataMode { didSet { persist(cellularDataMode.rawValue, key: Keys.cellularDataMode); configurationRevision &+= 1 } }
    var respectSystemLowDataMode: Bool { didSet { persist(respectSystemLowDataMode, key: Keys.respectSystemLowDataMode); configurationRevision &+= 1 } }
    var respectLowPowerMode: Bool { didSet { persist(respectLowPowerMode, key: Keys.respectLowPowerMode); configurationRevision &+= 1 } }
    var imageCacheLimitMB: Int { didSet { persist(imageCacheLimitMB, key: Keys.imageCacheLimitMB); configurationRevision &+= 1 } }
    var mediaExportCleanup: MediaExportCleanup { didSet { persist(mediaExportCleanup.rawValue, key: Keys.mediaExportCleanup) } }

    var defaultPostSort: PostSort { didSet { persist(defaultPostSort.rawValue, key: Keys.defaultPostSort) } }
    var defaultTopTime: TopTime { didSet { persist(defaultTopTime.rawValue, key: Keys.defaultTopTime) } }
    var defaultCommentSort: CommentSort { didSet { persist(defaultCommentSort.rawValue, key: Keys.defaultCommentSort) } }
    var rememberSortPerCommunity: Bool { didSet { persist(rememberSortPerCommunity, key: Keys.rememberSortPerCommunity) } }
    var rememberSortPerMultireddit: Bool { didSet { persist(rememberSortPerMultireddit, key: Keys.rememberSortPerMultireddit) } }
    var rememberCommentSortPerCommunity: Bool { didSet { persist(rememberCommentSortPerCommunity, key: Keys.rememberCommentSortPerCommunity) } }

    var openExternalLinks: OpenExternalLinks { didSet { persist(openExternalLinks.rawValue, key: Keys.openExternalLinks) } }
    var preferReaderMode: Bool { didSet { persist(preferReaderMode, key: Keys.preferReaderMode) } }
    var openRedditLinksInOctonaut: Bool { didSet { persist(openRedditLinksInOctonaut, key: Keys.openRedditLinksInOctonaut) } }
    var detectCopiedRedditLinks: Bool { didSet { persist(detectCopiedRedditLinks, key: Keys.detectCopiedRedditLinks) } }

    var startupTab: AppTab { didSet { persist(startupTab.rawValue, key: Keys.startupTab) } }
    var startupPostsDestination: FeedDestination { didSet { persistCodable(startupPostsDestination, key: Keys.startupPostsDestination) } }
    var restoreLastScreen: Bool { didSet { persist(restoreLastScreen, key: Keys.restoreLastScreen) } }
    var refreshVisibleFeedOnLaunch: RefreshVisibleFeedPolicy { didSet { persist(refreshVisibleFeedOnLaunch.rawValue, key: Keys.refreshVisibleFeedOnLaunch) } }

    var confirmAccountSwitchWhileComposing: Bool { didSet { persist(confirmAccountSwitchWhileComposing, key: Keys.confirmAccountSwitchWhileComposing) } }
    var refreshAccountIdentityOnForegroundHours: Int { didSet { persist(refreshAccountIdentityOnForegroundHours, key: Keys.refreshAccountIdentityOnForegroundHours) } }
    var collectLocalUsageStatistics: Bool { didSet { persist(collectLocalUsageStatistics, key: Keys.collectLocalUsageStatistics) } }
    var theme: ThemeChoice { didSet { persist(theme.rawValue, key: Keys.theme) } }
    var pureBlackBackground: Bool { didSet { persist(pureBlackBackground, key: Keys.pureBlackBackground) } }
    var tintFollowsCommunity: Bool { didSet { persist(tintFollowsCommunity, key: Keys.tintFollowsCommunity) } }
    var gestureHaptics: Bool { didSet { persist(gestureHaptics, key: Keys.gestureHaptics) } }

    private(set) var configurationRevision: UInt = 0
    private(set) var filterRevision: UInt = 0

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        feedLayout = FeedLayout(rawValue: defaults.string(forKey: Keys.feedLayout) ?? "full") ?? .full
        compactThumbnailSide = CompactThumbnailSide(rawValue: defaults.string(forKey: Keys.compactThumbnailSide) ?? "left") ?? .left
        useSplitViewOnIPad = defaults.object(forKey: Keys.useSplitViewOnIPad) as? Bool ?? true
        showCommunityHeader = defaults.object(forKey: Keys.showCommunityHeader) as? Bool ?? true
        showCommunityIcons = defaults.object(forKey: Keys.showCommunityIcons) as? Bool ?? true
        selfTextPreviewLines = defaults.object(forKey: Keys.selfTextPreviewLines) as? Int ?? 3
        linkDescriptionLines = defaults.object(forKey: Keys.linkDescriptionLines) as? Int ?? 10
        showPostFlair = defaults.object(forKey: Keys.showPostFlair) as? Bool ?? true
        blurSpoilers = defaults.object(forKey: Keys.blurSpoilers) as? Bool ?? true
        blurNSFWMedia = defaults.object(forKey: Keys.blurNSFWMedia) as? Bool ?? true
        showPostSummaries = defaults.object(forKey: Keys.showPostSummaries) as? Bool ?? false
        showCommentSummaries = defaults.object(forKey: Keys.showCommentSummaries) as? Bool ?? false
        automaticVisibleSummaries = defaults.object(forKey: Keys.automaticVisibleSummaries) as? Bool ?? true
        automaticCommentSummaries = defaults.object(forKey: Keys.automaticCommentSummaries) as? Bool ?? false
        keyExcerptsFallback = defaults.object(forKey: Keys.keyExcerptsFallback) as? Bool ?? true
        cacheSummaries = defaults.object(forKey: Keys.cacheSummaries) as? Bool ?? true
        summaryProvider = SummaryProvider(rawValue: defaults.string(forKey: Keys.summaryProvider) ?? "openAICompatible") ?? .openAICompatible
        summaryEndpoint = defaults.string(forKey: Keys.summaryEndpoint) ?? "https://openrouter.ai/api/v1"
        summaryModel = defaults.string(forKey: Keys.summaryModel) ?? "openai/gpt-5.6-luna"
        autoplayVideo = AutoplayVideo(rawValue: defaults.string(forKey: Keys.autoplayVideo) ?? "wifi") ?? .wifi
        enableLiveText = defaults.object(forKey: Keys.enableLiveText) as? Bool ?? true
        hideSeenPosts = defaults.object(forKey: Keys.hideSeenPosts) as? Bool ?? false
        autoMarkSeenWhileScrolling = defaults.object(forKey: Keys.autoMarkSeenWhileScrolling) as? Bool ?? false
        showFilterCount = defaults.object(forKey: Keys.showFilterCount) as? Bool ?? true
        wifiDataMode = DataMode(rawValue: defaults.string(forKey: Keys.wifiDataMode) ?? "normal") ?? .normal
        cellularDataMode = DataMode(rawValue: defaults.string(forKey: Keys.cellularDataMode) ?? "normal") ?? .normal
        respectSystemLowDataMode = defaults.object(forKey: Keys.respectSystemLowDataMode) as? Bool ?? true
        respectLowPowerMode = defaults.object(forKey: Keys.respectLowPowerMode) as? Bool ?? true
        imageCacheLimitMB = defaults.object(forKey: Keys.imageCacheLimitMB) as? Int ?? 500
        mediaExportCleanup = MediaExportCleanup(rawValue: defaults.string(forKey: Keys.mediaExportCleanup) ?? "oneDay") ?? .oneDay
        defaultPostSort = PostSort(rawValue: defaults.string(forKey: Keys.defaultPostSort) ?? "default")
        defaultTopTime = TopTime(rawValue: defaults.string(forKey: Keys.defaultTopTime) ?? "day") ?? .day
        defaultCommentSort = CommentSort(rawValue: defaults.string(forKey: Keys.defaultCommentSort) ?? "best")
        rememberSortPerCommunity = defaults.object(forKey: Keys.rememberSortPerCommunity) as? Bool ?? false
        rememberSortPerMultireddit = defaults.object(forKey: Keys.rememberSortPerMultireddit) as? Bool ?? false
        rememberCommentSortPerCommunity = defaults.object(forKey: Keys.rememberCommentSortPerCommunity) as? Bool ?? false
        openExternalLinks = OpenExternalLinks(rawValue: defaults.string(forKey: Keys.openExternalLinks) ?? "inAppSafari") ?? .inAppSafari
        preferReaderMode = defaults.object(forKey: Keys.preferReaderMode) as? Bool ?? false
        openRedditLinksInOctonaut = defaults.object(forKey: Keys.openRedditLinksInOctonaut) as? Bool ?? true
        detectCopiedRedditLinks = defaults.object(forKey: Keys.detectCopiedRedditLinks) as? Bool ?? false
        startupTab = AppTab(rawValue: defaults.string(forKey: Keys.startupTab) ?? "posts") ?? .posts
        startupPostsDestination = defaults.data(forKey: Keys.startupPostsDestination).flatMap { try? JSONDecoder().decode(FeedDestination.self, from: $0) } ?? .home
        restoreLastScreen = defaults.object(forKey: Keys.restoreLastScreen) as? Bool ?? false
        refreshVisibleFeedOnLaunch = RefreshVisibleFeedPolicy(rawValue: defaults.string(forKey: Keys.refreshVisibleFeedOnLaunch) ?? "ifStale") ?? .ifStale
        confirmAccountSwitchWhileComposing = defaults.object(forKey: Keys.confirmAccountSwitchWhileComposing) as? Bool ?? true
        refreshAccountIdentityOnForegroundHours = defaults.object(forKey: Keys.refreshAccountIdentityOnForegroundHours) as? Int ?? 24
        collectLocalUsageStatistics = defaults.object(forKey: Keys.collectLocalUsageStatistics) as? Bool ?? true
        theme = ThemeChoice(rawValue: defaults.string(forKey: Keys.theme) ?? "system")
        pureBlackBackground = defaults.object(forKey: Keys.pureBlackBackground) as? Bool ?? false
        tintFollowsCommunity = defaults.object(forKey: Keys.tintFollowsCommunity) as? Bool ?? false
        gestureHaptics = defaults.object(forKey: Keys.gestureHaptics) as? Bool ?? true
    }

    func resetToDefaults() {
        let cleanDefaults = UserDefaults(suiteName: "com.ledwardchow.Octonaut.defaults-reset") ?? UserDefaults.standard
        cleanDefaults.removePersistentDomain(forName: "com.ledwardchow.Octonaut.defaults-reset")
        let fresh = SettingsStore(defaults: cleanDefaults)
        feedLayout = fresh.feedLayout
        compactThumbnailSide = fresh.compactThumbnailSide
        useSplitViewOnIPad = fresh.useSplitViewOnIPad
        showCommunityHeader = fresh.showCommunityHeader
        showCommunityIcons = fresh.showCommunityIcons
        selfTextPreviewLines = fresh.selfTextPreviewLines
        linkDescriptionLines = fresh.linkDescriptionLines
        showPostFlair = fresh.showPostFlair
        blurSpoilers = fresh.blurSpoilers
        blurNSFWMedia = fresh.blurNSFWMedia
        showPostSummaries = fresh.showPostSummaries
        showCommentSummaries = fresh.showCommentSummaries
        automaticVisibleSummaries = fresh.automaticVisibleSummaries
        automaticCommentSummaries = fresh.automaticCommentSummaries
        keyExcerptsFallback = fresh.keyExcerptsFallback
        cacheSummaries = fresh.cacheSummaries
        summaryProvider = fresh.summaryProvider
        summaryEndpoint = fresh.summaryEndpoint
        summaryModel = fresh.summaryModel
        autoplayVideo = fresh.autoplayVideo
        enableLiveText = fresh.enableLiveText
        hideSeenPosts = fresh.hideSeenPosts
        autoMarkSeenWhileScrolling = fresh.autoMarkSeenWhileScrolling
        showFilterCount = fresh.showFilterCount
        wifiDataMode = fresh.wifiDataMode
        cellularDataMode = fresh.cellularDataMode
        respectSystemLowDataMode = fresh.respectSystemLowDataMode
        respectLowPowerMode = fresh.respectLowPowerMode
        imageCacheLimitMB = fresh.imageCacheLimitMB
        mediaExportCleanup = fresh.mediaExportCleanup
        defaultPostSort = fresh.defaultPostSort
        defaultTopTime = fresh.defaultTopTime
        defaultCommentSort = fresh.defaultCommentSort
        rememberSortPerCommunity = fresh.rememberSortPerCommunity
        rememberSortPerMultireddit = fresh.rememberSortPerMultireddit
        rememberCommentSortPerCommunity = fresh.rememberCommentSortPerCommunity
        openExternalLinks = fresh.openExternalLinks
        preferReaderMode = fresh.preferReaderMode
        openRedditLinksInOctonaut = fresh.openRedditLinksInOctonaut
        detectCopiedRedditLinks = fresh.detectCopiedRedditLinks
        startupTab = fresh.startupTab
        startupPostsDestination = fresh.startupPostsDestination
        restoreLastScreen = fresh.restoreLastScreen
        refreshVisibleFeedOnLaunch = fresh.refreshVisibleFeedOnLaunch
        confirmAccountSwitchWhileComposing = fresh.confirmAccountSwitchWhileComposing
        refreshAccountIdentityOnForegroundHours = fresh.refreshAccountIdentityOnForegroundHours
        collectLocalUsageStatistics = fresh.collectLocalUsageStatistics
        theme = fresh.theme
        pureBlackBackground = fresh.pureBlackBackground
        tintFollowsCommunity = fresh.tintFollowsCommunity
        gestureHaptics = fresh.gestureHaptics
        configurationRevision = 0
        filterRevision = 0
    }

    /// Applies availability-based defaults only when the user has not already
    /// chosen whether summary cards should be shown.
    func applySummaryVisibilityDefaults(modelAvailable: Bool) {
        if defaults.object(forKey: Keys.showPostSummaries) == nil {
            showPostSummaries = modelAvailable
        }
        if defaults.object(forKey: Keys.showCommentSummaries) == nil {
            showCommentSummaries = modelAvailable
        }
    }

    private func persist(_ value: Any, key: String) { defaults.set(value, forKey: key) }
    private func persistCodable<T: Encodable>(_ value: T, key: String) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }

    private enum Keys {
        static let feedLayout = "appearance.feedLayout"
        static let compactThumbnailSide = "appearance.compactThumbnailSide"
        static let useSplitViewOnIPad = "appearance.useSplitViewOnIPad"
        static let showCommunityHeader = "appearance.showCommunityHeader"
        static let showCommunityIcons = "appearance.showCommunityIcons"
        static let selfTextPreviewLines = "appearance.selfTextPreviewLines"
        static let linkDescriptionLines = "appearance.linkDescriptionLines"
        static let showPostFlair = "appearance.showPostFlair"
        static let blurSpoilers = "appearance.blurSpoilers"
        static let blurNSFWMedia = "appearance.blurNSFWMedia"
        static let showPostSummaries = "appearance.showPostSummaries"
        static let showCommentSummaries = "appearance.showCommentSummaries"
        static let automaticVisibleSummaries = "intelligence.automaticVisibleSummaries"
        static let automaticCommentSummaries = "intelligence.automaticCommentSummaries"
        static let keyExcerptsFallback = "intelligence.keyExcerptsFallback"
        static let cacheSummaries = "intelligence.cacheSummaries"
        static let summaryProvider = "intelligence.summaryProvider"
        static let summaryEndpoint = "intelligence.summaryEndpoint"
        static let summaryModel = "intelligence.summaryModel"
        static let autoplayVideo = "appearance.autoplayVideo"
        static let enableLiveText = "appearance.enableLiveText"
        static let hideSeenPosts = "filters.hideSeenPosts"
        static let autoMarkSeenWhileScrolling = "filters.autoMarkSeenWhileScrolling"
        static let showFilterCount = "filters.showFilterCount"
        static let wifiDataMode = "data.wifiMode"
        static let cellularDataMode = "data.cellularMode"
        static let respectSystemLowDataMode = "data.respectSystemLowDataMode"
        static let respectLowPowerMode = "data.respectLowPowerMode"
        static let imageCacheLimitMB = "data.imageCacheLimitMB"
        static let mediaExportCleanup = "data.mediaExportCleanup"
        static let defaultPostSort = "sorting.defaultPostSort"
        static let defaultTopTime = "sorting.defaultTopTime"
        static let defaultCommentSort = "sorting.defaultCommentSort"
        static let rememberSortPerCommunity = "sorting.rememberSortPerCommunity"
        static let rememberSortPerMultireddit = "sorting.rememberSortPerMultireddit"
        static let rememberCommentSortPerCommunity = "sorting.rememberCommentSortPerCommunity"
        static let openExternalLinks = "links.openExternalLinks"
        static let preferReaderMode = "links.preferReaderMode"
        static let openRedditLinksInOctonaut = "links.openRedditLinksInOctonaut"
        static let detectCopiedRedditLinks = "links.detectCopiedRedditLinks"
        static let startupTab = "startup.tab"
        static let startupPostsDestination = "startup.postsDestination"
        static let restoreLastScreen = "startup.restoreLastScreen"
        static let refreshVisibleFeedOnLaunch = "startup.refreshVisibleFeedOnLaunch"
        static let confirmAccountSwitchWhileComposing = "accounts.confirmSwitchWhileComposing"
        static let refreshAccountIdentityOnForegroundHours = "accounts.refreshIdentityHours"
        static let collectLocalUsageStatistics = "privacy.collectLocalUsageStatistics"
        static let theme = "theme.choice"
        static let pureBlackBackground = "theme.pureBlackBackground"
        static let tintFollowsCommunity = "theme.tintFollowsCommunity"
        static let gestureHaptics = "gestures.haptics"
    }
}
