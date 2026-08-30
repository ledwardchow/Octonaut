import SwiftUI
import WebKit

@MainActor
struct MacRedditLoginView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: RedditLoginModel

    init(accounts: AccountCoordinator) {
        _model = State(initialValue: RedditLoginModel(accounts: accounts))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Sign in to Reddit")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    model.cancel()
                    dismiss()
                }
            }
            .padding()

            Divider()

            if case .succeeded(let username) = model.state {
                ContentUnavailableView(
                    "Signed in as u/\(username)",
                    systemImage: "checkmark.circle.fill",
                    description: Text("This Reddit session is stored in this Mac's Keychain.")
                )
            } else {
                MacRedditLoginWebView(model: model)
            }

            Divider()

            Text("Sign-in happens on Reddit's website. Octonaut never asks for your Reddit password or developer API credentials.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
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

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.customUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Version/18.6 Safari/605.1.15"
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.startMonitoring(webView)
        webView.load(URLRequest(url: Self.loginURL))
        model.didCreateWebView()
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {}

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.stopMonitoring(webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
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

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        let model: RedditLoginModel
        weak var webView: WKWebView?
        var pollingTask: Task<Void, Never>?

        init(model: RedditLoginModel) {
            self.model = model
        }

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

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let host = navigationAction.request.url?.host?.lowercased(),
                  host == "reddit.com" || host.hasSuffix(".reddit.com") else {
                return .cancel
            }
            return .allow
        }
    }
}
