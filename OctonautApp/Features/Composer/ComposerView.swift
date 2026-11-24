import SwiftUI

@MainActor
struct ComposerView: View {
    let kind: ComposerKind
    let store: OctonautFeatureStore
    let targetID: String?
    let onSubmitted: (() -> Void)?
    private let initialCommunity: String
    private let initialRecipient: String
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
    @State private var accountIsBound = false
    @State private var draftReady = false
    @State private var draftClosed = false
    @State private var hasSavedDraft = false
    @State private var draftSession: ComposerDraftSession?
    @State private var draftErrorTitle: String?
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
        self.initialCommunity = community
        self.initialRecipient = recipient
        _community = State(initialValue: community)
        _recipient = State(initialValue: recipient)
    }

    private var hasContent: Bool {
        !title.isEmpty || !bodyText.isEmpty || (kind == .post && postType == "Link" && !link.isEmpty)
            || (kind == .post && community != initialCommunity && !community.isEmpty)
            || (kind == .message && recipient != initialRecipient && !recipient.isEmpty)
    }
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
                                    // ponytail: no Image type until media upload exists; share an image link instead.
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
                        Section(kind == .post ? "Body" : kind == .message ? "Message" : isPostComment ? "Comment" : "Reply") {
                            TextEditor(text: $bodyText)
                                .focused($isBodyFocused)
                                .frame(minHeight: 180)
                                .overlay(alignment: .topLeading) {
                                    if bodyText.isEmpty, !isBodyFocused {
                                        Text(kind == .post ? "Write something useful…" : kind == .message ? "Write your message…" : isPostComment ? "Write a comment…" : "Write your reply…")
                                            .foregroundStyle(.tertiary)
                                            .padding(.top, 8)
                                            .allowsHitTesting(false)
                                    }
                                }
                        }
                        if kind == .post {
                            Section {
                                Toggle("Send me reply notifications", isOn: $sendReplies)
                            }
                        }
                    }
                }
                formattingBar
            }
            .disabled(sending || draftClosed)
            .navigationTitle(isPostComment ? "Comment" : kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasContent || hasSavedDraft {
                            showingDiscard = true
                        } else if draftSession?.hasPendingWrite != true || kind == .edit {
                            draftClosed = true
                            dismiss()
                        } else {
                            finishDraft(save: false)
                        }
                    }
                    .disabled(sending || draftClosed)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(submitTitle) { submit() }
                        .disabled(!canSubmit || sending || draftClosed)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isPreview ? "Edit" : "Preview") { isPreview.toggle() }
                }
            }
            .confirmationDialog(kind == .edit ? "Discard changes?" : "Keep this draft?", isPresented: $showingDiscard, titleVisibility: .visible) {
                if kind != .edit && hasContent {
                    Button("Save Draft") { finishDraft(save: true) }
                }
                Button("Discard", role: .destructive) {
                    finishDraft(save: false)
                }
                Button("Keep Editing", role: .cancel) {}
            }
            .alert(draftErrorTitle ?? (sendError == nil ? "Complete the required fields" : "Couldn't send"), isPresented: $showingError) {
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
            .onChange(of: draftFields) { _, _ in scheduleDraftSave() }
            .task {
                if !accountIsBound {
                    draftAccountID = dependencies.accounts.selectedAccountID
                    accountIsBound = true
                    draftSession = ComposerDraftSession(persistence: dependencies.persistence)
                }
                await restoreDraft()
                draftReady = true
                scheduleDraftSave()
            }
            // Swiping away would skip the discard prompt and lose the text.
            .interactiveDismissDisabled(hasContent || hasSavedDraft || sending || draftClosed)
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
        guard !sending, !draftClosed else { return }
        draftErrorTitle = nil
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
        let draftSession = self.draftSession
        let action: RedditAction
        switch kind {
        case .post:
            action = .submitPost(
                community: community.trimmingCharacters(in: .whitespacesAndNewlines),
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                text: bodyText.isEmpty ? nil : bodyText,
                // A link typed before switching back to Text must not turn this into a link post.
                link: postType == "Link" ? URL(string: link.trimmingCharacters(in: .whitespacesAndNewlines)) : nil,
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
                await draftSession?.drain()
                _ = try await dependencies.authenticated.perform(action, accountID: accountID)
                draftClosed = true
                if let draftSession {
                    try? await draftSession.finish(.discard, id: draftID)
                } else {
                    try? await dependencies.persistence.deleteDraft(draftID)
                }
                sending = false
                onSubmitted?()
                dismiss()
            } catch let error as RedditClientError where error == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
                sending = false
                showingError = true
                scheduleDraftSave()
            } catch {
                sending = false
                sendError = error.localizedDescription
                showingError = true
                scheduleDraftSave()
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

    private var draftTarget: String {
        switch kind {
        case .post: community
        case .message: recipient
        case .comment, .edit: targetID ?? ""
        }
    }

    /// Reopens the newest saved draft for the same account, kind and target.
    private func restoreDraft() async {
        guard !hasContent, !draftClosed, kind != .edit, let accountID = draftAccountID, let draftKind,
              let drafts = try? await dependencies.persistence.loadDrafts(accountID: accountID) else { return }
        let target = draftTarget
        let match = Draft.newestMatching(
            in: drafts,
            kind: draftKind,
            target: target,
            anyTargetWhenEmpty: kind == .post || kind == .message
        )
        guard let match, !hasContent, !draftClosed else { return }
        draftID = match.id
        hasSavedDraft = true
        title = match.title
        bodyText = match.body
        if let restoredLink = match.link {
            link = restoredLink.absoluteString
            postType = "Link"
        }
        if kind == .post, community.isEmpty { community = match.target ?? "" }
        if kind == .message, recipient.isEmpty { recipient = match.target ?? "" }
    }

    private func scheduleDraftSave() {
        guard draftReady, !draftClosed, !sending, kind != .edit, draftAccountID != nil else { return }
        draftSession?.schedule(currentDraft, id: draftID)
    }

    private func finishDraft(save: Bool) {
        guard !draftClosed else { return }
        draftClosed = true
        Task {
            do {
                guard let draftSession else { throw IOSComposerDraftError.notReady }
                let operation: ComposerDraftSession.Finish
                if save && hasContent {
                    guard let draft = currentDraft else { throw IOSComposerDraftError.accountRequired }
                    operation = .save(draft)
                } else {
                    operation = .discard
                }
                try await draftSession.finish(operation, id: draftID)
                dismiss()
            } catch {
                draftClosed = false
                draftErrorTitle = save ? "Couldn't save draft" : "Couldn't discard draft"
                sendError = error.localizedDescription
                showingError = true
            }
        }
    }

    private var currentDraft: Draft? {
        guard kind != .edit, hasContent, let accountID = draftAccountID, let draftKind else { return nil }
        return Draft(
            id: draftID,
            kind: draftKind,
            accountID: accountID,
            target: draftTarget,
            title: title,
            body: bodyText,
            link: postType == "Link" ? URL(string: link) : nil,
            modifiedAt: .now
        )
    }
}

private enum IOSComposerDraftError: LocalizedError {
    case accountRequired
    case notReady

    var errorDescription: String? {
        switch self {
        case .accountRequired: "Select a Reddit account before saving this draft."
        case .notReady: "Wait for the draft to finish loading, then try again."
        }
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
