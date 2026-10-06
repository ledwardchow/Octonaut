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
    @State private var selectedReason: String?
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
                    Text("Your report was sent to the moderators of r/\(target.community).")
                } else {
                    Section {
                        Text("Report this \(target.fullname.hasPrefix("t1_") ? "comment" : "post") to the moderators of r/\(target.community).")
                        if accountID == nil {
                            Text("Sign in to Reddit in Octonaut to submit a community report.")
                            Button("Sign in to Reddit") { showingLogin = true }
                        } else if loading {
                            ProgressView("Loading community rules…")
                        } else if rules.isEmpty && errorMessage == nil {
                            // ponytail: Reddit's site-wide reasons go through the browser handoff below;
                            // add them in-app once their /api/report fields can be verified.
                            Text("This community has no report rules. Use Open on Reddit below to report it for breaking Reddit's rules, such as spam or harassment.")
                        } else {
                            ForEach(rules) { rule in
                                Button {
                                    selectedReason = rule.violationReason
                                } label: {
                                    HStack {
                                        Text(rule.shortName)
                                        Spacer()
                                        if selectedReason == rule.violationReason {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                                .disabled(sending)
                                .accessibilityAddTraits(selectedReason == rule.violationReason ? .isSelected : [])
                            }
                        }
                    } header: { Text("Community rules") }
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

    private func loadRules() async {
        guard !submitted else { return }
        rules = []
        selectedReason = nil
        errorMessage = nil
        guard let accountID else { return }
        let token = dependencies.accounts.token(for: accountID)
        loading = true
        defer { loading = false }
        do {
            let fetched = try await dependencies.reddit.reportRules(community: target.community, account: accountID)
            guard dependencies.accounts.isCurrent(token), !Task.isCancelled else { return }
            rules = fetched.filter { $0.applies(to: target.fullname) }
        } catch is CancellationError {
        } catch {
            guard dependencies.accounts.isCurrent(token), !Task.isCancelled else { return }
            errorMessage = "Community rules could not be loaded. Try again or open the content on Reddit."
        }
    }

    private func submit() async {
        guard !sending, let accountID, let selectedReason,
              rules.contains(where: { $0.violationReason == selectedReason }) else { return }
        let token = dependencies.accounts.token(for: accountID)
        sending = true
        errorMessage = nil
        defer { sending = false }
        do {
            let result = try await dependencies.authenticated.perform(
                .report(fullname: target.fullname, community: target.community, reason: selectedReason),
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
