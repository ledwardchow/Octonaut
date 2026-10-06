import SwiftUI

@MainActor
struct ComposerView: View {
    let kind: ComposerKind
    let store: OctonautFeatureStore
    let targetID: String?
    let onSubmitted: (() -> Void)?
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
    @State private var sendError: String?
    @State private var sending = false
    @State private var draftID = UUID()
    @State private var draftAccountID: AccountID?
    @FocusState private var isBodyFocused: Bool

    init(
        kind: ComposerKind,
        store: OctonautFeatureStore,
        community: String = "",
        targetID: String? = nil,
        recipient: String = "",
        onSubmitted: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.store = store
        self.targetID = targetID
        self.onSubmitted = onSubmitted
        _community = State(initialValue: community)
        _recipient = State(initialValue: recipient)
    }

    private var isDirty: Bool { !title.isEmpty || !bodyText.isEmpty || !link.isEmpty || !community.isEmpty || !recipient.isEmpty }
    /// Text the user typed, as opposed to a prefilled community or recipient.
    private var hasContent: Bool { !title.isEmpty || !bodyText.isEmpty || !link.isEmpty }
    private var draftFields: [String] { [title, bodyText, link, community, recipient, postType] }
    private var isPostComment: Bool { kind == .comment && targetID?.hasPrefix("t3_") == true }
    private var canSubmit: Bool {
        switch kind {
        case .post: return !community.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (postType != "Link" || URL(string: link) != nil)
        case .comment, .edit:
            return targetID?.isEmpty == false
                && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .message: return !recipient.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var submitTitle: String {
        if sending {
            return switch kind {
            case .post: "Posting…"
            case .comment: "Commenting…"
            case .message: "Sending…"
            case .edit: "Saving…"
            }
        }

        return switch kind {
        case .post: "Post"
        case .comment: "Comment"
        case .message: "Send"
        case .edit: "Save"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isPreview {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if !title.isEmpty { Text(title).font(.title3.weight(.bold)) }
                            RedditMarkdownView(
                                source: bodyText.isEmpty ? "Nothing to preview yet." : bodyText
                            )
                            .font(.body)
                            .tint(.accentColor)
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
                        if kind == .message {
                            Section("Subject") { TextField("Subject", text: $title) }
                        }
                        if kind == .post, postType == "Link" {
                            Section("Link") { TextField("https://…", text: $link).keyboardType(.URL).textInputAutocapitalization(.never) }
                        }
                        Section(kind == .post ? "Body" : isPostComment ? "Comment" : "Reply") {
                            TextEditor(text: $bodyText)
                                .focused($isBodyFocused)
                                .frame(minHeight: 180)
                                .overlay(alignment: .topLeading) {
                                    if bodyText.isEmpty, !isBodyFocused {
                                        Text(kind == .post ? "Write something useful…" : isPostComment ? "Write a comment…" : "Write your reply…")
                                            .foregroundStyle(.tertiary)
                                            .padding(.top, 8)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                        Section {
                            Toggle("Send me reply notifications", isOn: $sendReplies)
                        }
                    }
                }
                formattingBar
            }
            .navigationTitle(isPostComment ? "Comment" : kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if isDirty { showingDiscard = true } else { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle) { submit() }
                        .disabled(!canSubmit || sending)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isPreview ? "Edit" : "Preview") { isPreview.toggle() }
                }
            }
            .confirmationDialog("Discard this draft?", isPresented: $showingDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) {
                    let id = draftID
                    Task { try? await dependencies.persistence.deleteDraft(id) }
                    dismiss()
                }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert(sendError == nil ? "Complete the required fields" : "Couldn't send", isPresented: $showingError) {
                Button("OK", role: .cancel) {}
            } message: {
                if let sendError {
                    Text(sendError)
                } else if dependencies.accounts.selectedAccount == nil {
                    Text("Add or select a Reddit account before sending.")
                } else if dependencies.accounts.selectedAccount?.health == .needsLogin {
                    Text("Sign in again from the Account tab before sending.")
                } else {
                    Text(kind == .post ? "Add a community and title. Link posts also need a valid URL." : kind == .message ? "Add a recipient, subject and message." : "Add some text before sending.")
                }
            }
            .task(id: draftFields) {
                // A cancelled wait means the view closed or the text changed again.
                do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                await saveDraft()
            }
            .task {
                if draftAccountID == nil { draftAccountID = dependencies.accounts.selectedAccountID }
                await restoreDraft()
            }
            // Swiping away would skip the discard prompt and lose the text.
            .interactiveDismissDisabled(hasContent)
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
        sendError = nil
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
            let target = targetID ?? ""
            action = kind == .edit ? .edit(thingID: target, text: bodyText) : .comment(thingID: target, text: bodyText)
        case .message:
            action = .composeMessage(to: recipient.trimmingCharacters(in: .whitespacesAndNewlines), subject: title.trimmingCharacters(in: .whitespacesAndNewlines), text: bodyText)
        }
        Task {
            do {
                _ = try await dependencies.authenticated.perform(action, accountID: accountID)
                try? await dependencies.persistence.deleteDraft(draftID)
                sending = false
                onSubmitted?()
                dismiss()
            } catch let error as RedditClientError where error == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
                sending = false
                showingError = true
            } catch {
                sending = false
                sendError = error.localizedDescription
                showingError = true
            }
        }
    }

