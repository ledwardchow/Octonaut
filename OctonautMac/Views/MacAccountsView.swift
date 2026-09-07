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
    @State private var model: MacInboxModel

    init(service: any AuthenticatedRedditService, accounts: AccountCoordinator) {
        self.accounts = accounts
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
                }
                .listStyle(.inset)
            }
        }
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

    init(service: any AuthenticatedRedditService) {
        self.service = service
    }

    func load(accountID: AccountID?) async {
        guard let accountID else {
            items = []
            errorMessage = nil
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            items = try await service.fetchInbox(section: .all, accountID: accountID).items
        } catch is CancellationError {
            return
        } catch {
            items = []
            errorMessage = error.localizedDescription
        }
    }
}
