import SwiftUI

@MainActor
struct SearchRootView: View {
    let store: OctonautFeatureStore
    let router: OctonautFeatureRouter
    @Environment(AppDependencies.self) private var dependencies
    @State private var query = ""
    @State private var scope: FeatureSearchScope = .posts
    @State private var submittedQuery = ""
    @State private var model: SearchFeatureModel

    init(store: OctonautFeatureStore, router: OctonautFeatureRouter, reddit: (any RedditClient)? = nil) {
        self.store = store
        self.router = router
        _model = State(initialValue: SearchFeatureModel(reddit: reddit ?? UnavailableRedditClient()))
    }

    var body: some View {
        Group {
            if submittedQuery.isEmpty {
                trending
            } else {
                results
            }
        }
        .navigationTitle("Search")
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search Reddit")
        .searchScopes($scope) {
            ForEach(FeatureSearchScope.allCases) { value in
                Text(value.rawValue).tag(value)
            }
        }
        .onSubmit(of: .search) {
            submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            Task { await model.submit(query: submittedQuery, scope: scope) }
        }
        .onChange(of: scope) { _, newScope in
            guard !submittedQuery.isEmpty else { return }
            Task { await model.submit(query: submittedQuery, scope: newScope) }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !query.isEmpty {
                    Button("Clear") {
                        query = ""
                        submittedQuery = ""
                        Task { await model.submit(query: "", scope: scope) }
                    }
                }
            }
        }
    }

    private var trending: some View {
        List {
            Section {
                ForEach(store.communities) { community in
                    NavigationLink(value: FeatureRoute.community(community.name)) {
                        OctonautCommunityRow(community: community)
                    }
                    .listRowInsets(EdgeInsets())
                }
            } header: {
                OctonautSectionHeader("Trending communities")
            }
            Section {
                Text("Search posts, communities, or users. Search terms stay on this device until you submit them to Reddit.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var results: some View {
        switch model.state {
        case .loading:
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching Reddit…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView("Search failed", systemImage: "wifi.exclamationmark", description: Text(message))
        case .empty, .idle:
            ContentUnavailableView.search(text: submittedQuery)
        case .loaded:
            loadedResults
        }
    }

    @ViewBuilder
    private var loadedResults: some View {
        List {
            switch scope {
            case .posts:
                ForEach(model.posts) { post in
                    NavigationLink(value: FeatureRoute.post(post)) {
                        OctonautPostRow(
                            post: post,
                            showsFlair: dependencies.settings.showPostFlair
                        )
                    }
                    .listRowInsets(EdgeInsets())
                    .onAppear {
                        if post.id == model.posts.last?.id { Task { await model.loadMore() } }
                    }
                }
            case .communities:
                ForEach(model.communities) { community in
                    NavigationLink(value: FeatureRoute.community(community.name)) {
                        OctonautCommunityRow(community: community)
                    }
                    .listRowInsets(EdgeInsets())
                    .onAppear {
                        if community.id == model.communities.last?.id { Task { await model.loadMore() } }
                    }
                }
            case .users:
                ForEach(model.users) { user in
                    NavigationLink(value: FeatureRoute.account(user.reference.username)) {
                        userRow(user)
                    }
                    .listRowInsets(EdgeInsets())
                }
            }
            if let paginationError = model.paginationError {
                VStack(alignment: .leading, spacing: 6) {
                    Label("More results could not be loaded", systemImage: "exclamationmark.triangle")
                    Text(paginationError)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Try again") { Task { await model.loadMore() } }
                        .font(.caption.weight(.semibold))
                }
                .padding(.vertical, 8)
                .listRowSeparator(.hidden)
            }
            HStack { Spacer(); ProgressView().opacity(0.001); Spacer() }
                .listRowSeparator(.hidden)
                .accessibilityHidden(true)
        }
        .listStyle(.plain)
    }

    private func userRow(_ user: UserProfile) -> some View {
        HStack(spacing: 12) {
            Group {
                if let avatarURL = user.avatarURL {
                    OctonautAsyncImage(url: avatarURL)
                } else {
                    Image(systemName: "person.crop.circle.fill")
                        .resizable()
                        .foregroundStyle(.orange)
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(user.reference.displayName)
                    .font(.body.weight(.semibold))
                if let about = user.about?.plainText, !about.isEmpty {
                    Text(about)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Reddit user")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
