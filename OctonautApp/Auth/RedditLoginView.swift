import SwiftUI
import WebKit

struct RedditLoginView: View {
    let accounts: AccountCoordinator
    let anonymousRequestsBlocked: Bool
    @Environment(\.dismiss) private var dismiss
    @AppStorage(LegalDocuments.acceptedVersionKey) private var acceptedConsentVersion = ""
    @State private var model: RedditLoginModel
    @State private var hasStartedSignIn = false

    init(accounts: AccountCoordinator, anonymousRequestsBlocked: Bool = false) {
        self.accounts = accounts
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
        NavigationStack {
            VStack(spacing: 0) {
                if !hasStartedSignIn {
                    RedditLoginWelcomeView(anonymousRequestsBlocked: anonymousRequestsBlocked, onSignIn: { hasStartedSignIn = true }) {
                        model.cancel()
                        dismiss()
                    }
                } else if LegalDocuments.requiresConsent(acceptedVersion: acceptedConsentVersion) {
                    LoginConsentView { acceptedConsentVersion = LegalDocuments.consentVersion }
                } else if case .succeeded(let username) = model.state {
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
            .navigationTitle(hasStartedSignIn ? (LegalDocuments.requiresConsent(acceptedVersion: acceptedConsentVersion) ? "Privacy and Terms" : "Sign in to Reddit") : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(hasStartedSignIn ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if hasStartedSignIn {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            model.cancel()
                            dismiss()
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if hasStartedSignIn {
                    VStack(alignment: .leading, spacing: 5) {
                        if showingWebLogin {
                            RedditLoginAccountHelpView()
                                .padding(.bottom, 5)
                        }
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

    func makeCoordinator() -> RedditLoginWebCoordinator { RedditLoginWebCoordinator(model: model) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        RedditLoginPageCustomization.usernameAndPasswordOnly.install(on: configuration)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1"
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.startMonitoring(webView)
        webView.load(URLRequest(url: Self.loginURL))
        model.didCreateWebView()
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: RedditLoginWebCoordinator) {
        coordinator.stopMonitoring(webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private static let loginURL: URL = {
        var components = URLComponents(string: "https://www.reddit.com/login/")!
        components.queryItems = [
            URLQueryItem(name: "dest", value: "https://www.reddit.com/user/me/about.json?raw_json=1")
        ]
        return components.url!
    }()
}
