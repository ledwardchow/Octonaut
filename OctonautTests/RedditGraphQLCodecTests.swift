import XCTest

@testable import Octonaut

final class RedditGraphQLCodecTests: XCTestCase {
    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testFeedIDsSkipAdsAndKeepLastAvailableCursor() throws {
        let response = data(#"{"data":{"allFeedV1":{"elements":{"edges":[{"node":{"groupId":"t3_first"}},{"node":{"id":"t3_second"}},{"node":{"groupId":"t3_second"}},{"node":{"groupId":"t3_ad","adPayload":{}}},{"node":{"groupId":"t5_community"}}]}}}}"#)
        XCTAssertEqual(try RedditGraphQLCodec.feedPostIDs(data: response), ["t3_first", "t3_second"])
        XCTAssertThrowsError(try RedditGraphQLCodec.feedPostIDs(data: data(#"{"data":{"allFeedV1":{}}}"#)))
        XCTAssertEqual(try RedditGraphQLCodec.feedPostIDs(data: data(#"{"data":{"allFeedV1":{"elements":{"edges":[]}}}}"#)), [])
    }

    func testPostsByIdsKeepsFeedOrderAndMapsMediaAndFlags() throws {
        let response = data(#"{"data":{"postsInfoByIds":[{"__typename":"SubredditPost","id":"t3_second","postTitle":"Second","permalink":"/r/pics/comments/second/second/","subreddit":{"name":"pics"},"createdAt":"2026-10-04T00:26:11.575000+0000","score":12,"commentCount":5,"voteState":"UP","isSaved":true,"isNsfw":true,"media":{"still":{"source":{"url":"https://i.redd.it/second.jpg","dimensions":{"width":800,"height":600}}}}},{"__typename":"UnavailablePost","id":"t3_missing"},{"__typename":"SubredditPost","id":"t3_first","postTitle":"First","permalink":"/r/videos/comments/first/first/","subreddit":{"name":"videos"},"media":{"streaming":{"hlsUrl":"https://v.redd.it/first/HLSPlaylist.m3u8","isGif":true,"dimensions":{"width":480,"height":720}}}}]}}"#)
        let posts = try RedditGraphQLCodec.posts(data: response, orderedIDs: ["t3_first", "t3_missing", "t3_second"])
        XCTAssertEqual(posts.map(\.id), ["first", "second"])
        XCTAssertEqual(posts[0].media.kind, "gif")
        XCTAssertEqual(posts[1].media.kind, "image")
        XCTAssertEqual(posts[1].score, 12)
        XCTAssertEqual(posts[1].vote, .upvoted)
        XCTAssertTrue(posts[1].isSaved)
        XCTAssertTrue(posts[1].isNSFW)
        XCTAssertEqual(posts[1].createdAt.timeIntervalSince1970, 1_791_073_571.575, accuracy: 0.001)
        XCTAssertThrowsError(try RedditGraphQLCodec.posts(data: data(#"{"data":{}}"#), orderedIDs: ["t3_first"]))
    }

    func testSearchPostCursorAndEmptyPage() throws {
        let response = data(#"{"data":{"search":{"general":{"posts":{"edges":[{"node":{"__typename":"SubredditPost","id":"t3_found","title":"Found","subreddit":{"name":"swift"}}},{"node":{"__typename":"AdPost","id":"t3_ad"}}],"pageInfo":{"hasNextPage":true,"endCursor":"opaque-cursor"}}}}}}"#)
        let listing = try RedditGraphQLCodec.searchPosts(data: response)
        XCTAssertEqual(listing.items.map(\.id), ["found"])
        XCTAssertEqual(listing.after, "opaque-cursor")
        let empty = try RedditGraphQLCodec.searchPosts(data: data(#"{"data":{"search":{"general":{"posts":{"edges":[],"pageInfo":{"hasNextPage":false,"endCursor":"stale"}}}}}}"#))
        XCTAssertTrue(empty.items.isEmpty)
        XCTAssertNil(empty.after)
        XCTAssertThrowsError(try RedditGraphQLCodec.searchPosts(data: data(#"{"data":{"search":{"general":{}}}}"#)))
        XCTAssertThrowsError(try RedditGraphQLCodec.searchPosts(data: data(#"{"data":{"search":{"general":{"posts":{"edges":[],"pageInfo":{"hasNextPage":true}}}}}}"#)))
    }

    func testCommunityAndUserSearchMapNodesAndCursor() throws {
        let communities = try RedditGraphQLCodec.communities(data: data(#"{"data":{"search":{"general":{"communities":{"edges":[{"node":{"__typename":"Subreddit","id":"t5_swift","name":"swift","title":"Swift","subscribersCount":42,"publicDescriptionText":"Discussion","styles":{"icon":"https://example.com/icon.png"}}},{"node":{"__typename":"Ad","name":"sponsored"}}],"pageInfo":{"hasNextPage":false}}}}}}"#))
        XCTAssertEqual(communities.items.map(\.reference.name), ["swift"])
        XCTAssertEqual(communities.items[0].subscribers, 42)
        XCTAssertNil(communities.after)

        let users = try RedditGraphQLCodec.users(data: data(#"{"data":{"search":{"general":{"authors":{"edges":[{"node":{"__typename":"Redditor","id":"t2_user","name":"ExampleUser","karma":{"total":900},"isFollowed":true,"profile":{"createdAt":"2026-10-04T00:26:11+00:00"}}},{"node":{"__typename":"Subreddit","name":"wrong"}}],"pageInfo":{"hasNextPage":true,"endCursor":"user-cursor"}}}}}}"#))
        XCTAssertEqual(users.items.map(\.reference.username), ["ExampleUser"])
        XCTAssertEqual(users.items[0].karma, 900)
        XCTAssertTrue(users.items[0].isFollowing)
        XCTAssertEqual(users.after, "user-cursor")
    }

    func testExternalLinkKeepsTargetWhenStillMediaIsPreview() throws {
        let response = data(#"{"data":{"postsInfoByIds":[{"__typename":"SubredditPost","id":"t3_link","title":"Article","subreddit":{"name":"news"},"url":"https://example.com/article","media":{"still":{"source":{"url":"https://preview.redd.it/preview.jpg","dimensions":{"width":640,"height":360}}}}}]}}"#)
        let post = try XCTUnwrap(RedditGraphQLCodec.posts(data: response, orderedIDs: ["t3_link"]).first)
        guard case .link(let target, let metadata) = post.media else {
            return XCTFail("Expected link media")
        }
        XCTAssertEqual(target.absoluteString, "https://example.com/article")
        XCTAssertEqual(metadata?.imageURL?.absoluteString, "https://preview.redd.it/preview.jpg")
    }

    func testGalleryPreservesOrderCaptionsAndDimensions() throws {
        let response = data(#"""
        {"data":{"postsInfoByIds":[{
          "__typename":"SubredditPost","id":"t3_gallery","title":"Gallery","subreddit":{"name":"pics"},
          "gallery":{"items":[
            {"id":"second","caption":"First caption","media":{"url":"https://i.redd.it/two.jpg","width":800,"height":1200,"small":{"url":"https://preview.redd.it/two.jpg"}}},
            {"id":"first","caption":"Second caption","media":{"url":"https://i.redd.it/one.jpg","width":1600,"height":900}}
          ]}
        }]}}
        """#)
        let post = try XCTUnwrap(RedditGraphQLCodec.posts(data: response, orderedIDs: ["t3_gallery"]).first)
        guard case .gallery(let items) = post.media else { return XCTFail("Expected a gallery") }
        XCTAssertEqual(items.map(\.id), ["second", "first"])
        XCTAssertEqual(items.map(\.caption), ["First caption", "Second caption"])
        XCTAssertEqual(items.map(\.width), [800, 1600])
        XCTAssertEqual(items.map(\.height), [1200, 900])
        XCTAssertEqual(items[0].thumbnailURL?.absoluteString, "https://preview.redd.it/two.jpg")
    }

    func testAnimatedMediaDeletedPostsAndCrossposts() throws {
        let response = data(#"""
        {"data":{"postsInfoByIds":[
          {"__typename":"SubredditPost","id":"t3_animation","title":"Animation","subreddit":{"name":"gifs"},"media":{"animated":{"mp4_source":{"url":"https://i.redd.it/animation.mp4"}}}},
          {"__typename":"DeletedSubredditPost","id":"t3_deleted","title":"Deleted","subreddit":{"name":"swift"}},
          {"__typename":"SubredditPost","id":"t3_cross","title":"Crosspost","subreddit":{"name":"pics"},"url":"https://www.reddit.com/r/original/comments/parent/","crosspostRoot":{"post":{
            "__typename":"SubredditPost","id":"t3_parent","title":"Original","subreddit":{"name":"original"},"permalink":"/r/original/comments/parent/","url":"https://i.redd.it/parent.jpg","media":{"still":{"source":{"url":"https://i.redd.it/parent.jpg","dimensions":{"width":400,"height":600}}}}
          }}}
        ]}}
        """#)
        let posts = try RedditGraphQLCodec.posts(data: response, orderedIDs: ["t3_animation", "t3_deleted", "t3_cross"])
        guard case .video(let url, _, _, let isGIF, _, _) = posts[0].media else { return XCTFail("Expected an animated video") }
        XCTAssertEqual(url.absoluteString, "https://i.redd.it/animation.mp4")
        XCTAssertTrue(isGIF)
        XCTAssertEqual(posts[1].body?.plainText, "[deleted]")
        XCTAssertEqual(posts[1].media, .none)
        XCTAssertEqual(posts[2].crosspost?.postID, "parent")
        XCTAssertEqual(posts[2].media.primaryURL?.absoluteString, "https://i.redd.it/parent.jpg")
    }

    func testPollAndTextFieldsSurviveSearchDecoding() throws {
        let response = data(#"""
        {"data":{"search":{"general":{"posts":{"edges":[{"node":{
          "__typename":"SubredditPost","id":"t3_poll","title":"Choose","subreddit":{"name":"swift"},
          "isSelfPost":true,"content":{"markdown":"Read **this** first."},"authorInfo":{"name":"reader"},
          "authorFlair":{"text":"Author"},"flair":{"text":"Discussion","template":{"id":"discussion"}},
          "poll":{"options":[{"id":"one","text":"First","voteCount":3},{"id":"two","text":"Second","voteCount":4}]}
        }}],"pageInfo":{"hasNextPage":false}}}}}}
        """#)
        let post = try XCTUnwrap(RedditGraphQLCodec.searchPosts(data: response).items.first)
        XCTAssertEqual(post.author?.username, "reader")
        XCTAssertEqual(post.authorFlair?.text, "Author")
        XCTAssertEqual(post.flair?.text, "Discussion")
        XCTAssertNotNil(post.body)
        guard case .poll(let poll) = post.media else { return XCTFail("Expected poll media") }
        XCTAssertEqual(poll.options.map(\.text), ["First", "Second"])
        XCTAssertEqual(poll.options.map(\.voteCount), [3, 4])
        XCTAssertEqual(poll.totalVoteCount, 7)
    }
}
