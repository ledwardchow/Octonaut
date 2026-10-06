import Observation
import SwiftUI

@MainActor
struct MacAccountsView: View {
    let accounts: AccountCoordinator
    @State private var showingLogin = false
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    Task {
                        do {
                            try await accounts.select(nil)
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    accountRow(title: "Anonymous", isSelected: accounts.selectedAccountID == nil)
                }
                .buttonStyle(.plain)

                ForEach(accounts.accounts) { account in
                    Button {
                        Task {
                            do {
                                try await accounts.select(account.id)
                            } catch {
                                errorMessage = error.localizedDescription
                            }
                        }
                    } label: {
                        accountRow(
                            title: "u/\(account.username)",
                            isSelected: accounts.selectedAccountID == account.id
                        )
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Remove Account", role: .destructive) {
                            Task {
                                do {
                                    try await accounts.remove(account.id)
                                } catch {
                                    errorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Reddit accounts")
                    Spacer()
                    Button {
                        showingLogin = true
                    } label: {
                        Label("Add Account", systemImage: "person.badge.plus")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } footer: {
                Text("Session cookies are stored in this Mac's Keychain.")
            }
        }
        .navigationTitle("Accounts")
        .sheet(isPresented: $showingLogin) {
            MacRedditLoginView(accounts: accounts)
                .frame(minWidth: 720, minHeight: 620)
        }
        .alert(
            "Account could not be updated",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
    }

    private func accountRow(title: String, isSelected: Bool) -> some View {
        HStack {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.secondary)
            Text(title)
            Spacer()
            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(.orange)
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }
}

@MainActor
struct MacInboxView: View {
    let accounts: AccountCoordinator
    let openDiscussion: (URL) -> Void
    @State private var selectedItem: InboxItem?
    @State private var model: MacInboxModel

    init(service: any AuthenticatedRedditService, accounts: AccountCoordinator, openDiscussion: @escaping (URL) -> Void) {
        self.accounts = accounts
        self.openDiscussion = openDiscussion
        _model = State(initialValue: MacInboxModel(service: service))
    }

    var body: some View {
        Group {
            if accounts.selectedAccountID == nil {
                ContentUnavailableView(
                    "Sign in to view your inbox",
                    systemImage: "person.crop.circle.badge.questionmark",
                    description: Text("Choose an account from the sidebar first.")
                )
            } else if model.isLoading && model.items.isEmpty {
                ProgressView("Loading inbox…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorMessage = model.errorMessage, model.items.isEmpty {
                ContentUnavailableView(
                    "Inbox unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorMessage)
                )
            } else if model.items.isEmpty {
                ContentUnavailableView("Inbox is empty", systemImage: "tray")
            } else {
                List(model.items) { item in
                    Button { selectedItem = item } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(item.subject).font(.headline)
                                    if !item.isRead {
                                        Circle().fill(.orange).frame(width: 7, height: 7)
                                    }
                                }
                                if let body = item.body?.plainText, !body.isEmpty {
                                    Text(body).lineLimit(3)
                                }
                                Text(metadata(for: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.inset)
            }
        }
        .sheet(item: $selectedItem) { item in
            MacInboxDetailView(item: item, model: model, accounts: accounts) { url in
                selectedItem = nil
                openDiscussion(url)
            }
        }
        .onChange(of: accounts.selectionGeneration) { selectedItem = nil }
        .navigationTitle("Inbox")
        .toolbar {
            ToolbarItem {
                Button {
                    load()
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(accounts.selectedAccountID == nil || model.isLoading)
            }
        }
        .task(id: accounts.selectionGeneration) {
            await model.load(accountID: accounts.selectedAccountID)
        }
    }

    private func load() {
        Task { await model.load(accountID: accounts.selectedAccountID) }
    }

    private func metadata(for item: InboxItem) -> String {
        let author = item.author.map { "u/\($0.username)" } ?? "Reddit"
        let community = item.community.map { "r/\($0.name)" }
        let age = item.createdAt.formatted(.relative(presentation: .named))
        return [community, author, age].compactMap { $0 }.joined(separator: " • ")
    }
}

@MainActor
@Observable
private final class MacInboxModel {
    @ObservationIgnored private let service: any AuthenticatedRedditService
    private(set) var items: [InboxItem] = []
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var loadID = UUID()
    @ObservationIgnored private var loadedAccountID: AccountID?

    init(service: any AuthenticatedRedditService) {
        self.service = service
    }

    func conversation(for item: InboxItem, accountID: AccountID) async throws -> [Message] {
        try await service.fetchConversation(messageID: item.conversationFullname ?? item.fullname, accountID: accountID)
    }

    func markRead(_ item: InboxItem, accountID: AccountID) async throws {
        guard !item.isRead else { return }
        let result = try await service.perform(.markRead(fullname: item.fullname, read: true), accountID: accountID)
        guard result.succeeded, loadedAccountID == accountID else { return }
        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].isRead = true }
    }

    func load(accountID: AccountID?) async {
        let requestID = UUID()
        loadID = requestID
        if loadedAccountID != accountID { items = [] }
        loadedAccountID = accountID
        guard let accountID else {
            isLoading = false
            items = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { if loadID == requestID { isLoading = false } }
        do {
            let loaded = try await service.fetchInbox(section: .all, accountID: accountID).items
            guard loadID == requestID, !Task.isCancelled else { return }
            items = loaded
        } catch is CancellationError {
            return
        } catch {
            guard loadID == requestID else { return }
            items = []
            errorMessage = error.localizedDescription
        }
    }
}

@MainActor
private struct MacInboxDetailView: View {
    let item: InboxItem
    let model: MacInboxModel
    let accounts: AccountCoordinator
    let openDiscussion: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var messages: [Message] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.subject).font(.headline)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding()
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if messages.isEmpty {
                        Text(item.author.map { "u/\($0.username)" } ?? "Reddit").foregroundStyle(.secondary)
                        RedditMarkdownView(source: item.body?.plainText ?? "").textSelection(.enabled)
                    } else {
                        ForEach(messages) { message in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(message.sender.map { "u/\($0.username)" } ?? "Reddit").font(.headline)
                                RedditMarkdownView(source: message.body.plainText).textSelection(.enabled)
                                Text(message.createdAt.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Divider()
                        }
                    }
                    if isLoading { ProgressView("Loading conversation…") }
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.secondary)
                        Button("Try Again") { Task { await load() } }
                    }
                    if let url = item.postPermalink {
                        Button("View discussion") { openDiscussion(url) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
        }
        .frame(minWidth: 480, idealWidth: 600, minHeight: 400, idealHeight: 600)
        .task { await load() }
    }

    private func load() async {
        guard let accountID = accounts.selectedAccountID else { return }
        let token = accounts.token(for: accountID)
        errorMessage = nil
        isLoading = item.kind == "message"
        defer { isLoading = false }
        do {
            if item.kind == "message" {
                let loaded = try await model.conversation(for: item, accountID: accountID)
                guard accounts.isCurrent(token), !Task.isCancelled else { return }
                messages = loaded.sorted { $0.createdAt < $1.createdAt }
            }
            try await model.markRead(item, accountID: accountID)
        } catch is CancellationError {
            return
        } catch {
            guard accounts.isCurrent(token) else { return }
            errorMessage = error.localizedDescription
            if error as? RedditClientError == .authenticationRequired { await accounts.markNeedsLogin(accountID) }
        }
    }
}
