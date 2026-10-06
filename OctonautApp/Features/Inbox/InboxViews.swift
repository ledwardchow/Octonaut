import SwiftUI
import UIKit

@MainActor
struct InboxRootView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @State private var filter = "All"
    @State private var showingMarkAllRead = false
    @State private var selectedItem: InboxCardModel?
    @State private var isLoading = false
    @State private var loadError: String?
    @State private var nextInboxPage: String?
    @State private var loadMoreError: String?

    private var items: [InboxCardModel] {
        guard filter != "Unread" else { return store.inbox.filter(\.isUnread) }
        guard filter != "Messages" else { return store.inbox.filter { $0.kind == .message } }
        return store.inbox
    }

    var body: some View {
        Group {
            if dependencies.accounts.selectedAccount == nil {
                ContentUnavailableView("Sign in to view Inbox", systemImage: "envelope.badge", description: Text("Replies and private messages will appear here when you sign in."))
            } else if dependencies.accounts.selectedAccount?.health == .needsLogin {
                ContentUnavailableView("Sign in again", systemImage: "person.crop.circle.badge.exclamationmark", description: Text("This Reddit session has expired. Reauthenticate from the Account tab."))
            } else {
                List {
                    if isLoading && items.isEmpty {
                        ProgressView("Loading inbox…")
                    } else if let loadError, items.isEmpty {
                        ContentUnavailableView("Inbox unavailable", systemImage: "exclamationmark.triangle", description: Text(loadError))
                        Button("Try Again") { Task { await refreshLiveInbox() } }
                    } else if items.isEmpty {
                        ContentUnavailableView("Inbox is empty", systemImage: "tray", description: Text("New replies and messages will appear here."))
                            .listRowSeparator(.hidden)
                    }
                    ForEach(items) { item in
                        Button {
                            if item.isUnread { markRead(item) }
                            selectedItem = item
                        } label: {
                            inboxRow(item)
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets())
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button { markRead(item) } label: { Label(item.isUnread ? "Read" : "Unread", systemImage: item.isUnread ? "envelope.open" : "envelope.badge") }
                                .tint(.blue)
                        }
                        .contextMenu {
                            Button { markRead(item) } label: { Label(item.isUnread ? "Mark Read" : "Mark Unread", systemImage: "envelope") }
                        }
                    }
                    if let nextInboxPage, !items.isEmpty {
                        if let loadMoreError {
                            VStack(spacing: 6) {
                                Text(loadMoreError).font(.caption).foregroundStyle(.secondary)
                                Button("Load More") { Task { await loadMoreInbox() } }
                            }
                            .frame(maxWidth: .infinity)
                            .listRowSeparator(.hidden)
                        } else {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .listRowSeparator(.hidden)
                                .task(id: nextInboxPage) { await loadMoreInbox() }
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await refreshLiveInbox() }
            }
        }
        .navigationDestination(item: $selectedItem) { item in
            if item.kind == .message {
                ConversationView(itemID: item.conversationID ?? item.id, store: store, router: router, initialItem: item)
            } else {
                InboxDetailView(item: item, store: store, router: router)
            }
        }
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    ForEach(["All", "Unread", "Replies", "Post Replies", "Mentions", "Messages"], id: \.self) { value in
                        Button { filter = value } label: {
                            if filter == value { Label(value, systemImage: "checkmark") } else { Text(value) }
                        }
                    }
                } label: { Label(filter, systemImage: "line.3.horizontal.decrease.circle") }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if dependencies.accounts.selectedAccount?.health == .healthy {
                    Button { router.push(.composer(.message)) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("Compose message")
                }
                if store.unreadCount > 0 {
                    Button { showingMarkAllRead = true } label: { Image(systemName: "envelope.open") }
                        .accessibilityLabel("Mark all read")
                }
            }
        }
        .confirmationDialog("Mark every inbox item as read?", isPresented: $showingMarkAllRead, titleVisibility: .visible) {
            Button("Mark All Read") { markAllRead() }
            Button("Cancel", role: .cancel) {}
        }
        .onChange(of: dependencies.accounts.selectionGeneration) { selectedItem = nil }
        .task(id: inboxRefreshKey) { await refreshLiveInbox() }
    }

    private var inboxRefreshKey: String {
        "\(filter):\(dependencies.accounts.selectedAccountID?.description ?? "anonymous"):\(dependencies.accounts.selectionGeneration)"
    }

    private func refreshLiveInbox() async {
        guard let accountID = dependencies.accounts.selectedAccountID else {
            return
        }
        let token = dependencies.accounts.token(for: accountID)
        let refreshKey = inboxRefreshKey
        isLoading = true
        loadError = nil
        loadMoreError = nil
        nextInboxPage = nil
        defer { if refreshKey == inboxRefreshKey { isLoading = false } }
        do {
            let page = try await dependencies.authenticated.fetchInbox(section: sectionForFilter, accountID: accountID)
            guard dependencies.accounts.isCurrent(token), refreshKey == inboxRefreshKey, !Task.isCancelled else { return }
            store.inbox = page.items.map(cardModel)
            nextInboxPage = page.after
        } catch is CancellationError {
            return
        } catch {
            guard dependencies.accounts.isCurrent(token), refreshKey == inboxRefreshKey else { return }
            loadError = error.localizedDescription
            if error as? RedditClientError == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
            }
        }
    }

    /// Appends the next page of older items.
    private func loadMoreInbox() async {
        guard let accountID = dependencies.accounts.selectedAccountID, let after = nextInboxPage else { return }
        let token = dependencies.accounts.token(for: accountID)
        let refreshKey = inboxRefreshKey
        loadMoreError = nil
        do {
            let page = try await dependencies.authenticated.fetchInbox(section: sectionForFilter, after: after, accountID: accountID)
            guard dependencies.accounts.isCurrent(token), refreshKey == inboxRefreshKey,
                  nextInboxPage == after, !Task.isCancelled else { return }
            let existing = Set(store.inbox.map(\.id))
            store.inbox.append(contentsOf: page.items.map(cardModel).filter { !existing.contains($0.id) })
            nextInboxPage = page.after == after ? nil : page.after
        } catch is CancellationError {
            return
        } catch {
            guard dependencies.accounts.isCurrent(token), refreshKey == inboxRefreshKey else { return }
            loadMoreError = error.localizedDescription
            if error as? RedditClientError == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
            }
        }
    }

    private func cardModel(_ item: InboxItem) -> InboxCardModel {
        InboxCardModel(
            id: item.fullname,
            kind: item.kind.localizedCaseInsensitiveContains("message") ? .message : item.kind.localizedCaseInsensitiveContains("mention") ? .mention : .reply,
            title: item.subject,
            subtitle: [item.community.map { "r/\($0.name)" }, item.author.map { "u/\($0.username)" }].compactMap { $0 }.joined(separator: " • "),
            preview: item.body?.plainText ?? "",
            author: item.author?.username ?? "",
            age: item.createdAt.formatted(.relative(presentation: .named)),
            score: nil,
            isUnread: !item.isRead,
            postURL: item.postPermalink,
            conversationID: item.conversationFullname
        )
    }

    private var sectionForFilter: InboxSection {
        switch filter {
        case "Unread": return .unread
        case "Replies": return .replies
        case "Post Replies": return .postReplies
        case "Mentions": return .mentions
        case "Messages": return .messages
        default: return .all
        }
    }

    private func markRead(_ item: InboxCardModel) {
        let newReadState = item.isUnread
        if let index = store.inbox.firstIndex(where: { $0.id == item.id }) {
            store.inbox[index].isUnread = !newReadState
        }
        guard let accountID = dependencies.accounts.selectedAccountID else { return }
        Task {
            do {
                _ = try await dependencies.authenticated.perform(.markRead(fullname: item.id, read: newReadState), accountID: accountID)
            } catch let error as RedditClientError where error == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
                if let index = store.inbox.firstIndex(where: { $0.id == item.id }) { store.inbox[index].isUnread = newReadState }
            } catch {
                if let index = store.inbox.firstIndex(where: { $0.id == item.id }) { store.inbox[index].isUnread = newReadState }
            }
        }
    }

    private func markAllRead() {
        guard let accountID = dependencies.accounts.selectedAccountID else { return }
        Task {
            do {
                _ = try await dependencies.authenticated.perform(.markAllRead, accountID: accountID)
                store.markAllRead()
            } catch let error as RedditClientError where error == .authenticationRequired {
                await dependencies.accounts.markNeedsLogin(accountID)
            } catch {}
        }
    }

    private func inboxRow(_ item: InboxCardModel) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind == .message ? "envelope.fill" : item.kind == .mention ? "at" : "bubble.left.fill")
                .font(.title3)
                .foregroundStyle(item.isUnread ? .orange : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title).font(.subheadline.weight(item.isUnread ? .bold : .semibold)).foregroundStyle(.primary).lineLimit(2)
                    Spacer()
                    Text(item.age).font(.caption).foregroundStyle(.secondary)
                }
                Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Text(item.preview).font(.body).foregroundStyle(.primary).lineLimit(2)
                if let score = item.score { Label(score.formatted(), systemImage: "arrow.up") .font(.caption2).foregroundStyle(.secondary) }
            }
            if item.isUnread {
                Circle().fill(.orange).frame(width: 8, height: 8).padding(.top, 5)
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .padding(.horizontal)
        .padding(.vertical, 13)
        .contentShape(Rectangle())
        .background(item.isUnread ? Color.orange.opacity(0.07) : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: .separator)).frame(height: 0.5) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.kind == .message ? "Message" : "Reply"), \(item.title), \(item.age)")
    }
}

