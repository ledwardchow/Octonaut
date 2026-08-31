import SwiftUI

@MainActor
struct MacSearchView: View {
    let model: SearchFeatureModel
    @Binding var selectedPost: PostCardModel?
    let openCommunity: (String) -> Void

    @State private var query = ""
    @State private var scope: FeatureSearchScope = .posts

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search Reddit", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { submit() }
                Button("Search", action: submit)
                    .keyboardShortcut(.return, modifiers: [])
            }
            .padding()

            Picker("Search", selection: $scope) {
                ForEach(FeatureSearchScope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.bottom)

            Divider()

            searchResults
        }
        .navigationTitle("Search")
    }

    @ViewBuilder
    private var searchResults: some View {
        switch model.state {
        case .idle:
            ContentUnavailableView(
                "Search Reddit",
                systemImage: "magnifyingglass",
                description: Text("Search posts, communities, or users.")
            )
        case .loading:
            ProgressView("Searching…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .empty:
            ContentUnavailableView.search(text: model.activeQuery)
        case .failed(let message):
            ContentUnavailableView(
                "Search failed",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .loaded:
            List {
                switch scope {
                case .posts:
                    ForEach(model.posts) { post in
                        Button { selectedPost = post } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(post.title).font(.headline)
                                Text("r/\(post.community) • \(post.score) points")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                case .communities:
                    ForEach(model.communities) { community in
                        Button { openCommunity(community.name) } label: {
                            Label("r/\(community.name)", systemImage: "person.3")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                case .users:
                    ForEach(model.users, id: \.reference.username) { user in
                        Link(
                            "u/\(user.reference.username)",
                            destination: URL(
                                string: "https://www.reddit.com/user/\(user.reference.username)"
                            )!
                        )
                    }
                }

                Button("Load More") {
                    Task { await model.loadMore() }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .listStyle(.inset)
        }
    }

    private func submit() {
        Task { await model.submit(query: query, scope: scope) }
    }
}
