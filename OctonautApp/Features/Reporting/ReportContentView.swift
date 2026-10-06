import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
struct ReportContentView: View {
    let target: RedditReportTarget
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    // Reporting must leave Octonaut even when ordinary Reddit links open in the app.
    private let openBrowser = OpenURLAction { url in .systemAction(url) }
    @State private var rules: [RedditReportRule] = []
    @State private var siteReasons: [RedditSiteReportReason] = []
    @State private var selectedReason: String?
    /// Whether `selectedReason` is a Reddit-wide reason rather than a community rule.
    @State private var selectedIsSiteRule = false
    @State private var loading = false
    @State private var sending = false
    @State private var submitted = false
    @State private var showingLogin = false
    @State private var linkCopied = false
    @State private var errorMessage: String?

    private var accountID: AccountID? {
        dependencies.accounts.selectedAccount?.health == .healthy
            ? dependencies.accounts.selectedAccountID : nil
    }

    var body: some View {
        NavigationStack {
            Form {
                if submitted {
                    Label("Report submitted", systemImage: "checkmark.circle")
                    Text(selectedIsSiteRule
                         ? "Your report was sent to Reddit."
                         : "Your report was sent to the moderators of r/\(target.community).")
                } else {
                    Section {
                        Text("Report this \(target.fullname.hasPrefix("t1_") ? "comment" : "post") to the moderators of r/\(target.community), or to Reddit for breaking Reddit's rules.")
                        if accountID == nil {
                            Text("Sign in to Reddit in Octonaut to submit a community report.")
                            Button("Sign in to Reddit") { showingLogin = true }
                        } else if loading {
                            ProgressView("Loading community rules…")
                        } else if rules.isEmpty && errorMessage == nil {
                            Text("This community has no rules of its own. Choose one of Reddit's rules below.")
                        } else {
                            ForEach(rules) { rule in
                                reasonButton(rule.shortName, reason: rule.violationReason, isSiteRule: false)
                            }
                        }
                    } header: { Text("Community rules") }
                    if accountID != nil, !loading, !siteReasons.isEmpty {
                        Section {
                            ForEach(siteReasons) { reason in
                                switch reason.handling {
                                case .report:
                                    reasonButton(reason.label, reason: reason.reasonText, isSiteRule: true)
                                case .complaint(let template):
                                    if let url = RedditSiteReportReason.complaintURL(template, fullname: target.fullname) {
                                        Button { openBrowser(url) } label: {
                                            Label(reason.label, systemImage: "arrow.up.forward.app")
                                        }
                                        .disabled(sending)
                                    }
                                case .browser:
                                    if let url = target.browserURL {
                                        Button { openBrowser(url) } label: {
                                            Label(reason.label, systemImage: "safari")
                                        }
                                        .disabled(sending)
                                    }
                                }
                            }
                        } header: {
                            Text("Reddit rules")
                        } footer: {
                            Text("Reddit reviews these reports. Items marked with an arrow open Reddit's own form.")
                        }
                    }
                    if let errorMessage {
                        Section {
                            Text(errorMessage).foregroundStyle(.red)
                            if !sending && rules.isEmpty && accountID != nil {
                                Button("Retry loading rules") { Task { await loadRules() } }
                            }
                        }
                    }
                    if accountID != nil {
                        Section {
                            Button(sending ? "Submitting…" : "Submit report") {
                                Task { await submit() }
                            }
                            .disabled(selectedReason == nil || sending || loading)
                        }
                    }
                    Section {
                        if let url = target.browserURL {
                            Button(target.fullname.hasPrefix("t1_") ? "Open comment on Reddit" : "Open post on Reddit", systemImage: "safari") {
                                openBrowser(url) { accepted in
                                    if !accepted {
                                        errorMessage = "The link could not be opened. Copy the link and open it in your browser."
                                    }
                                }
                            }
                                .disabled(sending)
                            Button(linkCopied ? "Link copied" : "Copy link", systemImage: "doc.on.doc") {
                                #if os(macOS)
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString, forType: .string)
                                #else
                                UIPasteboard.general.url = url
                                #endif
                                linkCopied = true
                            }
                        }
                        Text("On Reddit, open the post or comment’s ⋯ menu and choose Report. Your browser has its own Reddit login, so you may need to sign in there even if you’re signed in to Octonaut.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Report content")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(submitted ? "Done" : "Cancel") { dismiss() }.disabled(sending)
                }
            }
        }
        #if os(macOS)
        .frame(width: 480, height: 520)
        #endif
        .interactiveDismissDisabled(sending)
        .sheet(isPresented: $showingLogin, onDismiss: { Task { await loadRules() } }) {
            #if os(macOS)
            MacRedditLoginView(accounts: dependencies.accounts)
                .frame(width: 640, height: 720)
            #else
            RedditLoginView(accounts: dependencies.accounts)
            #endif
        }
        .task(id: "\(dependencies.accounts.selectionGeneration):\(dependencies.accounts.selectedAccount?.health.rawValue ?? "none")") { await loadRules() }
    }

    private func reasonButton(_ title: String, reason: String, isSiteRule: Bool) -> some View {
        let isSelected = selectedReason == reason && selectedIsSiteRule == isSiteRule
        return Button {
            selectedReason = reason
            selectedIsSiteRule = isSiteRule
        } label: {
            HStack {
                Text(title)
                Spacer()
                if isSelected { Image(systemName: "checkmark") }
            }
        }
        .disabled(sending)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func loadRules() async {
        guard !submitted else { return }
        rules = []
        siteReasons = []
        selectedReason = nil
        selectedIsSiteRule = false
        errorMessage = nil
        guard let accountID else { return }
        let token = dependencies.accounts.token(for: accountID)
        loading = true
        defer { loading = false }
        do {
            let fetched = try await dependencies.reddit.reportOptions(community: target.community, account: accountID)
            guard dependencies.accounts.isCurrent(token), !Task.isCancelled else { return }
            rules = fetched.rules.filter { $0.applies(to: target.fullname) }
            siteReasons = fetched.siteReasons
        } catch is CancellationError {
        } catch {
            guard dependencies.accounts.isCurrent(token), !Task.isCancelled else { return }
            errorMessage = "Community rules could not be loaded. Try again or open the content on Reddit."
        }
    }

    private func submit() async {
        guard !sending, let accountID, let selectedReason else { return }
        let isSiteRule = selectedIsSiteRule
        // Only send reasons Reddit itself offered for this item.
        if isSiteRule {
            guard siteReasons.contains(where: { $0.handling == .report && $0.reasonText == selectedReason }) else { return }
        } else {
            guard rules.contains(where: { $0.violationReason == selectedReason }) else { return }
        }
        let token = dependencies.accounts.token(for: accountID)
        sending = true
        errorMessage = nil
        defer { sending = false }
        do {
            let result = try await dependencies.authenticated.perform(
                isSiteRule
                    ? .reportSiteRule(fullname: target.fullname, community: target.community, reason: selectedReason)
                    : .report(fullname: target.fullname, community: target.community, reason: selectedReason),
                accountID: accountID
            )
            guard dependencies.accounts.isCurrent(token) else { return }
            if result.succeeded { submitted = true }
            else { errorMessage = result.message ?? "Reddit did not accept the report." }
        } catch {
            guard dependencies.accounts.isCurrent(token) else { return }
            if let clientError = error as? RedditClientError, clientError == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
                errorMessage = "Sign in again to submit a report, or open the content on Reddit."
            } else {
                errorMessage = "The report could not be confirmed. Open the content on Reddit to check or report it."
            }
        }
    }
}
