import Foundation
import Observation
import WebKit

enum RedditLoginState: Equatable {
    case loading
    case waitingForCookie
    case validating
    case succeeded(username: String)
    case failed(String)
    case cancelled
}

enum RedditLoginNavigationPolicy {
    private static let embeddedFramePaths: [String: [String]] = [
        "accounts.google.com": ["/gsi/"],
        "recaptcha.google.com": ["/recaptcha/"],
        "www.google.com": ["/recaptcha/"],
    ]

    static func allows(_ url: URL?, isMainFrame: Bool?) -> Bool {
        guard let url else { return false }

        if isMainFrame == false,
           url.scheme?.lowercased() == "about",
           url.absoluteString == "about:blank" {
            return true
        }

        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased() else {
            return false
        }
        if host == "reddit.com" || host.hasSuffix(".reddit.com") {
            return true
        }

        guard isMainFrame == false,
              let allowedPaths = embeddedFramePaths[host] else {
            return false
        }
        return allowedPaths.contains { url.path.hasPrefix($0) }
    }
}

@MainActor
@Observable
final class RedditLoginModel {
    private let accounts: AccountCoordinator
    private let validator: RedditSessionValidator
    private(set) var state: RedditLoginState = .loading
    private(set) var attemptID = UUID()
    @ObservationIgnored private var isFinishing = false
    @ObservationIgnored private var isCheckingSession = false

    init(accounts: AccountCoordinator, validator: RedditSessionValidator = RedditSessionValidator()) {
        self.accounts = accounts
        self.validator = validator
    }

    func didCreateWebView() {
        guard state == .loading else { return }
        state = .waitingForCookie
    }

    func didFinishNavigation(_ webView: WKWebView) {
        checkForSession(in: webView)
    }

    func cookiesDidChange(in webView: WKWebView) {
        checkForSession(in: webView)
    }

    func retryAfterFailure() {
        guard case .failed = state else { return }
        state = .waitingForCookie
    }

    private func checkForSession(in webView: WKWebView) {
        guard !isFinishing, !isCheckingSession else { return }
        isCheckingSession = true
        let attempt = attemptID
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self, weak webView] cookies in
            guard let self, let webView else { return }
            Task { @MainActor in
                defer { self.isCheckingSession = false }
                guard self.attemptID == attempt, !self.isFinishing else { return }
                guard let cookie = Self.sessionCookie(from: cookies) else {
                    self.state = .waitingForCookie
                    return
                }
                self.state = .validating
                do {
                    let companionCookies = Dictionary(
                        cookies.compactMap { candidate -> (String, String)? in
                            guard Self.isRedditCookie(candidate) else { return nil }
                            return (candidate.name, candidate.value)
                        },
                        uniquingKeysWith: { _, newest in newest }
                    )
                    let identity = try await self.validator.validate(
                        cookieName: cookie.name,
                        cookieValue: cookie.value,
                        companionCookies: companionCookies
                    )
                    guard self.attemptID == attempt else { return }
                    let account = Account(
                        username: identity.username,
                        createdAt: .now,
                        lastUsedAt: .now,
                        lastValidatedAt: .now,
                        health: .healthy,
                        transport: .webSession
                    )
                    let secret = SessionSecret(
                        cookieName: cookie.name,
                        cookieValue: cookie.value,
                        modhash: identity.modhash,
                        redditUser: identity.username,
                        validatedAt: .now
                    )
                    self.isFinishing = true
                    try await self.accounts.add(account, secret: secret)
                    self.state = .succeeded(username: identity.username)
                    _ = webView
                } catch is CancellationError {
                    return
                } catch {
                    self.state = .failed(
                        (error as? LocalizedError)?.errorDescription
                            ?? "Reddit login could not be completed."
                    )
                }
            }
        }
    }

    func cancel() {
        attemptID = UUID()
        isFinishing = true
        state = .cancelled
    }

    static func sessionCookie(from cookies: [HTTPCookie]) -> HTTPCookie? {
        cookies.first { cookie in
            cookie.name == "reddit_session" && isRedditCookie(cookie)
        }
    }

    private static func isRedditCookie(_ cookie: HTTPCookie) -> Bool {
        let domain = cookie.domain
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return domain == "reddit.com" || domain.hasSuffix(".reddit.com")
    }
}
