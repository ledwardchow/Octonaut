import SwiftUI

@MainActor
struct AccountRootView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @State private var showingAddAccount = false
    @State private var logoutError: String?

    private var navigationTitle: String {
        guard dependencies.settings.showUsernameInAccountTab,
              let username = dependencies.accounts.selectedAccount?.username else { return "Accounts" }
        return username
    }

    var body: some View {
        Group {
            if let account = dependencies.accounts.selectedAccount, account.health == .needsLogin {
                NeedsLoginView(username: account.username) { showingAddAccount = true }
            } else if let account = dependencies.accounts.selectedAccount {
                UserProfileView(
                    username: account.username, store: store, router: router,
                    onAddAccount: { showingAddAccount = true }, onLogOut: logOut
                )
            } else {
                AccountManagerView(store: store) { showingAddAccount = true }
            }
        }
        .navigationTitle(navigationTitle)
        .toolbar {
            if dependencies.accounts.selectedAccount?.health != .healthy {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showingAddAccount = true } label: {
                        Image(systemName: "person.badge.plus")
                    }
                    .accessibilityLabel("Add Account")
                }
            }
        }
        .sheet(isPresented: $showingAddAccount) {
            RedditLoginView(accounts: dependencies.accounts)
        }
        .alert("Could not remove saved login", isPresented: Binding(
            get: { logoutError != nil },
            set: { if !$0 { logoutError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(logoutError ?? "")
        }
        .task { await dependencies.accounts.load() }
    }

    private func logOut() {
        Task {
            do {
                try await dependencies.accounts.logOut()
            } catch {
                logoutError = error.localizedDescription
            }
        }
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
    let store: OctonautFeatureStore
    let onAdd: () -> Void
    @Environment(AppDependencies.self) private var dependencies
    @State private var accountToRemove: Account?

    var body: some View {
        List {
            Text("You are not signed in.")
                .foregroundStyle(.secondary)
            Section {
                ForEach(dependencies.accounts.accounts) { account in
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.username).font(.body.weight(.semibold))
                            Text(account.health == .needsLogin ? "Needs sign in" : (dependencies.accounts.selectedAccountID == account.id ? "Selected" : "Saved account")).font(.caption).foregroundStyle(account.health == .needsLogin ? .red : .secondary)
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
                OctonautSectionHeader("Saved accounts")
            }
            Section {
                Button { onAdd() } label: { Label("Add Account", systemImage: "person.badge.plus") }
                Text("Account credentials are stored in the system Keychain. Octonaut never displays cookies or session secrets.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .confirmationDialog(
            "Remove this saved account?",
            isPresented: Binding(
                get: { accountToRemove != nil },
                set: { if !$0 { accountToRemove = nil } }
            ),
            presenting: accountToRemove
        ) { account in
            Button("Remove Account", role: .destructive) {
                Task { try? await dependencies.accounts.remove(account.id) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

private struct ProfileMessageRecipient: Identifiable, Sendable {
    let username: String
    var id: String { username }
}

@MainActor
struct UserProfileView: View {
    private enum ProfileSection: String, CaseIterable, Identifiable {
        case posts = "Posts"
        case comments = "Comments"

        var id: String { rawValue }
    }

    let username: String
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    var onAddAccount: (() -> Void)? = nil
    var onLogOut: (() -> Void)? = nil
    @Environment(AppDependencies.self) private var dependencies
    @Environment(\.openURL) private var openURL
    @State private var showingLogin = false
    @State private var messageRecipient: ProfileMessageRecipient?
    @State private var confirmingBlock = false
    @State private var actionInProgress = false
    @State private var profileActionError: String?
    @State private var selectedSection: ProfileSection = .posts

    /// Reddit serves Saved, Upvoted, Downvoted, and Hidden only to the account
    /// that owns them, so the rows appear on your own profile and nowhere else.
    private var isOwnProfile: Bool {
        guard let account = dependencies.accounts.selectedAccount, account.health == .healthy else {
            return false
        }
        return account.username.caseInsensitiveCompare(username) == .orderedSame
    }

    private var profile: UserProfile? {
        guard let profile = store.userProfile,
              profile.reference.username.caseInsensitiveCompare(username) == .orderedSame else { return nil }
        return profile
    }

    private var privateSections: [UserSection] {
        UserSection.allCases.filter(\.isPrivateToOwner)
    }

    var body: some View {
        List {
            profileHeader

            if isOwnProfile {
                Section {
                    ForEach(privateSections, id: \.self) { section in
                        NavigationLink(value: FeatureRoute.userSection(username: username, section: section)) {
                            Label(section.title, systemImage: section.systemImage)
                        }
                    }
                } header: {
                    OctonautSectionHeader("Your activity")
                }
            }

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
            case .loginRequired:
                RedditLoginRequiredView()
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
                    .listRowSeparator(.hidden)
                    .accessibilityLabel("Profile content")

                    profileContent
                }
            }
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(onAddAccount == nil ? .automatic : .hidden, for: .navigationBar)
        .refreshable {
            await store.loadUserProfile(username: username, forceRefresh: true)
        }
        .loginRequiredModal(isPresented: $showingLogin)
        .sheet(item: $messageRecipient) { recipient in
            NavigationStack {
                ComposerView(kind: .message, store: store, recipient: recipient.username)
            }
        }
        .confirmationDialog("\(profile?.isBlocked == true ? "Unblock" : "Block") u/\(username)?", isPresented: $confirmingBlock, titleVisibility: .visible) {
            Button(profile?.isBlocked == true ? "Unblock user" : "Block user", role: profile?.isBlocked == true ? nil : .destructive) {
                performProfileAction(.block(username: username, blocked: !(profile?.isBlocked ?? false)))
            }
        } message: {
            Text(profile?.isBlocked == true
                 ? "This unblocks the user on your selected Reddit account."
                 : "This blocks the user on your selected Reddit account.")
        }
        .alert("Profile action failed", isPresented: Binding(
            get: { profileActionError != nil },
            set: { if !$0 { profileActionError = nil } }
        )) {
            Button("OK", role: .cancel) { profileActionError = nil }
        } message: {
            Text(profileActionError ?? "")
        }
        .onChange(of: store.accountContextKey) { _, _ in
            messageRecipient = nil
            confirmingBlock = false
            profileActionError = nil
        }
        .task(id: "\(username):\(store.accountContextKey)") {
            await store.loadUserProfile(username: username)
        }
    }

    private var profileHeader: some View {
        Section {
            VStack(spacing: 10) {
                if let avatarURL = profile?.avatarURL {
                    OctonautAsyncImage(url: avatarURL)
                        .frame(width: 78, height: 78)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 74))
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                }
                Text("u/\(profile?.reference.username ?? username)")
                    .font(.title2.weight(.bold))
                if let profile {
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
                        if let url = OctonautUserDestination.profileURL(for: username) {
                            openURL(url)
                        }
                    } label: {
                        Label("Open Profile", systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                    Button {
                        if dependencies.accounts.selectedAccount?.health == .healthy {
                            messageRecipient = ProfileMessageRecipient(username: username)
                        } else {
                            showingLogin = true
                        }
                    } label: {
                        Label("Message", systemImage: "envelope")
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(actionInProgress)
                if !isOwnProfile {
                    HStack {
                        Button {
                            performProfileAction(.follow(username: username, following: !(profile?.isFollowing ?? false)))
                        } label: {
                            Label(profile?.isFollowing == true ? "Unfollow" : "Follow", systemImage: "person.badge.plus")
                        }
                        .buttonStyle(.bordered)
                        .disabled(actionInProgress || profile == nil || profile?.isBlocked == true)
                        Button(role: profile?.isBlocked == true ? nil : .destructive) {
                            if dependencies.accounts.selectedAccount?.health == .healthy {
                                confirmingBlock = true
                            } else {
                                showingLogin = true
                            }
                        } label: {
                            Label(profile?.isBlocked == true ? "Unblock" : "Block", systemImage: profile?.isBlocked == true ? "person.crop.circle.badge.checkmark" : "person.crop.circle.badge.xmark")
                        }
                        .buttonStyle(.bordered)
                        .disabled(actionInProgress || profile == nil)
                    }
                    if actionInProgress { ProgressView("Updating profile…") }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .overlay(alignment: .topTrailing) {
                if let onAddAccount {
                    Menu {
                        Button { router.push(.composer(.post)) } label: {
                            Label("New Post", systemImage: "square.and.pencil")
                        }
                        Button { onLogOut?() } label: {
                            Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        Button(action: onAddAccount) {
                            Label("Add Account", systemImage: "person.badge.plus")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.title3)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Account actions")
                }
            }
        }
    }

    @ViewBuilder
    private var profileContent: some View {
        switch selectedSection {
        case .posts:
            if store.userProfilePosts.isEmpty {
                Text("No posts to show.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.userProfilePosts) { post in
                    NavigationLink(value: FeatureRoute.post(post)) {
                        OctonautCompactPostRow(
                            post: post,
                            onUserOpen: { router.push($0) },
                            showsFlair: dependencies.settings.showPostFlair,
                            blursNSFW: dependencies.settings.blurNSFWMedia,
                            blursSpoilers: dependencies.settings.blurSpoilers
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 14))
                }
            }
        case .comments:
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

    private func performProfileAction(_ action: RedditAction) {
        guard let account = dependencies.accounts.selectedAccount, account.health == .healthy else {
            showingLogin = true
            return
        }
        guard !actionInProgress else { return }
        let token = dependencies.accounts.token(for: account.id)
        actionInProgress = true
        Task {
            defer { actionInProgress = false }
            do {
                try await store.performProfileAction(action, username: username, accountID: account.id)
            } catch {
                guard dependencies.accounts.isCurrent(token) else { return }
                if error as? RedditClientError == .authenticationRequired {
                    await dependencies.accounts.markNeedsLogin(account.id)
                    showingLogin = true
                } else {
                    profileActionError = error.localizedDescription
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
            RedditMarkdownView(source: comment.body)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .tint(.accentColor)
                .lineLimit(4)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Comment on \(comment.postTitle), \(comment.body)")
    }
}

/// One profile section listing: Saved, Upvoted, Downvoted, or Hidden. The rows
/// live here rather than on the store so pushing a second section on top of a
/// first cannot replace what is underneath it.
@MainActor
struct UserSectionView: View {
    let router: OctonautFeatureRouter
    let username: String
    let section: UserSection
    let store: OctonautFeatureStore
    @Environment(AppDependencies.self) private var dependencies
    @State private var content: UserSectionContent = .posts
    @State private var loadedContent: UserSectionContent?
    @State private var posts: [PostCardModel] = []
    @State private var comments: [UserCommentCardModel] = []
    @State private var nextPage: String?
    @State private var state: OctonautLoadState = .idle
    @State private var isLoadingMore = false
    @State private var actionError: String?

    private var offersContentPicker: Bool { section == .saved }

    private var emptyMessage: String {
        switch (section, content) {
        case (.saved, .posts): return "Posts you save appear here."
        case (.saved, .comments): return "Comments you save appear here."
        case (.upvoted, _): return "Posts you upvote appear here."
        case (.downvoted, _): return "Posts you downvote appear here."
        case (.hidden, _): return "Posts you hide appear here."
        default: return "Nothing to show."
        }
    }

    var body: some View {
        List {
            if offersContentPicker {
                Picker("Show", selection: $content) {
                    ForEach(UserSectionContent.allCases) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
                .accessibilityLabel("Saved content kind")
            }

            switch state {
            case .idle, .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading \(section.title.lowercased())…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .loginRequired:
                RedditLoginRequiredView()
            case .failed(let message):
                ContentUnavailableView {
                    Label("\(section.title) unavailable", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Retry") { Task { await load(forceRefresh: true) } }
                        .buttonStyle(.borderedProminent)
                }
            case .empty:
                Text(emptyMessage)
                    .foregroundStyle(.secondary)
            case .loaded:
                rows
                if nextPage != nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                    .onAppear { Task { await loadMore() } }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load(forceRefresh: true) }
        .task(id: taskID) { await load() }
        .alert(
            "Reddit could not be updated",
            isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })
        ) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
    }

    private var taskID: String {
        "\(username):\(section.rawValue):\(content.rawValue):\(store.accountContextKey)"
    }

    @ViewBuilder
    private var rows: some View {
        switch content {
        case .posts:
            ForEach(posts) { post in
                NavigationLink(value: FeatureRoute.post(post)) {
                    OctonautCompactPostRow(
                        post: post,
                        onUserOpen: { router.push($0) },
                        showsFlair: dependencies.settings.showPostFlair,
                        blursNSFW: dependencies.settings.blurNSFWMedia,
                        blursSpoilers: dependencies.settings.blurSpoilers
                    )
                }
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 14))
                .swipeActions(edge: .trailing) {
                    if section == .saved {
                        Button("Unsave", systemImage: "bookmark.slash", role: .destructive) {
                            unsave(post)
                        }
                    }
                }
            }
        case .comments:
            ForEach(comments) { comment in
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

    private func load(forceRefresh: Bool = false) async {
        if loadedContent != content {
            // Posts and comments are different rows; do not leave one kind on
            // screen while the other loads.
            posts = []
            comments = []
            nextPage = nil
            state = .loading
        } else if state != .loaded {
            state = .loading
        }
        do {
            let page = try await store.fetchUserSection(
                section, username: username, content: content, forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            posts = page.posts
            comments = page.comments
            nextPage = page.nextPage
            loadedContent = content
            state = (content == .posts ? posts.isEmpty : comments.isEmpty) ? .empty : .loaded
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            state = .failure(error)
        }
    }

    private func loadMore() async {
        guard let after = nextPage, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let page = try await store.fetchUserSection(
                section, username: username, content: content, after: after)
            guard !Task.isCancelled, nextPage == after else { return }
            let existingPosts = Set(posts.map(\.id))
            posts.append(contentsOf: page.posts.filter { !existingPosts.contains($0.id) })
            let existingComments = Set(comments.map(\.id))
            comments.append(contentsOf: page.comments.filter { !existingComments.contains($0.id) })
            nextPage = page.nextPage
        } catch {
            // Keep the rows that did arrive; pagination stops until the next pull.
            nextPage = nil
        }
    }

    private func unsave(_ post: PostCardModel) {
        guard let accountID = dependencies.accounts.selectedAccountID else { return }
        let token = dependencies.accounts.token(for: accountID)
        let context = taskID
        guard let removal = UserSectionPostRemoval(postID: post.id, posts: &posts) else { return }
        if posts.isEmpty { state = .empty }
        Task {
            do {
                try await store.setSaved(false, postID: post.id, accountID: accountID)
            } catch {
                guard dependencies.accounts.isCurrent(token), taskID == context else { return }
                removal.restore(in: &posts)
                state = .loaded
                if let clientError = error as? RedditClientError, clientError == .authenticationRequired {
                    await dependencies.accounts.markNeedsLogin(accountID)
                } else {
                    actionError = error.localizedDescription
                }
            }
        }
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
