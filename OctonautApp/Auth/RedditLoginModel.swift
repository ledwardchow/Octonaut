import Foundation
import Observation
import WebKit
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

enum RedditLoginState: Equatable {
    case loading
    case waitingForCookie
    case validating
    case succeeded(username: String)
    case failed(String)
    case cancelled
}

enum RedditLoginNavigationPolicy {
    enum Route: Equatable {
        case embedded
        case browser(URL)
        case cancel
    }

    private static let embeddedFramePaths: [String: [String]] = [
        "accounts.google.com": ["/gsi/"],
        "recaptcha.google.com": ["/recaptcha/"],
        "www.google.com": ["/recaptcha/"],
    ]

    static func route(_ request: URLRequest, sourceURL: URL?, sourceIsMainFrame: Bool, isMainFrame: Bool?, isLinkOrNewWindow: Bool) -> Route {
        guard let url = request.url else { return .cancel }

        if isMainFrame == false,
           url.scheme?.lowercased() == "about",
           url.absoluteString == "about:blank" {
            return .embedded
        }

        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil else {
            return .cancel
        }

        guard host != "oauth.reddit.com" else { return .cancel }
        let isReddit = host == "reddit.com" || host.hasSuffix(".reddit.com")
        if isMainFrame != false, sourceIsMainFrame, isLinkOrNewWindow,
           request.httpMethod?.uppercased() == "GET", request.httpBody == nil,
           request.httpBodyStream == nil, isTrustedRedditSource(sourceURL),
           isBrowserDestination(url, host: host) {
            return .browser(url)
        }
        if isReddit {
            let path = url.path.lowercased()
            if isMainFrame != false,
               ["/password", "/username", "/register"].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                return .cancel
            }
            if isMainFrame != false,
               (path.hasPrefix("/api/v1/authorize") || path.hasPrefix("/oauth")
                || path.hasPrefix("/login/google") || path.hasPrefix("/login/apple")
                || path.hasPrefix("/account/sso")) {
                return .cancel
            }
            if isMainFrame == true, sourceIsMainFrame, isTrustedRedditSource(sourceURL),
               let sourcePath = sourceURL?.path.lowercased(),
               (sourcePath == "/login" || sourcePath.hasPrefix("/login/")
                || sourcePath == "/account/login" || sourcePath.hasPrefix("/account/login/")),
               path == "/" {
                return .cancel
            }
            return isMainFrame == nil ? .cancel : .embedded
        }

        guard isMainFrame == false,
              let allowedPaths = embeddedFramePaths[host] else {
            return .cancel
        }
        return allowedPaths.contains { url.path.hasPrefix($0) } ? .embedded : .cancel
    }

    private static func isTrustedRedditSource(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return host != "oauth.reddit.com" && (host == "reddit.com" || host.hasSuffix(".reddit.com"))
    }

    private static func isBrowserDestination(_ url: URL, host: String) -> Bool {
        guard url.fragment == nil, url.port == nil || url.port == 443 else { return false }
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let secretKeys = ["token", "session", "code", "auth", "password", "secret", "modhash", "cookie", "email", "username", "otp"]
        let redirectKeys = ["dest", "redirect", "next", "url", "return", "continue"]
        guard !query.contains(where: { item in
            let key = item.name.lowercased()
            let value = item.value?.lowercased() ?? ""
            return redirectKeys.contains(key) || secretKeys.contains { key.contains($0) || value.contains($0) }
        }) else { return false }
        let path = url.path.lowercased()
        if ["reddithelp.com", "www.reddithelp.com", "support.reddithelp.com"].contains(host) {
            return path == "/hc" || path.hasPrefix("/hc/")
        }
        if ["redditinc.com", "www.redditinc.com"].contains(host) {
            return path == "/policies" || path.hasPrefix("/policies/")
        }
        guard host == "reddit.com" || host.hasSuffix(".reddit.com") else { return false }
        return ["/password", "/username", "/register", "/help", "/policies", "/r/help"].contains {
            path == $0 || path.hasPrefix($0 + "/")
        }
    }
}