@MainActor
struct ConversationView: View {
    let itemID: String
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var initialItem: InboxCardModel? = nil
    @Environment(AppDependencies.self) private var dependencies
    @State private var composer: ComposerKind?
    @State private var messages: [Message] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if let initialItem, messages.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(initialItem.title).font(.headline)
                        Text(initialItem.subtitle).font(.caption).foregroundStyle(.secondary)
                        RedditMarkdownView(source: initialItem.preview).textSelection(.enabled)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if isLoading {
                    ProgressView("Loading conversation…")
                        .padding(.top, 40)
                } else if let errorMessage {
                    ContentUnavailableView(
                        "Conversation unavailable",
                        systemImage: "exclamationmark.bubble",
                        description: Text(errorMessage)
                    )
                    .padding(.top, 30)
                    Button("Try Again") { Task { await loadConversation() } }
                } else if messages.isEmpty && initialItem == nil {
                    ContentUnavailableView("No messages", systemImage: "bubble.left.and.bubble.right")
                        .padding(.top, 30)
                } else {
                    ForEach(messages) { message in
                        messageRow(message)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(initialItem?.title ?? "Conversation")
        .refreshable { await loadConversation() }
        .safeAreaInset(edge: .bottom) {
            Button { composer = .comment } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)
        }
        .sheet(item: $composer) { kind in
            // Replying to a private message uses /api/comment with the t4_ fullname.
            ComposerView(kind: kind, store: store, targetID: initialItem?.id ?? itemID) {
                Task { await loadConversation() }
            }
        }
        .task { await loadConversation() }
    }

