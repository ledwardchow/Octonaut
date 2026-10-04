import SwiftUI
import WebKit

struct LoginConsentView: View {
    let onAccept: () -> Void
    @State private var agrees = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Before you sign in", systemImage: "doc.text")
                    .font(.title2.bold())
                Text("Please review Octonaut's Privacy Policy, Apple's standard End User License Agreement (EULA), and the Reddit Rules.")
                LegalDocumentLinks()
                Toggle("I agree to the EULA and Reddit Rules, and acknowledge the Privacy Policy.", isOn: $agrees)
                Button("Agree and Continue to Reddit", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .disabled(!agrees || LegalDocuments.privacyPolicy() == nil)
                    .accessibilityIdentifier("legal.agreeAndContinue")
                if LegalDocuments.privacyPolicy() == nil {
                    Text("The Privacy Policy could not be loaded. Please close this screen and try again.")
                        .foregroundStyle(.red)
                }
                Text("Sign-in happens on Reddit's website. Your Reddit session is saved in this device's Keychain.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 560, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity)
        }
    }
}

struct LegalDocumentLinks: View {
    @State private var document: LegalDocument?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Button { document = .privacy } label: {
                Label("Privacy Policy", systemImage: "hand.raised")
            }
            Button { document = .eula } label: {
                Label("End User License Agreement (EULA)", systemImage: "doc.text")
            }
            Button { document = .redditRules } label: {
                Label("Reddit Rules", systemImage: "list.bullet")
            }
        }
        .sheet(item: $document) { document in
            LegalDocumentView(document: document)
        }
    }
}

private struct LegalDocumentView: View {
    let document: LegalDocument
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                switch document {
                case .privacy:
                    if let policy = LegalDocuments.privacyPolicy() {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(Array(policy.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                                    if paragraph.hasPrefix("## ") {
                                        Text(String(paragraph.dropFirst(3)))
                                            .font(.title2.bold())
                                    } else {
                                        Text(.init(paragraph))
                                    }
                                }
                            }
                            .textSelection(.enabled)
                            .frame(maxWidth: 700, alignment: .leading)
                            .padding(24)
                            .frame(maxWidth: .infinity)
                        }
                    } else {
                        ContentUnavailableView("Privacy Policy unavailable", systemImage: "doc.text", description: Text("Please close this screen and try again."))
                    }
                case .eula, .redditRules:
                    RemoteLegalDocumentView(document: document)
                }
            }
            .navigationTitle(document.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 500)
        #endif
    }
}

private struct RemoteLegalDocumentView: View {
    let document: LegalDocument
    @State private var loading = true
    @State private var failed = false
    @State private var reloadID = UUID()

    var body: some View {
        ZStack {
            LegalWebView(document: document, loading: $loading, failed: $failed)
                .id(reloadID)
            if loading { ProgressView("Loading \(document.title)…") }
            if failed {
                ContentUnavailableView {
                    Label("\(document.title) could not be loaded", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Check your internet connection and try again.")
                } actions: {
                    Button("Try Again") {
                        failed = false
                        loading = true
                        reloadID = UUID()
                    }
                    if let url = document.remoteURL {
                        Link("Open in Browser", destination: url)
                    }
                }
                .background(.background)
            }
        }
    }
}

// Legal pages use their own temporary cookie store, separate from Reddit login.
struct LegalWebView {
    let document: LegalDocument
    @Binding var loading: Bool
    @Binding var failed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, loading: $loading, failed: $failed)
    }

    func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        if let url = document.remoteURL {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let document: LegalDocument
        @Binding var loading: Bool
        @Binding var failed: Bool

        init(document: LegalDocument, loading: Binding<Bool>, failed: Binding<Bool>) {
            self.document = document
            _loading = loading
            _failed = failed
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            // The document is visible now. Embedded resources can keep didFinish
            // pending even when the policy is already readable.
            loading = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            loading = false
            failed = true
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            loading = false
            failed = true
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            LegalDocuments.allowsNavigation(navigationAction.request.url, for: document) ? .allow : .cancel
        }
    }
}

#if os(iOS)
extension LegalWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.navigationDelegate = nil
    }
}
#elseif os(macOS)
extension LegalWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.stopLoading()
        nsView.navigationDelegate = nil
    }
}
#endif
