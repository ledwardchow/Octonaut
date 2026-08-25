import SwiftUI

@MainActor
struct AccountRootView: View {
    let store: LedditFeatureStore
    let router: LedditFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingAddAccount = false

    var body: some View {
        Group {
            if let account = dependencies.accounts.selectedAccount, account.health == .needsLogin {
                NeedsLoginView(username: account.username) { showingAddAccount = true }
            } else if let account = dependencies.accounts.selectedAccount {
                UserProfileView(username: account.username, store: store, router: router)
            } else {
                AccountManagerView(store: store) { showingAddAccount = true }
            }
        }
        .navigationTitle(dependencies.accounts.selectedAccount?.username ?? "Accounts")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let account = dependencies.accounts.selectedAccount, account.health != .needsLogin {
                        Button { router.push(.composer(.post)) } label: { Label("New Post", systemImage: "square.and.pencil") }
                        Button {
                            dependencies.accounts.logOut()
                        } label: { Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right") }
                    }
                    Button { showingAddAccount = true } label: { Label("Add Account", systemImage: "person.badge.plus") }
                } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showingAddAccount) {
            RedditLoginView(accounts: dependencies.accounts)
        }
        .task { await dependencies.accounts.load() }
    }

}

@MainActor
private struct NeedsLoginView: View {
    let username: String
    let onSignInAgain: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Sign in again", systemImage: "person.crop.circle.badge.exclamationmark")
        } description: {
            Text("The saved Reddit session for u/\(username) has expired.")
        } actions: {
            Button("Sign In Again", action: onSignInAgain)
                .buttonStyle(.borderedProminent)
        }
    }
}

@MainActor
struct AccountManagerView: View {
    let store: LedditFeatureStore
    let onAdd: () -> Void
    @Environment(AppDependencies.self) private var dependencies
    @State private var accountToRemove: Account?

    var body: some View {
        List {
            Section {
                Button {
                    dependencies.accounts.logOut()
                } label: {
                    Label("Continue as Logged Out", systemImage: "person.crop.circle.badge.xmark")
                }
            } header: {
                LedditSectionHeader("Current session")
            }
            Section {
                ForEach(dependencies.accounts.accounts) { account in
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.username).font(.body.weight(.semibold))
                            Text(account.health == .needsLogin ? "Needs sign in" : "Ready").font(.caption).foregroundStyle(account.health == .needsLogin ? .red : .secondary)
                        }
                        Spacer()
                            if dependencies.accounts.selectedAccountID == account.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
                        }
                        .contentShape(Rectangle())
                    .onTapGesture {
                        Task { try? await dependencies.accounts.select(account.id) }
                    }
                    .swipeActions {
                        Button(role: .destructive) { accountToRemove = account } label: { Label("Remove", systemImage: "trash") }
                    }
                }
            } header: {
                LedditSectionHeader("Saved accounts")
            }
            Section {
                Button { onAdd() } label: { Label("Add Account", systemImage: "person.badge.plus") }
                Text("Account credentials are stored in the system Keychain. Leddit never displays cookies or session secrets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog("Remove this saved account?", item: $accountToRemove) { account in
            Button("Remove Account", role: .destructive) {
                Task { try? await dependencies.accounts.remove(account.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

@MainActor
struct UserProfileView: View {
    private enum ProfileSection: String, CaseIterable, Identifiable {
        case posts = "Posts"
        case comments = "Comments"

        var id: String { rawValue }
    }

    let username: String
    let store: LedditFeatureStore
    let router: LedditFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.openURL) private var openURL
    @State private var showingLogin = false
    @State private var selectedSection: ProfileSection = .posts

    var body: some View {
        List {
            profileHeader

            switch store.userProfileState {
            case .idle, .loading:
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading profile…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .failed(let message):
                Section {
                    ContentUnavailableView {
                        Label("Profile unavailable", systemImage: "person.crop.circle.badge.exclamationmark")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Retry") {
                            Task { await store.loadUserProfile(username: username) }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .loaded, .empty:
                Section {
                    Picker("Profile section", selection: $selectedSection) {
                        ForEach(ProfileSection.allCases) { section in
                            Text(section.rawValue).tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Profile content")
                }
                profileContent
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("u/\(username)")
        .sheet(isPresented: $showingLogin) {
            RedditLoginView(accounts: dependencies.accounts)
        }
        .task(id: "\(username):\(store.accountContextKey)") {
            await store.loadUserProfile(username: username)
        }
    }

    private var profileHeader: some View {
        Section {
            VStack(spacing: 10) {
                if let avatarURL = store.userProfile?.avatarURL {
                    LedditAsyncImage(url: avatarURL)
                        .frame(width: 78, height: 78)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 74))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text("u/\(store.userProfile?.reference.username ?? username)")
                    .font(.title2.weight(.bold))
                if let profile = store.userProfile {
                    HStack(spacing: 18) {
                        profileMetric(title: "Karma", value: profile.karma?.formatted() ?? "—")
                        if let createdAt = profile.createdAt {
                            profileMetric(title: "Joined", value: createdAt.formatted(date: .abbreviated, time: .omitted))
                        }
                    }
                    if let about = profile.about?.plainText, !about.isEmpty {
                        Text(about)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 420)
                    }
                } else {
                    Text("Reddit user")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        if let url = URL(string: "https://www.reddit.com/user/\(username)") {
                            openURL(url)
                        }
                    } label: {
                        Label("Open Profile", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        if dependencies.accounts.selectedAccount?.health == .healthy {
                            router.push(.composer(.message))
                        } else {
                            showingLogin = true
                        }
                    } label: {
                        Label("Message", systemImage: "envelope")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
        }
    }

    @ViewBuilder
    private var profileContent: some View {
        switch selectedSection {
        case .posts:
            Section("Posts") {
                if store.userProfilePosts.isEmpty {
                    Text("No posts to show.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.userProfilePosts) { post in
                        NavigationLink(value: FeatureRoute.post(post)) {
                            LedditCompactPostRow(post: post)
                        }
                        .listRowInsets(EdgeInsets())
                    }
                }
            }
        case .comments:
            Section("Comments") {
                if store.userProfileComments.isEmpty {
                    Text("No comments to show.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.userProfileComments) { comment in
                        if let postURL = comment.postURL {
                            NavigationLink(value: FeatureRoute.postURL(postURL)) {
                                UserCommentProfileRow(comment: comment)
                            }
                        } else {
                            UserCommentProfileRow(comment: comment)
                        }
                    }
                }
            }
        }
    }

    private func profileMetric(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UserCommentProfileRow: View {
    let comment: UserCommentCardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text("r/\(comment.community)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text("•")
                    .foregroundStyle(.tertiary)
                Text(comment.age)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("↑ \(comment.score.formatted())")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(comment.postTitle)
                .font(.subheadline.weight(.semibold))
                .lineLimit(2)
            Text(comment.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(4)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Comment on \(comment.postTitle), \(comment.body)")
    }
}

struct LoginPlaceholderView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ContentUnavailableView("Reddit Login", systemImage: "person.crop.circle.badge.plus", description: Text("The Reddit web login will open in an isolated session."))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}
