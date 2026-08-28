import Foundation
import Observation

enum SearchLoadState: Sendable, Equatable {
    case idle
    case loading
    case loaded
    case empty
    case failed(String)
}

@MainActor
@Observable
final class SearchFeatureModel {
    @ObservationIgnored private let reddit: any RedditClient
    @ObservationIgnored private var postsAfter: String?
    @ObservationIgnored private var communitiesAfter: String?
    @ObservationIgnored private var requestGeneration = 0

    var posts: [PostCardModel] = []
    var communities: [CommunityCardModel] = []
    var users: [UserProfile] = []
    var state: SearchLoadState = .idle
    var activeScope: FeatureSearchScope = .posts
    var activeQuery = ""
    var paginationError: String?

    init(reddit: any RedditClient) {
        self.reddit = reddit
    }

    func submit(query: String, scope: FeatureSearchScope) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        activeQuery = query
        activeScope = scope
        requestGeneration &+= 1
        let generation = requestGeneration
        postsAfter = nil
        communitiesAfter = nil
        paginationError = nil
        guard query.count >= 2 else {
            posts = []
            communities = []
            users = []
            state = query.isEmpty ? .idle : .empty
            return
        }
        state = .loading
        do {
            switch scope {
            case .posts:
                let listing = try await reddit.search(RedditSearchRequest(query: query, sort: .hot), account: nil)
                guard generation == requestGeneration else { return }
                paginationError = nil
                posts = listing.items.map(PostCardModel.init)
                postsAfter = listing.after
                communities = []
                users = []
                state = posts.isEmpty ? .empty : .loaded
            case .communities:
                let listing = try await reddit.communities(RedditCommunitySearchRequest(query: query), account: nil)
                guard generation == requestGeneration else { return }
                paginationError = nil
                communities = listing.items.map(CommunityCardModel.init)
                communitiesAfter = listing.after
                posts = []
                users = []
                state = communities.isEmpty ? .empty : .loaded
            case .users:
                let listing = try await reddit.users(RedditUserSearchRequest(query: query), account: nil)
                guard generation == requestGeneration else { return }
                paginationError = nil
                posts = []
                communities = []
                users = listing.items
                state = users.isEmpty ? .empty : .loaded
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            state = .failed(error.localizedDescription)
        }
    }

    func loadMore() async {
        guard state == .loaded, activeQuery.count >= 2 else { return }
        let generation = requestGeneration
        do {
            switch activeScope {
            case .posts:
                guard let postsAfter else { return }
                let listing = try await reddit.search(
                    RedditSearchRequest(query: activeQuery, sort: .hot, after: postsAfter),
                    account: nil
                )
                guard generation == requestGeneration else { return }
                let existing = Set(posts.map(\.id))
                posts.append(contentsOf: listing.items.filter { !existing.contains($0.id) }.map(PostCardModel.init))
                self.postsAfter = listing.after
            case .communities:
                guard let communitiesAfter else { return }
                let listing = try await reddit.communities(
                    RedditCommunitySearchRequest(query: activeQuery, after: communitiesAfter),
                    account: nil
                )
                guard generation == requestGeneration else { return }
                let existing = Set(communities.map(\.id))
                communities.append(contentsOf: listing.items.filter { !existing.contains($0.id) }.map(CommunityCardModel.init))
                self.communitiesAfter = listing.after
            case .users:
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            paginationError = error.localizedDescription
        }
    }
}
