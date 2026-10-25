import SwiftUI
import WebKit

@MainActor
struct MacRedditLoginView: View {
    let anonymousRequestsBlocked: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LegalDocuments.acceptedVersionKey) private var acceptedConsentVersion = ""
    @State private var model: RedditLoginModel
    @State private var hasStartedSignIn = false

    init(accounts: AccountCoordinator, anonymousRequestsBlocked: Bool = false) {
        self.anonymousRequestsBlocked = anonymousRequestsBlocked
        _model = State(initialValue: RedditLoginModel(accounts: accounts))
    }

    private var showingWebLogin: Bool {
        guard hasStartedSignIn,
              !LegalDocuments.requiresConsent(acceptedVersion: acceptedConsentVersion) else { return false }
        if case .succeeded = model.state { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            if !hasStartedSignIn {
                RedditLoginWelcomeView(anonymousRequestsBlocked: anonymousRequestsBlocked, onSignIn: { hasStartedSignIn = true }) {
                    model.cancel()
                    dismiss()
                }
            } else {
                HStack {
                    Text(LegalDocuments.requiresConsent(acceptedVersion: acceptedConsentVersion) ? "Privacy and Terms" : "Sign in to Reddit")
                        .font(.headline)
                    Spacer()
                    Button("Cancel") {
                        model.cancel()
                        dismiss()
                    }
                }
                .padding()

                Divider()

                if LegalDocuments.requiresConsent(acceptedVersion: acceptedConsentVersion) {
                    LoginConsentView { acceptedConsentVersion = LegalDocuments.consentVersion }
                } else if case .succeeded(let username) = model.state {
                    ContentUnavailableView(
                        "Signed in as u/\(username)",
                        systemImage: "checkmark.circle.fill",
                        description: Text("This Reddit session is stored in this Mac's Keychain.")
                    )
                } else {
                    MacRedditLoginWebView(model: model)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    if showingWebLogin {
                        RedditLoginAccountHelpView()
                    }
                    Text("Sign-in happens on Reddit's website. Octonaut never asks for your Reddit password or developer API credentials.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
        }
        .overlay {
            if case .validating = model.state {
                ProgressView("Checking Reddit account…")
                    .padding()
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .alert(
            "Reddit sign-in failed",
            isPresented: Binding(
                get: { if case .failed = model.state { true } else { false } },
                set: { if !$0 { model.retryAfterFailure() } }
            )
        ) {
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

private struct MacRedditLoginWebView: NSViewRepresentable {
    let model: RedditLoginModel

    func makeCoordinator() -> RedditLoginWebCoordinator {
        RedditLoginWebCoordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        RedditLoginPageCustomization.usernameAndPasswordOnly.install(on: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.startMonitoring(webView)
        webView.load(URLRequest(url: Self.loginURL))
        model.didCreateWebView()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: RedditLoginWebCoordinator) {
        coordinator.stopMonitoring(webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private static let loginURL: URL = {
        var components = URLComponents(string: "https://www.reddit.com/login/")!
        components.queryItems = [
            URLQueryItem(
                name: "dest",
                value: "https://www.reddit.com/user/me/about.json?raw_json=1"
            )
        ]
        return components.url!
    }()
}
