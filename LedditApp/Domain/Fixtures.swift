import Foundation

enum FixtureData {
    static let community = CommunityReference(name: "swift", displayName: "r/Swift")
    static let author = UserReference(username: "leddit_reader")

    static let posts: [Post] = [
        Post(
            id: "fixture-swift-post",
            permalink: URL(string: "https://www.reddit.com/r/swift/comments/fixture-swift-post/native_swiftui/")!,
            community: community,
            author: author,
            title: "What native SwiftUI APIs are you using this week?",
            body: RichText(plainText: "A small fixture post with a body, a link, and a few comments for previews and tests."),
            flair: Flair(id: "discussion", text: "Discussion", backgroundColor: "#5E5CE6", textColor: "#FFFFFF"),
            createdAt: Date(timeIntervalSince1970: 1_724_000_000),
            score: 128,
            commentCount: 3,
            vote: .upvoted,
            isSaved: true,
            media: .link(
                url: URL(string: "https://developer.apple.com/documentation/swiftui")!,
                metadata: LinkMetadata(title: "SwiftUI - Apple Developer", description: "Build apps across Apple platforms.", siteName: "Apple Developer")
            )
        ),
        Post(
            id: "fixture-photo-post",
            permalink: URL(string: "https://www.reddit.com/r/iphone/comments/fixture-photo-post/a_photo/")!,
            community: CommunityReference(name: "iphone", displayName: "r/iPhone"),
            author: UserReference(username: "photographer"),
            title: "A quiet evening on the coast",
            body: nil,
            createdAt: Date(timeIntervalSince1970: 1_724_010_000),
            score: 2_401,
            commentCount: 84,
            media: .image(url: URL(string: "https://images.example.invalid/coast.jpg")!, thumbnailURL: nil, width: 1_600, height: 1_000)
        ),
        Post(
            id: "fixture-warning-post",
            permalink: URL(string: "https://www.reddit.com/r/swift/comments/fixture-warning-post/long_title/")!,
            community: community,
            author: nil,
            title: "This is a deliberately long fixture title that wraps across multiple lines so large text and compact feed rows can be checked",
            body: RichText(plainText: "The author has been deleted. The score is hidden and the post is marked as a spoiler."),
            createdAt: Date(timeIntervalSince1970: 1_724_020_000),
            score: nil,
            commentCount: 0,
            isNSFW: false,
            isSpoiler: true,
            media: .none
        )
    ]

    static let comments: [CommentTreeNode] = [
        .comment(
            CommentNode(
                id: "fixture-comment-1",
                fullname: "t1_fixture-comment-1",
                parentFullname: "t3_fixture-swift-post",
                author: UserReference(username: "first_reply"),
                body: RichText(plainText: "Observation has made this screen much easier to keep small."),
                createdAt: Date(timeIntervalSince1970: 1_724_000_300),
                score: 42,
                vote: .none,
                isSaved: false,
                isLocked: false,
                isDistinguished: false,
                children: []
            )
        ),
        .more(MoreCommentsNode(id: "more-fixture-comments", parentFullname: "t3_fixture-swift-post", childIDs: ["t1_fixture-comment-2", "t1_fixture-comment-3"], count: 2)),
        .deleted(DeletedCommentNode(id: "deleted-fixture-comment", parentFullname: "t3_fixture-swift-post", reason: "Comment removed"))
    ]

    static let thread = PostThread(post: posts[0], comments: comments)

    static let accounts: [Account] = [
        Account(username: "swift_reader", health: .healthy),
        Account(username: "media_reader", health: .needsLogin)
    ]

    static let listing = Listing(items: posts, after: "fixture-next-page")

    static func draft(accountID: AccountID? = nil) -> Draft {
        Draft(kind: .comment, accountID: accountID, target: posts[0].fullname, body: "A local draft that survives a restart.")
    }
}
