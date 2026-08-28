import XCTest
@testable import Octonaut

@MainActor
final class SettingsTests: XCTestCase {
    func testDefaultsMatchTheReleaseOneBaseline() {
        let defaults = UserDefaults(suiteName: "OctonautTests.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertEqual(settings.feedLayout, .full)
        XCTAssertEqual(settings.defaultPostSort.rawValue, "default")
        XCTAssertEqual(settings.defaultTopTime, .day)
        XCTAssertTrue(settings.openRedditLinksInOctonaut)
        XCTAssertTrue(settings.collectLocalUsageStatistics)
        XCTAssertEqual(settings.summaryProvider, .openAICompatible)
        XCTAssertEqual(settings.summaryEndpoint, "https://openrouter.ai/api/v1")
        XCTAssertEqual(settings.summaryModel, "openai/gpt-5.6-luna")
        XCTAssertFalse(settings.keyExcerptsFallback)
    }

    func testChangingFilterIncrementsFilterRevision() {
        let defaults = UserDefaults(suiteName: "OctonautTests.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        let before = settings.filterRevision
        settings.hideSeenPosts.toggle()
        XCTAssertEqual(settings.filterRevision, before &+ 1)
    }

    func testThemeRoundTripsThroughDefaults() {
        let suite = "OctonautTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        settings.theme = .deepOcean
        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reloaded.theme, .deepOcean)
    }

    func testAutomaticCommentSummaryRoundTripsThroughDefaults() {
        let suite = "OctonautTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(settings.automaticCommentSummaries)
        settings.automaticCommentSummaries = true

        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertTrue(reloaded.automaticCommentSummaries)
    }

    func testAvailableModelEnablesSummaryCardsWhenUserHasNotChosen() {
        let defaults = UserDefaults(suiteName: "OctonautTests.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)

        settings.applySummaryVisibilityDefaults(modelAvailable: true)

        XCTAssertTrue(settings.showPostSummaries)
        XCTAssertTrue(settings.showCommentSummaries)
    }

    func testAvailabilityDefaultPreservesExplicitSummaryChoices() {
        let defaults = UserDefaults(suiteName: "OctonautTests.\(UUID())")!
        let settings = SettingsStore(defaults: defaults)
        settings.showPostSummaries = false
        settings.showCommentSummaries = false

        settings.applySummaryVisibilityDefaults(modelAvailable: true)

        XCTAssertFalse(settings.showPostSummaries)
        XCTAssertFalse(settings.showCommentSummaries)
    }

    func testSummaryProviderSettingsRoundTripThroughDefaults() {
        let suite = "OctonautTests.\(UUID())"
        let settings = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        settings.summaryProvider = .onDevice
        settings.summaryEndpoint = "https://example.test/v1"
        settings.summaryModel = "summary-model"

        let reloaded = SettingsStore(defaults: UserDefaults(suiteName: suite)!)
        XCTAssertEqual(reloaded.summaryProvider, .onDevice)
        XCTAssertEqual(reloaded.summaryEndpoint, "https://example.test/v1")
        XCTAssertEqual(reloaded.summaryModel, "summary-model")
    }

    func testOpenAICompatibleEndpointAddsChatCompletionsPath() {
        let configuration = OpenAICompatibleSummaryConfiguration(
            endpoint: "https://openrouter.ai/api/v1/",
            model: "openai/gpt-5.6-luna"
        )

        XCTAssertEqual(
            configuration.chatCompletionsURL?.absoluteString,
            "https://openrouter.ai/api/v1/chat/completions"
        )
        XCTAssertTrue(configuration.isValid)
    }

    func testOpenRouterRequestsIdentifyOctonaut() throws {
        let configuration = OpenAICompatibleSummaryConfiguration(
            endpoint: "https://openrouter.ai/api/v1",
            model: "openai/gpt-5.6-luna"
        )
        var request = URLRequest(url: try XCTUnwrap(configuration.chatCompletionsURL))

        configuration.addOpenRouterAttributionHeaders(to: &request)

        XCTAssertEqual(
            request.value(forHTTPHeaderField: "HTTP-Referer"),
            "https://github.com/ledwardchow/octonaut"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-OpenRouter-Title"), "Octonaut")
    }

    func testOtherProvidersDoNotReceiveOpenRouterIdentification() throws {
        let configuration = OpenAICompatibleSummaryConfiguration(
            endpoint: "https://example.test/v1",
            model: "summary-model"
        )
        var request = URLRequest(url: try XCTUnwrap(configuration.chatCompletionsURL))

        configuration.addOpenRouterAttributionHeaders(to: &request)

        XCTAssertNil(request.value(forHTTPHeaderField: "HTTP-Referer"))
        XCTAssertNil(request.value(forHTTPHeaderField: "X-OpenRouter-Title"))
    }
}
