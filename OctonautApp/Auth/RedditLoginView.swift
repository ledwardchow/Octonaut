import SwiftUI
import WebKit
import Observation

enum RedditLoginState: Equatable {
    case loading
    case waitingForCookie
    case validating
    case succeeded(username: String)
    case failed(String)
    case cancelled
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
                    self.state = .failed((error as? LocalizedError)?.errorDescription ?? "Reddit login could not be completed.")
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
        return cookies.first { cookie in
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

struct RedditLoginView: View {
    let accounts: AccountCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var model: RedditLoginModel

    init(accounts: AccountCoordinator) {
        self.accounts = accounts
        _model = State(initialValue: RedditLoginModel(accounts: accounts))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if case .succeeded(let username) = model.state {
                    ContentUnavailableView("Signed in as u/\(username)", systemImage: "checkmark.circle.fill", description: Text("This Reddit session is saved securely on this device."))
                } else {
                    RedditLoginWebView(model: model)
                }
            }
            .overlay {
                if case .validating = model.state {
                    ProgressView("Checking Reddit account…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .navigationTitle("Sign in to Reddit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Octonaut signs in through Reddit's website and stores the resulting session only in this device's Keychain.")
                        .font(.footnote)
                    Link("Reddit Terms and Privacy", destination: URL(string: "https://www.reddit.com/policies/privacy-policy")!)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 9)
                .background(.bar)
            }
            .alert("Reddit sign-in failed", isPresented: Binding(get: {
                if case .failed = model.state { return true }
                return false
            }, set: { if !$0 { model.retryAfterFailure() } })) {
                Button("Try Again") { model.retryAfterFailure() }
                Button("Cancel", role: .cancel) {
                    model.cancel()
                    dismiss()
                }
            } message: {
                if case .failed(let message) = model.state { Text(message) }
            }
            .onChange(of: model.state) { _, state in
                if case .succeeded = state { dismiss() }
            }
            .onDisappear { model.cancel() }
        }
    }
}

private struct RedditLoginWebView: UIViewRepresentable {
    let model: RedditLoginModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.startMonitoring(webView)
        webView.load(URLRequest(url: Self.loginURL))
        model.didCreateWebView()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopMonitoring(webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private static let loginURL: URL = {
        var components = URLComponents(string: "https://www.reddit.com/login/")!
        components.queryItems = [
            URLQueryItem(name: "dest", value: "https://www.reddit.com/user/me/about.json?raw_json=1")
        ]
        return components.url!
    }()

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let model: RedditLoginModel
        weak var webView: WKWebView?
        var pollingTask: Task<Void, Never>?

        init(model: RedditLoginModel) { self.model = model }

        func startMonitoring(_ webView: WKWebView) {
            self.webView = webView
            webView.configuration.websiteDataStore.httpCookieStore.add(self)
            pollingTask?.cancel()
            pollingTask = Task { @MainActor [weak self, weak webView] in
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(for: .milliseconds(500))
                    } catch {
                        return
                    }
                    guard let self, let webView else { return }
                    self.model.cookiesDidChange(in: webView)
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
            model.cookiesDidChange(in: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            model.didFinishNavigation(webView)
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let host = navigationAction.request.url?.host?.lowercased(), host == "reddit.com" || host.hasSuffix(".reddit.com") else {
                return .cancel
            }
            return .allow
        }
    }
}
