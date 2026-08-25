import SwiftUI

@MainActor
struct ComposerView: View {
    let kind: ComposerKind
    let store: OctonautFeatureStore
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var community = ""
    @State private var recipient = ""
    @State private var title = ""
    @State private var bodyText = ""
    @State private var link = ""
    @State private var postType = "Text"
    @State private var isPreview = false
    @State private var sendReplies = true
    @State private var showingDiscard = false
    @State private var showingError = false
    @State private var sending = false
    @State private var draftID = UUID()
    @State private var draftAccountID: AccountID?

    private var isDirty: Bool { !title.isEmpty || !bodyText.isEmpty || !link.isEmpty || !community.isEmpty || !recipient.isEmpty }
    private var canSubmit: Bool {
        switch kind {
        case .post: return !community.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (postType != "Link" || URL(string: link) != nil)
        case .comment, .edit: return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .message: return !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isPreview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !title.isEmpty { Text(title).font(.title3.weight(.bold)) }
                        Text(bodyText.isEmpty ? "Nothing to preview yet." : bodyText)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if kind == .post, postType == "Link", !link.isEmpty { Label(link, systemImage: "link") .font(.caption).foregroundStyle(.secondary) }
                    }
                    .padding()
                }
            } else {
                Form {
                    if kind == .post {
                        Section("Destination") {
                            TextField("Community, for example apple", text: $community)
                                .textInputAutocapitalization(.never)
                            Picker("Post type", selection: $postType) {
                                Text("Text").tag("Text")
                                Text("Link").tag("Link")
                                Text("Image").tag("Image")
                            }
                        }
                    }
                    if kind == .message {
                        Section("Recipient") { TextField("Username", text: $recipient).textInputAutocapitalization(.never) }
                    }
                    if kind == .post {
                        Section("Title") { TextField("A clear title", text: $title) }
                    }
                    if kind == .post, postType == "Link" {
                        Section("Link") { TextField("https://…", text: $link).keyboardType(.URL).textInputAutocapitalization(.never) }
                    }
                    Section(kind == .post ? "Body" : "Reply") {
                        TextEditor(text: $bodyText)
                            .frame(minHeight: 180)
                            .overlay(alignment: .topLeading) {
                                if bodyText.isEmpty { Text(kind == .post ? "Write something useful…" : "Write your reply…").foregroundStyle(.tertiary).padding(.top, 8).allowsHitTesting(false) }
                            }
                    }
                    Section {
                        Toggle("Send me reply notifications", isOn: $sendReplies)
                    }
                }
            }
            formattingBar
        }
        .navigationTitle(kind.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    if isDirty { showingDiscard = true } else { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(sending ? "Sending…" : "Send") { submit() }
                    .disabled(!canSubmit || sending)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isPreview ? "Edit" : "Preview") { isPreview.toggle() }
            }
        }
        .confirmationDialog("Discard this draft?", isPresented: $showingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert("Complete the required fields", isPresented: $showingError) {
            Button("OK", role: .cancel) {}
        } message: {
            if dependencies.accounts.selectedAccount == nil {
                Text("Add or select a Reddit account before sending.")
            } else if dependencies.accounts.selectedAccount?.health == .needsLogin {
                Text("Sign in again from the Account tab before sending.")
            } else {
                Text(kind == .post ? "Add a community and title. Link posts also need a valid URL." : "Add some text before sending.")
            }
        }
        .task(id: bodyText) {
            try? await Task.sleep(for: .milliseconds(500))
            await saveDraft()
        }
        .task {
            if draftAccountID == nil { draftAccountID = dependencies.accounts.selectedAccountID }
        }
    }

    private var formattingBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                formatButton("bold", title: "Bold", open: "**", close: "**")
                formatButton("italic", title: "Italic", open: "*", close: "*")
                formatButton("strikethrough", title: "Strike", open: "~~", close: "~~")
                formatButton("text.quote", title: "Quote", open: "> ", close: "")
                formatButton("eye.slash", title: "Spoiler", open: ">!", close: "!<")
                formatButton("link", title: "Link", open: "[", close: "](url)")
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func formatButton(_ symbol: String, title: String, open: String, close: String) -> some View {
        Button {
            bodyText.append(bodyText.isEmpty ? "\(open)text\(close)" : " \(open)text\(close)")
        } label: {
            Image(systemName: symbol)
                .frame(minWidth: 28, minHeight: 28)
        }
        .accessibilityLabel(title)
    }

    private func submit() {
        guard canSubmit else { showingError = true; return }
        guard let selectedAccount = dependencies.accounts.selectedAccount,
              selectedAccount.health != .needsLogin,
              selectedAccount.id == draftAccountID else {
            showingError = true
            return
        }
        let accountID = selectedAccount.id
        sending = true
        let action: RedditAction
        switch kind {
        case .post:
            action = .submitPost(
                community: community.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                text: bodyText.isEmpty ? nil : bodyText,
                link: URL(string: link),
                sendReplies: sendReplies
            )
        case .comment, .edit:
            let target = store.posts.first?.id ?? ""
            action = kind == .edit ? .edit(thingID: target, text: bodyText) : .comment(thingID: target, text: bodyText)
        case .message:
            action = .composeMessage(to: recipient.trimmingCharacters(in: .whitespacesAndNewlines), subject: title, text: bodyText)
        }
        Task {
            do {
                _ = try await dependencies.authenticated.perform(action, accountID: accountID)
                try? await dependencies.persistence.deleteDraft(draftID)
                sending = false
                dismiss()
            } catch let error as RedditClientError where error == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
                sending = false
                showingError = true
            } catch {
                sending = false
                showingError = true
            }
        }
    }

    private func saveDraft() async {
        guard isDirty, let accountID = draftAccountID else { return }
        let draftKind: DraftKind = switch kind {
        case .post: .post
        case .comment, .edit: .comment
        case .message: .message
        }
        let draft = Draft(
            id: draftID,
            kind: draftKind,
            accountID: accountID,
            target: kind == .post ? community : recipient,
            title: title,
            body: bodyText,
            link: URL(string: link),
            modifiedAt: .now
        )
        try? await dependencies.persistence.saveDraft(draft)
    }
}
