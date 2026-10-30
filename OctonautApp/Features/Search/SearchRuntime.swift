import Foundation
import Observation

typealias SearchLoadState = OctonautLoadState

@MainActor
@Observable
final class SearchFeatureModel {
    @ObservationIgnored private let reddit: any RedditClient
    @ObservationIgnored private var postsAfter: String?
    @ObservationIgnored private var communitiesAfter: String?
    @ObservationIgnored private var requestGeneration = 0

    private var accountID: AccountID?
    private var trendingGeneration = 0

    var posts: [PostCardModel] = []
    var communities: [CommunityCardModel] = []
    var trendingCommunities: [CommunityCardModel] = []
    var users: [UserProfile] = []
    var state: SearchLoadState = .idle
    var trendingState: SearchLoadState = .idle
    var activeScope: FeatureSearchScope = .posts
    var activeQuery = ""
    var paginationError: String?
    private(set) var isLoadingMore = false

    var hasMoreResults: Bool {
        switch activeScope {
        case .posts: postsAfter != nil
        case .communities: communitiesAfter != nil
        case .users: false
        }
    }

    init(reddit: any RedditClient) {
        self.reddit = reddit
    }

    func invalidateForAccountChange() {
        isLoadingMore = false
        requestGeneration &+= 1
        trendingGeneration &+= 1
        trendingCommunities.removeAll()
        trendingState = .idle
        postsAfter = nil
        communitiesAfter = nil
        posts.removeAll()
        communities.removeAll()
        users.removeAll()
        state = .idle
    }

    func loadTrendingCommunities(forceRefresh: Bool = false, account: AccountID? = nil) async {
        if !forceRefresh, trendingState == .loading || trendingState == .loaded { return }
        trendingGeneration &+= 1
        let generation = trendingGeneration
        trendingState = .loading
        do {
            let listing = try await reddit.trendingCommunities(limit: 25, account: account)
            guard !Task.isCancelled, generation == trendingGeneration else { return }
            trendingCommunities = listing.items.map(CommunityCardModel.init)
            trendingState = trendingCommunities.isEmpty ? .empty : .loaded
        } catch is CancellationError {
            guard generation == trendingGeneration else { return }
            trendingState = trendingCommunities.isEmpty ? .idle : .loaded
            return
        } catch {
            guard generation == trendingGeneration else { return }
            trendingState = .failure(error)
        }
    }

    func submit(query: String, scope: FeatureSearchScope, account: AccountID? = nil) async {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        accountID = account
        activeQuery = query
        activeScope = scope
        requestGeneration &+= 1
        let generation = requestGeneration
        isLoadingMore = false
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
                let listing = try await reddit.search(RedditSearchRequest(query: query, sort: .hot), account: accountID)
                guard generation == requestGeneration else { return }
                paginationError = nil
                posts = listing.items.map(PostCardModel.init)
                postsAfter = listing.after
                communities = []
                users = []
                state = posts.isEmpty && listing.after == nil ? .empty : .loaded
            case .communities:
                let listing = try await reddit.communities(RedditCommunitySearchRequest(query: query), account: accountID)
                guard generation == requestGeneration else { return }
                paginationError = nil
                communities = listing.items.map(CommunityCardModel.init)
                communitiesAfter = listing.after
                posts = []
                users = []
                state = communities.isEmpty && listing.after == nil ? .empty : .loaded
            case .users:
                let listing = try await reddit.users(RedditUserSearchRequest(query: query), account: accountID)
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
            state = .failure(error)
        }
    }

    func loadMore() async {
        guard state == .loaded, activeQuery.count >= 2, hasMoreResults, !isLoadingMore else { return }
        let generation = requestGeneration
        isLoadingMore = true
        paginationError = nil
        defer { if generation == requestGeneration { isLoadingMore = false } }
        do {
            switch activeScope {
            case .posts:
                guard let postsAfter else { return }
                let listing = try await reddit.search(
                    RedditSearchRequest(query: activeQuery, sort: .hot, after: postsAfter),
                    account: accountID
                )
                guard generation == requestGeneration else { return }
                let existing = Set(posts.map(\.id))
                posts.append(contentsOf: listing.items.filter { !existing.contains($0.id) }.map(PostCardModel.init))
                self.postsAfter = listing.after == postsAfter ? nil : listing.after
                state = posts.isEmpty && self.postsAfter == nil ? .empty : .loaded
            case .communities:
                guard let communitiesAfter else { return }
                let listing = try await reddit.communities(
                    RedditCommunitySearchRequest(query: activeQuery, after: communitiesAfter),
                    account: accountID
                )
                guard generation == requestGeneration else { return }
                let existing = Set(communities.map(\.id))
                communities.append(contentsOf: listing.items.filter { !existing.contains($0.id) }.map(CommunityCardModel.init))
                self.communitiesAfter = listing.after == communitiesAfter ? nil : listing.after
                state = communities.isEmpty && self.communitiesAfter == nil ? .empty : .loaded
            case .users:
                return
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == requestGeneration else { return }
            paginationError = error.localizedDescription
            if OctonautLoadState.failure(error) == .loginRequired { state = .loginRequired }
        }
    }
}