    private var draftKind: DraftKind? {
        switch kind {
        case .post: .post
        case .comment: .comment
        case .message: .message
        case .edit: nil
        }
    }

    private var draftTarget: String { kind == .post ? community : (targetID ?? recipient) }

    /// Reopens the newest saved draft for the same account, kind and target.
    private func restoreDraft() async {
        guard !hasContent, kind != .edit, let accountID = draftAccountID, let draftKind,
              let drafts = try? await dependencies.persistence.loadDrafts(accountID: accountID) else { return }
        let target = draftTarget
        let match = drafts
            .filter { $0.kind == draftKind && (kind == .post && community.isEmpty || ($0.target ?? "") == target) }
            .max { $0.modifiedAt < $1.modifiedAt }
        guard let match, !hasContent else { return }
        draftID = match.id
        title = match.title
        bodyText = match.body
        if let restoredLink = match.link {
            link = restoredLink.absoluteString
            postType = "Link"
        }
        if kind == .post, community.isEmpty { community = match.target ?? "" }
    }

    private func saveDraft() async {
        // Edits start from the existing text and share a target with replies, so they aren't drafted.
        guard !sending, kind != .edit, let accountID = draftAccountID, let draftKind else { return }
        guard hasContent else {
            try? await dependencies.persistence.deleteDraft(draftID)
            return
        }
        let draft = Draft(
            id: draftID,
            kind: draftKind,
            accountID: accountID,
            target: draftTarget,
            title: title,
            body: bodyText,
            link: URL(string: link),
            modifiedAt: .now
        )
        try? await dependencies.persistence.saveDraft(draft)
    }
}

@MainActor
struct CrosspostComposerView: View {
    let post: PostCardModel

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var community = ""
    @State private var title: String
    @State private var sendReplies = true
    @State private var sending = false
    @State private var errorMessage: String?

    init(post: PostCardModel) {
        self.post = post
        _title = State(initialValue: post.title)
    }

    private var canSubmit: Bool {
        !normalizedCommunity.isEmpty
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !sending
    }

    private var normalizedCommunity: String {
        let trimmed = community.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("r/") {
            return String(trimmed.dropFirst(2))
        }
        return trimmed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("Community, for example apple", text: $community)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
                Section("Title") {
                    TextField("Crosspost title", text: $title, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section("Original post") {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(post.title)
                            .font(.body.weight(.medium))
                        Text("r/\(post.community) · u/\(post.author)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    Toggle("Send me reply notifications", isOn: $sendReplies)
                }
            }
            .navigationTitle("Crosspost")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(sending ? "Posting…" : "Post") { submit() }
                        .disabled(!canSubmit)
                }
            }
        }
        .interactiveDismissDisabled(sending)
        .alert("Crosspost failed", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Reddit could not create the crosspost.")
        }
    }

    private func submit() {
        guard canSubmit,
              let account = dependencies.accounts.selectedAccount,
              account.health == .healthy else {
            errorMessage = "Sign in to Reddit before creating a crosspost."
            return
        }

        let accountID = account.id
        let action = RedditAction.crosspost(
            community: normalizedCommunity,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            sourceFullname: post.fullname,
            sendReplies: sendReplies
        )
        sending = true
        Task {
            do {
                _ = try await dependencies.authenticated.perform(action, accountID: accountID)
                sending = false
                dismiss()
            } catch let error as RedditClientError where error == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
                sending = false
                errorMessage = error.errorDescription
            } catch {
                sending = false
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Reddit could not create the crosspost."
            }
        }
    }
}
