import SwiftUI
import WebKit
import XCTest

@testable import Octonaut

final class LegalDocumentsTests: XCTestCase {
    @MainActor
    func testSpinnerClearsWhenDocumentCommitsBeforeLoadingFinishes() {
        var loading = true
        var failed = false
        let coordinator = LegalWebView.Coordinator(
            document: .redditRules,
            loading: Binding(get: { loading }, set: { loading = $0 }),
            failed: Binding(get: { failed }, set: { failed = $0 })
        )
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)

        // A readable document must clear the spinner without a didFinish event.
        coordinator.webView(webView, didCommit: nil)
        XCTAssertFalse(loading)
        XCTAssertFalse(failed)
    }

    func testFirstLoginRequiresConsentAndCurrentAcceptanceSkipsIt() {
        XCTAssertTrue(LegalDocuments.requiresConsent(acceptedVersion: ""))
        XCTAssertTrue(LegalDocuments.requiresConsent(acceptedVersion: "older-policy"))
        XCTAssertFalse(LegalDocuments.requiresConsent(acceptedVersion: LegalDocuments.consentVersion))
    }

    func testPrivacyPolicyIsBundled() throws {
        let policy = try XCTUnwrap(LegalDocuments.privacyPolicy())
        XCTAssertTrue(policy.contains("Octonaut Privacy Policy"))
        XCTAssertTrue(policy.contains("https://github.com/ledwardchow/Octonaut/issues"))
        XCTAssertTrue(policy.contains("OpenAI-compatible summary provider"))
    }

    func testMissingPolicyReturnsNil() {
        XCTAssertNil(LegalDocuments.privacyPolicy(in: Bundle(for: Self.self)))
    }

    func testRedditRulesUseOfficialSiteAndRejectUnrelatedDestinations() {
        XCTAssertEqual(LegalDocuments.redditRulesURL.absoluteString, "https://redditinc.com/policies/reddit-rules")
        XCTAssertTrue(LegalDocuments.allowsNavigation(LegalDocuments.redditRulesURL, for: .redditRules))
        XCTAssertTrue(LegalDocuments.allowsNavigation(URL(string: "https://www.redditinc.com/policies/reddit-rules"), for: .redditRules))
        for destination in ["http://redditinc.com/policies/reddit-rules", "https://redditinc.com.example.org/", "https://oauth.reddit.com/", "https://www.apple.com/"] {
            XCTAssertFalse(LegalDocuments.allowsNavigation(URL(string: destination), for: .redditRules))
        }
    }

    func testEULAUsesAppleStandardAgreement() {
        XCTAssertEqual(LegalDocuments.eulaURL.absoluteString, "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")
        XCTAssertTrue(LegalDocuments.allowsNavigation(LegalDocuments.eulaURL, for: .eula))
        for destination in [
            "http://www.apple.com/legal/",
            "https://www.apple.com.example.org/legal/",
            "https://www.reddit.com/login/",
            "file:///tmp/policy.html",
        ] {
            XCTAssertFalse(LegalDocuments.allowsNavigation(URL(string: destination), for: .eula))
        }
        XCTAssertFalse(LegalDocuments.allowsNavigation(nil, for: .eula))
    }
}
