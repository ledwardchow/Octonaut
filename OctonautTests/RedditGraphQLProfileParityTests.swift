import XCTest

@testable import Octonaut

final class RedditGraphQLProfileParityTests: XCTestCase {
    @MainActor
    func testInitialProfileCollectsFiftyUniquePostsAndComments() async throws {
        let client = ProfilePages(
            posts: [
                "": Listing(items: (0..<25).map(Self.post), after: "posts-2"),
                "posts-2": Listing(items: (24..<49).map(Self.post), after: "posts-3"),
                "posts-3": Listing(items: (49..<74).map(Self.post), after: "posts-4")
            ],
            comments: [
                "": Listing(items: (0..<25).map(Self.comment), after: "comments-2"),
                "comments-2": Listing(items: (24..<49).map(Self.comment), after: "comments-3"),
                "comments-3": Listing(items: (49..<74).map(Self.comment), after: "comments-4")
            ])
        let store = OctonautFeatureStore(reddit: client)
        await store.loadUserProfile(username: UUID().uuidString, forceRefresh: true)

        XCTAssertEqual(store.userProfilePosts.count, 50)
        XCTAssertEqual(Set(store.userProfilePosts.map(\.id)).count, 50)
        XCTAssertEqual(store.userProfileComments.count, 50)
        XCTAssertEqual(Set(store.userProfileComments.map(\.id)).count, 50)
        let requests = await client.requests()
        XCTAssertEqual(requests.posts, ["", "posts-2", "posts-3"])
        XCTAssertEqual(requests.comments, ["", "comments-2", "comments-3"])
    }

    @MainActor
    func testRepeatedCursorsStopBothProfileSections() async throws {
        let client = ProfilePages(
            posts: [
                "": Listing(items: (0..<25).map(Self.post), after: "repeat"),
                "repeat": Listing(items: (0..<25).map(Self.post), after: "repeat")
            ],
            comments: [
                "": Listing(items: (0..<25).map(Self.comment), after: "repeat"),
                "repeat": Listing(items: (0..<25).map(Self.comment), after: "repeat")
            ])
        let store = OctonautFeatureStore(reddit: client)
        await store.loadUserProfile(username: UUID().uuidString, forceRefresh: true)

        XCTAssertEqual(store.userProfilePosts.count, 25)
        XCTAssertEqual(store.userProfileComments.count, 25)
        let requests = await client.requests()
        XCTAssertEqual(requests.posts, ["", "repeat"])
        XCTAssertEqual(requests.comments, ["", "repeat"])
    }

    func testHydratedProfileCommentKeepsRichTextPostLinkAndFlags() throws {
        let response = Data(#"{"data":{"commentsByIds":[{"__typename":"Comment","id":"t1_reply","parentId":"t3_post","authorInfo":{"name":"alice"},"content":{"richtext":{"document":[{"e":"par","c":[{"e":"text","t":"Hello world","f":[[1,6,5]]}]}]}},"permalink":"/user/alice/comments/post/title/reply/","score":42,"isScoreHidden":true,"distinguishedAs":"MODERATOR"}]}}"#.utf8)
        let comments = try RedditGraphQLCodec.hydratedUserComments(
            data: response, edges: [.init(id: "t1_reply", postTitle: "Post title")])
        let comment = try XCTUnwrap(comments.first)
        XCTAssertEqual(comment.body?.plainText, "Hello **world**")
        XCTAssertEqual(comment.community?.name, "u_alice")
        XCTAssertEqual(comment.postPermalink?.path, "/user/alice/comments/post/title")
        XCTAssertNil(comment.score)
        XCTAssertTrue(comment.isDistinguished)
        XCTAssertEqual(comment.postTitle, "Post title")
    }

    private static func post(_ number: Int) -> Post {
        Post(id: "p\(number)", permalink: URL(string: "https://www.reddit.com/r/swift/comments/p\(number)/")!,
             community: CommunityReference(name: "swift"), title: "Post \(number)")
    }

    private static func comment(_ number: Int) -> UserComment {
        UserComment(id: "c\(number)", body: RichText(plainText: "Comment \(number)"))
    }
}

private actor ProfilePages: RedditClient {
    private let postPages: [String: Listing<Post>]
    private let commentPages: [String: Listing<UserComment>]
    private var postRequests: [String] = []
    private var commentRequests: [String] = []

    init(posts: [String: Listing<Post>], comments: [String: Listing<UserComment>]) {
        postPages = posts
        commentPages = comments
    }

    func requests() -> (posts: [String], comments: [String]) { (postRequests, commentRequests) }

    func listing(_ request: ListingRequest, account: AccountID?) async throws -> Listing<Post> {
        let cursor = request.after ?? ""
        postRequests.append(cursor)
        return postPages[cursor] ?? Listing(items: [])
    }

    func userComments(_ username: String, section: UserSection, after: String?, account: AccountID?) async throws -> Listing<UserComment> {
        let cursor = after ?? ""
        commentRequests.append(cursor)
        return commentPages[cursor] ?? Listing(items: [])
    }

    func userProfile(_ username: String, account: AccountID?) async throws -> UserProfile {
        UserProfile(reference: UserReference(username: username), avatarURL: nil, createdAt: nil,
                    karma: nil, about: nil, isBlocked: false, isFollowing: false)
    }

    func post(_ permalink: URL, sort: CommentSort, account: AccountID?) async throws -> PostThread { throw RedditClientError.malformedResponse }
    func moreComments(postFullname: String, parentFullname: String, continuation: CommentContinuation, sort: CommentSort, account: AccountID?) async throws -> [CommentTreeNode] { throw RedditClientError.malformedResponse }
    func search(_ request: RedditSearchRequest, account: AccountID?) async throws -> Listing<Post> { throw RedditClientError.malformedResponse }
    func communities(_ request: RedditCommunitySearchRequest, account: AccountID?) async throws -> Listing<Community> { throw RedditClientError.malformedResponse }
    func users(_ request: RedditUserSearchRequest, account: AccountID?) async throws -> Listing<UserProfile> { throw RedditClientError.malformedResponse }
    func trendingCommunities(limit: Int, account: AccountID?) async throws -> Listing<Community> { throw RedditClientError.malformedResponse }
    func subscribedCommunities(after: String?, account: AccountID) async throws -> Listing<Community> { throw RedditClientError.malformedResponse }
    func blockedUsers(after: String?, account: AccountID) async throws -> Listing<UserReference> { throw RedditClientError.malformedResponse }
    func perform(_ action: RedditAction, account: AccountID) async throws -> ActionResult { throw RedditClientError.malformedResponse }
}
