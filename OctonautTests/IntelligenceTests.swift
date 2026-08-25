import XCTest
@testable import Octonaut

final class IntelligenceTests: XCTestCase {
    func testDeterministicFilterRemovesBlockedCommunitiesAndKeywords() {
        let result = DeterministicPostFilter.apply(
            FixtureData.posts,
            configuration: DeterministicFilterConfiguration(
                blockedCommunities: ["swift"],
                keywordRules: [KeywordFilterRule(terms: ["coast"], fields: [.title])]
            )
        )

        XCTAssertTrue(result.visible.isEmpty)
        XCTAssertEqual(result.removedCount, FixtureData.posts.count)
        XCTAssertEqual(result.reasons["Community"], 2)
        XCTAssertEqual(result.reasons["Keyword"], 1)
    }

    func testSeenFilterUsesStablePostIDs() {
        let result = DeterministicPostFilter.apply(
            FixtureData.posts,
            configuration: DeterministicFilterConfiguration(
                seenPostIDs: [FixtureData.posts[0].id],
                hideSeen: true
            )
        )

        XCTAssertFalse(result.visible.contains { $0.id == FixtureData.posts[0].id })
        XCTAssertEqual(result.reasons["Seen"], 1)
    }

    func testKeyExcerptsAreDeterministicAndOrdered() {
        let first = DeterministicExcerptEngine.excerpts(
            title: "SwiftUI updates",
            body: "First sentence explains the change. Second sentence gives the tradeoff. Third sentence describes the result."
        )
        let second = DeterministicExcerptEngine.excerpts(
            title: "SwiftUI updates",
            body: "First sentence explains the change. Second sentence gives the tradeoff. Third sentence describes the result."
        )

        XCTAssertEqual(first, second)
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(first.first, "First sentence explains the change.")
    }

    func testHelpIndexWorksWithoutNetwork() {
        let results = LocalHelpIndex().search("semantic filter")
        XCTAssertEqual(results.first?.section.id, "filters")
    }

    func testPostSummaryEligibilityHidesContentBelow850Scalars() {
        var shortPost = FixtureData.posts[0]
        shortPost.title = ""
        shortPost.body = RichText(plainText: String(repeating: "a", count: 848))
        XCTAssertFalse(SummaryEligibility.post(shortPost))

        shortPost.body = RichText(plainText: String(repeating: "a", count: 849))
        XCTAssertTrue(SummaryEligibility.post(shortPost))
    }

    @MainActor
    func testRemoteSummaryAvailabilityIsSeparateFromOnDeviceFeatures() async throws {
        let apiKeys = InMemorySummaryAPIKeyStore()
        let service = ConfiguredIntelligenceService(
            onDevice: UnavailableIntelligenceService(),
            apiKeyStore: apiKeys
        ) {
            (
                .openAICompatible,
                OpenAICompatibleSummaryConfiguration(
                    endpoint: "https://openrouter.ai/api/v1",
                    model: "openai/gpt-5.6-luna"
                )
            )
        }

        let onDeviceAvailability = await service.availability
        let missingKeyAvailability = await service.summaryAvailability
        XCTAssertEqual(onDeviceAvailability, .unsupported)
        XCTAssertEqual(missingKeyAvailability, .remoteAPIKeyMissing)

        try await apiKeys.saveAPIKey("test-key")
        let configuredAvailability = await service.summaryAvailability
        XCTAssertEqual(configuredAvailability, .available)
    }
}