@MainActor
final class RedditLoginWebCoordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    private let model: RedditLoginModel?
    private let openBrowser: (URL) -> Void
    private weak var webView: WKWebView?
    private var pollingTask: Task<Void, Never>?

    init(model: RedditLoginModel? = nil, openBrowser: @escaping (URL) -> Void = { url in
        #if os(iOS)
        UIApplication.shared.open(url)
        #elseif os(macOS)
        NSWorkspace.shared.open(url)
        #endif
    }) {
        self.model = model
        self.openBrowser = openBrowser
    }

    func startMonitoring(_ webView: WKWebView) {
        self.webView = webView
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
        guard model != nil else { return }
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self, weak webView] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(500)) }
                catch { return }
                guard let self, let webView else { return }
                self.model?.cookiesDidChange(in: webView)
            }
        }
    }

    func stopMonitoring(_ webView: WKWebView) {
        pollingTask?.cancel()
        pollingTask = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        self.webView = nil
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        guard let webView else { return }
        model?.cookiesDidChange(in: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        model?.didFinishNavigation(webView)
    }

    private func sourceURL(for action: WKNavigationAction) -> URL? {
        if let url = action.sourceFrame.request.url, url.scheme?.lowercased() == "https" { return url }
        let origin = action.sourceFrame.securityOrigin
        guard origin.protocol.lowercased() == "https" else { return nil }
        return URL(string: "https://\(origin.host)/")
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        let route = RedditLoginNavigationPolicy.route(
            action.request,
            sourceURL: sourceURL(for: action),
            sourceIsMainFrame: action.sourceFrame.isMainFrame,
            isMainFrame: action.targetFrame?.isMainFrame,
            isLinkOrNewWindow: action.navigationType == .linkActivated || action.targetFrame == nil
        )
        switch route {
        case .embedded: return .allow
        case .cancel: return .cancel
        case .browser(let url):
            if action.targetFrame == nil { return .allow }
            openBrowser(url)
            return .cancel
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard action.targetFrame == nil else { return nil }
        if case .browser(let url) = RedditLoginNavigationPolicy.route(
            action.request,
            sourceURL: sourceURL(for: action),
            sourceIsMainFrame: action.sourceFrame.isMainFrame,
            isMainFrame: nil,
            isLinkOrNewWindow: action.navigationType == .linkActivated || action.targetFrame == nil
        ) {
            openBrowser(url)
        }
        return nil
    }
}

enum RedditLoginPageCustomization {
    case usernameAndPasswordOnly

    @MainActor
    func install(on configuration: WKWebViewConfiguration) {
        configuration.userContentController.addUserScript(
            WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        )
    }

    private var source: String {
        switch self {
        case .usernameAndPasswordOnly:
            return #"""
            (() => {
                if (location.protocol !== 'https:' ||
                    !(location.hostname === 'reddit.com' || location.hostname.endsWith('.reddit.com')) ||
                    window !== window.top) return;

                const css = `:is(
                    div:has(> div > auth-flow-sso-buttons[auth-flow="login"]),
                    auth-flow-sso-buttons[auth-flow="login"],
                    auth-flow-link[step="phone_auth"],
                    auth-flow-link[step="magic_link_login"],
                    div:has(> auth-flow-link[step="password"]),
                    auth-flow-link[step="password"]:has(faceplate-tracker[noun="forgot_password"]),
                    div:has(> auth-flow-link[step="register"]),
                    auth-flow-link[step="register"],
                    a[href="/password"],
                    a[href="/password/"],
                    a[href="https://www.reddit.com/password"],
                    a[href="https://www.reddit.com/password/"],
                    a[href="/register"],
                    a[href="/register/"],
                    a[href="https://www.reddit.com/register"],
                    a[href="https://www.reddit.com/register/"],
                    button[aria-label="Close" i],
                    button[aria-label="Close dialog" i],
                    a[aria-label="Close" i],
                    [slot="close-button"],
                    #login-close-button,
                    button:has(svg[icon-name="close"]),
                    button:has(svg[icon-name="close-outline"]),
                    a:has(svg[icon-name="close"]),
                    a:has(svg[icon-name="close-outline"]),
                    button:has(faceplate-icon[name="close"]),
                    #google-sso-button-container,
                    #apple-sso-button-container) { display: none !important; }
                `;
                const observed = new WeakSet();
                const styled = new WeakMap();

                function scan(root) {
                    if (!observed.has(root)) {
                        observed.add(root);
                        new MutationObserver(mutations => {
                            for (const mutation of mutations) {
                                for (const node of mutation.addedNodes) {
                                    if (node.nodeType === Node.ELEMENT_NODE) scanNode(node);
                                }
                            }
                            addStyle(root);
                        }).observe(root, { childList: true, subtree: true });
                    }
                    addStyle(root);
                    for (const element of root.querySelectorAll('*')) {
                        if (element.shadowRoot) scan(element.shadowRoot);
                    }
                }

                function addStyle(root) {
                    const existingStyle = styled.get(root);
                    if (existingStyle && existingStyle.getRootNode() === root) return;
                    const parent = root === document ? (document.head || document.documentElement) : root;
                    if (!parent) return;
                    const style = document.createElement('style');
                    style.textContent = css;
                    parent.appendChild(style);
                    styled.set(root, style);
                }

                function scanNode(node) {
                    if (node.shadowRoot) scan(node.shadowRoot);
                    for (const element of node.querySelectorAll('*')) {
                        if (element.shadowRoot) scan(element.shadowRoot);
                    }
                }

                scan(document);
                customElements.whenDefined('auth-flow-sso-buttons').then(() => scan(document));
            })();
            """#
        }
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
        // After a failure, wait for the user to choose Try Again instead of
        // re-validating the same cookie on every 0.5 s poll.
        if case .failed = state { return }
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
                    guard self.attemptID == attempt else { return }
                    // Saving can fail (for example a Keychain error); let Try Again run again.
                    self.isFinishing = false
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
