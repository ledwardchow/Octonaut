import SwiftUI

@MainActor
struct SearchRootView: View {
    let store: LedditFeatureStore
    let router: LedditFeatureRouter
    @State private var query = ""
    @State private var scope: FeatureSearchScope = .posts
    @State private var submittedQuery = ""
    @State private var model: SearchFeatureModel

    init(store: LedditFeatureStore, router: LedditFeatureRouter, reddit: (any RedditClient)? = nil) {
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
                        LedditCommunityRow(community: community)
                    }
                    .listRowInsets(EdgeInsets())
                }
            } header: {
                LedditSectionHeader("Trending communities")
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
                        LedditPostRow(post: post)
                    }
                    .listRowInsets(EdgeInsets())
                    .onAppear {
                        if post.id == model.posts.last?.id { Task { await model.loadMore() } }
                    }
                }
            case .communities:
                ForEach(model.communities) { community in
                    NavigationLink(value: FeatureRoute.community(community.name)) {
                        LedditCommunityRow(community: community)
                    }
                    .listRowInsets(EdgeInsets())
                    .onAppear {
                        if community.id == model.communities.last?.id { Task { await model.loadMore() } }
                    }
                }
            case .users:
                ContentUnavailableView("No user results", systemImage: "person.crop.circle", description: Text("Reddit user search is not available in the public JSON endpoint."))
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
}
