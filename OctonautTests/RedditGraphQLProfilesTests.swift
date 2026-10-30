import XCTest

@testable import Octonaut

final class RedditGraphQLProfilesTests: XCTestCase {
    private func data(_ value: String) -> Data { Data(value.utf8) }

    func testProfileMapsKarmaAndFollowState() throws {
        let profile = try RedditGraphQLCodec.userProfile(data: data(
            #"{"data":{"redditorInfoByName":{"__typename":"Redditor","id":"t2_abc","name":"Example","karma":{"fromPosts":12,"fromComments":8},"profile":{"createdAt":"2026-10-04T00:26:11+00:00","isSubscribed":true,"publicDescriptionText":"About"}}}}"#
        ))
        XCTAssertEqual(profile.reference.username, "Example")
        XCTAssertEqual(profile.karma, 20)
        XCTAssertEqual(profile.about?.plainText, "About")
        XCTAssertTrue(profile.isFollowing)
        XCTAssertThrowsError(try RedditGraphQLCodec.userProfile(data: data(#"{"data":{"redditorInfoByName":null}}"#)))
    }

    func testPostSectionKeepsServerCursorAfterFilteredNodes() throws {
        let page = try RedditGraphQLCodec.profilePostIDs(data: data(
            #"{"data":{"profileFeed":{"elements":{"edges":[{"node":{"groupId":"t3_one"}},{"node":{"groupId":"t3_one"}},{"node":{"groupId":"t3_ad","adPayload":{}}},{"node":{"groupId":"t1_comment"}}],"pageInfo":{"hasNextPage":true,"endCursor":"server-next"}}}}}"#
        ), section: .submitted)
        XCTAssertEqual(page.ids, ["t3_one"])
        XCTAssertEqual(page.after, "server-next")
    }

    func testSubmittedCommentsKeepOrderAfterHydration() throws {
        let page = try RedditGraphQLCodec.commentEdges(data: data(
            #"{"data":{"redditorInfoByName":{"comments":{"edges":[{"node":{"__typename":"Comment","id":"t1_one","postInfo":{"title":"First"}}},{"node":{"__typename":"Comment","id":"t1_two","postInfo":{"title":"Second"}}}],"pageInfo":{"hasNextPage":false}}}}}"#
        ), section: .comments)
        let comments = try RedditGraphQLCodec.hydratedUserComments(data: data(
            #"{"data":{"commentsByIds":[{"__typename":"Comment","id":"t1_two","permalink":"/r/swift/comments/post/title/two/","authorInfo":{"name":"Example"},"content":{"markdown":"Second body"}},{"__typename":"Comment","id":"t1_one","permalink":"/r/swift/comments/post/title/one/","authorInfo":{"name":"Example"},"content":{"markdown":"First body"}}]}}"#
        ), edges: page.edges)
        XCTAssertEqual(comments.map(\.id), ["one", "two"])
        XCTAssertEqual(comments.map(\.postTitle), ["First", "Second"])
        XCTAssertEqual(comments[0].body?.plainText, "First body")
    }

    func testSubscriptionsKeepFollowedUsersAndSeparateCursors() throws {
        let page = try RedditGraphQLCodec.subscriptions(data: data(
            #"{"data":{"identity":{"subscribedSubredditInfos":{"edges":[{"node":{"__typename":"Subreddit","id":"t5_swift","name":"swift","title":"Swift","isQuarantined":false}}],"pageInfo":{"hasNextPage":true,"endCursor":"sub-next"}},"followedRedditorsInfo":{"edges":[{"node":{"profile":{"name":"u_Example","redditorInfo":{"prefixedName":"u/Example"}}}}],"pageInfo":{"hasNextPage":false}}}}}"#
        ), fetchSubscribed: true, fetchFollowed: true)
        XCTAssertEqual(page.communities.map(\.reference.name), ["swift", "u_example"])
        XCTAssertEqual(page.subscribedAfter, "sub-next")
        XCTAssertNil(page.followedAfter)
    }
}
