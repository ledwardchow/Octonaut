import SwiftUI

enum MacComposerContext: Identifiable, Hashable {
    case post(defaultCommunity: String)
    case comment(postID: String, postTitle: String)
    case reply(commentID: String, author: String)

    var id: String {
        switch self {
        case .post(let community): "post:\(community)"
        case .comment(let postID, _): "comment:\(postID)"
        case .reply(let commentID, _): "reply:\(commentID)"
        }
    }

    var title: String {
        switch self {
        case .post: "New Post"
        case .comment: "Add Comment"
        case .reply: "Reply"
        }
    }
}

enum MacComposerResult {
    case post
    case comment

    var message: String {
        switch self {
        case .post: "Post submitted"
        case .comment: "Comment submitted"
        }
    }
}

@MainActor
struct MacComposerView: View {
    private enum PostKind: String, CaseIterable, Identifiable {
        case text = "Text"
        case link = "Link"

        var id: String { rawValue }
    }

    let context: MacComposerContext
    let onSubmitted: (MacComposerResult) -> Void
    private let initialCommunity: String

    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.dismiss) private var dismiss
    @State private var community: String
    @State private var title = ""
    @State private var bodyText = ""
    @State private var linkText = ""
    @State private var postKind = PostKind.text
    @State private var sendReplies = true
    @State private var isPreviewing = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var errorTitle = "Could not send"
    @State private var showingCloseOptions = false
    @State private var isClosing = false
    @State private var draftID = UUID()
    @State private var draftAccountID: AccountID?
    @State private var accountIsBound = false
    @State private var draftSession: ComposerDraftSession?
    @State private var hasSavedDraft = false
    @FocusState private var bodyIsFocused: Bool

    init(
        context: MacComposerContext,
        onSubmitted: @escaping (MacComposerResult) -> Void
    ) {
        self.context = context
        self.onSubmitted = onSubmitted
        if case .post(let defaultCommunity) = context {
            initialCommunity = defaultCommunity
            _community = State(initialValue: defaultCommunity)
        } else {
            initialCommunity = ""
            _community = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isPreviewing {
                    preview
                } else {
                    editor
                }
                formattingBar
            }
            .disabled(isSubmitting || isClosing)
            .navigationTitle(context.title)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        if hasContent || hasSavedDraft {
                            showingCloseOptions = true
                        } else {
                            dismiss()
                        }
                    }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isSubmitting || isClosing)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(isPreviewing ? "Edit" : "Preview") {
                        isPreviewing.toggle()
                    }
                    .disabled(isSubmitting || isClosing)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSubmitting ? "Sending..." : "Send") {
                        submit()
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!canSubmit || isSubmitting || isClosing)
                }
            }
        }
        .frame(minWidth: 580, idealWidth: 660, minHeight: 440, idealHeight: 560)
        .confirmationDialog("Keep this draft?", isPresented: $showingCloseOptions, titleVisibility: .visible) {
            if hasContent {
                Button("Save Draft") { closeDraft(save: true) }
            }
            Button("Discard", role: .destructive) { closeDraft(save: false) }
            Button("Keep Editing", role: .cancel) {}
        }
        .alert(
            errorTitle,
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .task {
            if !accountIsBound {
                draftAccountID = dependencies.accounts.selectedAccountID
                accountIsBound = true
                draftSession = ComposerDraftSession(persistence: dependencies.persistence)
            }
            await restoreDraft()
            bodyIsFocused = context.isComment
        }
        .interactiveDismissDisabled(hasContent || hasSavedDraft || isSubmitting || isClosing)
    }

    private var editor: some View {
        Form {
            switch context {
            case .post:
                Section("Post") {
                    TextField("Community", text: $community, prompt: Text("swift"))
                    Picker("Type", selection: $postKind) {
                        ForEach(PostKind.allCases) { kind in
                            Text(kind.rawValue).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    TextField("Title", text: $title, prompt: Text("A clear title"))
                    if postKind == .link {
                        TextField("Link", text: $linkText, prompt: Text("https://example.com"))
                    }
                }
                Section(postKind == .link ? "Optional text" : "Body") {
                    bodyEditor(placeholder: "Write your post...")
                }
                Section {
                    Toggle("Send me reply notifications", isOn: $sendReplies)
                }
            case .comment(_, let postTitle):
                Section("Commenting on") {
                    Text(postTitle)
                        .lineLimit(2)
                        .foregroundStyle(.secondary)
                }
                Section("Comment") {
                    bodyEditor(placeholder: "Write a comment...")
                }
            case .reply(_, let author):
                Section("Replying to") {
                    Text(author.isEmpty ? "Comment" : "u/\(author)")
                        .foregroundStyle(.secondary)
                }
                Section("Reply") {
                    bodyEditor(placeholder: "Write a reply...")
                }
            }
        }
        .formStyle(.grouped)
    }

    private var preview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if case .post = context, !title.isEmpty {
                    Text(title)
                        .font(.title2.weight(.semibold))
                }
                if case .post = context, postKind == .link, let linkURL {
                    Label(linkURL.absoluteString, systemImage: "link")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                RedditMarkdownView(
                    source: bodyText.isEmpty ? "Nothing to preview yet." : bodyText
                )
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(24)
        }
    }

    private func bodyEditor(placeholder: String) -> some View {
        TextEditor(text: $bodyText)
            .font(.body)
            .frame(minHeight: 210)
            .focused($bodyIsFocused)
            .overlay(alignment: .topLeading) {
                if bodyText.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary)
                        .padding(.top, 7)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
    }

    private var formattingBar: some View {
        HStack(spacing: 8) {
            formatButton("bold", label: "Bold", opening: "**", closing: "**")
            formatButton("italic", label: "Italic", opening: "*", closing: "*")
            formatButton("strikethrough", label: "Strikethrough", opening: "~~", closing: "~~")
            formatButton("text.quote", label: "Quote", opening: "> ", closing: "")
            formatButton("eye.slash", label: "Spoiler", opening: ">!", closing: "!<")
            formatButton("link", label: "Link", opening: "[", closing: "](url)")
            Spacer()
            Text("Markdown supported")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .disabled(isPreviewing)
    }

    private func formatButton(
        _ systemImage: String,
        label: String,
        opening: String,
        closing: String
    ) -> some View {
        Button(label, systemImage: systemImage) {
            let sample = "text"
            let prefix = bodyText.isEmpty ? "" : " "
            bodyText.append("\(prefix)\(opening)\(sample)\(closing)")
            bodyIsFocused = true
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .help(label)
    }

    private var canSubmit: Bool {
        switch context {
        case .post:
            return !normalizedCommunity.isEmpty
                && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (postKind == .text || linkURL != nil)
        case .comment, .reply:
            return !bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private var hasContent: Bool {
        !title.isEmpty || !bodyText.isEmpty || (context.isPost && postKind == .link && !linkText.isEmpty)
            || (context.isPost && community != initialCommunity && !community.isEmpty)
    }

    private var draftKind: DraftKind {
        context.isPost ? .post : .comment
    }

    private var draftTarget: String {
        switch context {
        case .post: community
        case .comment(let postID, _): IDNormalization.fullname(postID, kind: "t3")
        case .reply(let commentID, _): IDNormalization.fullname(commentID, kind: "t1")
        }
    }

    private func restoreDraft() async {
        guard !hasContent, !isClosing, let accountID = draftAccountID,
              let drafts = try? await dependencies.persistence.loadDrafts(accountID: accountID) else { return }
        let target = draftTarget
        let match = Draft.newestMatching(
            in: drafts,
            kind: draftKind,
            target: target,
            anyTargetWhenEmpty: context.isPost
        )
        guard let match, !hasContent, !isClosing else { return }
        draftID = match.id
        hasSavedDraft = true
        title = match.title
        bodyText = match.body
        if let restoredLink = match.link {
            linkText = restoredLink.absoluteString
            postKind = .link
        }
        if context.isPost, community.isEmpty { community = match.target ?? "" }
    }

    private func closeDraft(save: Bool) {
        guard !isClosing else { return }
        isClosing = true
        Task {
            do {
                guard let draftSession else { throw MacComposerDraftError.notReady }
                let operation: ComposerDraftSession.Finish
                if save && hasContent {
                    guard let draft = currentDraft else { throw MacComposerDraftError.accountRequired }
                    operation = .save(draft)
                } else {
                    operation = .discard
                }
                try await draftSession.finish(operation, id: draftID)
                dismiss()
            } catch {
                isClosing = false
                errorTitle = save ? "Could not save draft" : "Could not discard draft"
                errorMessage = error.localizedDescription
            }
        }
    }

    private var currentDraft: Draft? {
        guard hasContent, let accountID = draftAccountID else { return nil }
        return Draft(
            id: draftID,
            kind: draftKind,
            accountID: accountID,
            target: draftTarget,
            title: title,
            body: bodyText,
            link: postKind == .link ? URL(string: linkText) : nil,
            modifiedAt: .now
        )
    }

    private var normalizedCommunity: String {
        var value = community.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("r/") { value.removeFirst(2) }
        return value
    }

    private var linkURL: URL? {
        guard postKind == .link,
              let url = URL(string: linkText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else {
            return nil
        }
        return url
    }

    private func submit() {
        guard canSubmit, !isSubmitting, !isClosing else { return }
        guard let account = dependencies.accounts.selectedAccount,
              account.health != .needsLogin,
              account.id == draftAccountID else {
            errorTitle = "Could not send"
            errorMessage = "Select a signed-in Reddit account before sending."
            return
        }

        let action: RedditAction
        let result: MacComposerResult
        switch context {
        case .post:
            action = .submitPost(
                community: normalizedCommunity,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                text: bodyText.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                link: postKind == .link ? linkURL : nil,
                sendReplies: sendReplies
            )
            result = .post
        case .comment(let postID, _):
            action = .comment(
                thingID: IDNormalization.fullname(postID, kind: "t3"),
                text: bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            result = .comment
        case .reply(let commentID, _):
            action = .comment(
                thingID: IDNormalization.fullname(commentID, kind: "t1"),
                text: bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            result = .comment
        }

        isSubmitting = true
        let draftSession = self.draftSession
        Task {
            do {
                _ = try await dependencies.authenticated.perform(action, accountID: account.id)
                if let draftSession {
                    try? await draftSession.finish(.discard, id: draftID)
                } else {
                    try? await dependencies.persistence.deleteDraft(draftID)
                }
                isSubmitting = false
                dismiss()
                onSubmitted(result)
            } catch let error as RedditClientError where error == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(account.id)
                isSubmitting = false
                errorTitle = "Could not send"
                errorMessage = "Your Reddit session expired. Sign in again from Accounts."
            } catch {
                isSubmitting = false
                errorTitle = "Could not send"
                errorMessage = error.localizedDescription
            }
        }
    }
}

private extension MacComposerContext {
    var isPost: Bool {
        if case .post = self { return true }
        return false
    }

    var isComment: Bool {
        switch self {
        case .post: false
        case .comment, .reply: true
        }
    }
}

private enum MacComposerDraftError: LocalizedError {
    case accountRequired
    case notReady

    var errorDescription: String? {
        switch self {
        case .accountRequired: "Select a Reddit account before saving this draft."
        case .notReady: "Wait for the draft to finish loading, then try again."
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