    private func messageRow(_ message: Message) -> some View {
        let isMine = message.sender?.username.caseInsensitiveCompare(dependencies.accounts.selectedAccount?.username ?? "") == .orderedSame
        return HStack {
            if isMine { Spacer(minLength: 35) }
            VStack(alignment: isMine ? .trailing : .leading, spacing: 4) {
                Text(isMine ? "You" : message.sender?.displayName ?? "Reddit user")
                    .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                RedditMarkdownView(source: message.body.plainText)
                    .textSelection(.enabled)
                    .font(.body)
                    .foregroundStyle(isMine ? .white : .primary)
                    .padding(11)
                    .background(isMine ? Color.orange : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                Text(message.createdAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
            }
            if !isMine { Spacer(minLength: 35) }
        }
    }

    private func loadConversation() async {
        guard let accountID = dependencies.accounts.selectedAccountID else {
            isLoading = false
            errorMessage = "Sign in to load this conversation."
            return
        }
        let token = dependencies.accounts.token(for: accountID)
        isLoading = true
        defer { isLoading = false }
        errorMessage = nil
        do {
            let loaded = try await dependencies.authenticated.fetchConversation(messageID: itemID, accountID: accountID)
            guard dependencies.accounts.isCurrent(token), !Task.isCancelled else { return }
            messages = loaded.sorted { $0.createdAt < $1.createdAt }
        } catch is CancellationError {
            return
        } catch let error as RedditClientError where error == .authenticationRequired {
            guard dependencies.accounts.isCurrent(token) else { return }
            await dependencies.accounts.markNeedsLogin(accountID)
            errorMessage = error.localizedDescription
        } catch {
            guard dependencies.accounts.isCurrent(token) else { return }
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct InboxDetailView: View {
    let item: InboxCardModel
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @State private var composer: ComposerKind?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(item.title).font(.title2.bold())
                Text(item.subtitle).font(.subheadline).foregroundStyle(.secondary)
                Text(item.age).font(.caption).foregroundStyle(.secondary)
                RedditMarkdownView(source: item.preview).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let url = item.postURL {
                    Button { router.push(.postURL(url)) } label: {
                        Label("View discussion", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding()
        }
        .navigationTitle(item.kind == .mention ? "Mention" : "Reply")
        .safeAreaInset(edge: .bottom) {
            if item.id.hasPrefix("t1_") {
                Button { composer = .comment } label: {
                    Label("Reply", systemImage: "arrowshape.turn.up.left").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .padding()
                .background(.bar)
            }
        }
        .sheet(item: $composer) { kind in
            ComposerView(kind: kind, store: store, targetID: item.id)
        }
    }
}
