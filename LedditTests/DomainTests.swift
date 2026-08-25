import XCTest

@testable import Leddit

final class DomainTests: XCTestCase {
    @MainActor
    func testCommentTreeCanCollapseAndExpandParentAndNestedComments() {
        let store = LedditFeatureStore()
        store.comments = CommentCardModel.samples

        store.toggleComment(id: "t1_comment-1")
        XCTAssertTrue(store.comments[0].isCollapsed)

        store.toggleComment(id: "t1_comment-1")
        XCTAssertFalse(store.comments[0].isCollapsed)

        store.toggleComment(id: "t1_comment-1a")
        XCTAssertTrue(store.comments[0].children[0].isCollapsed)
    }

    @MainActor
    func testLoginFindsRedditSessionCookieAcrossRedditDomains() throws {
        let cookie = try XCTUnwrap(
            HTTPCookie(properties: [
                .name: "reddit_session",
                .value: "session-value",
                .domain: ".reddit.com",
                .path: "/",
            ]))

        XCTAssertEqual(RedditLoginModel.sessionCookie(from: [cookie])?.value, "session-value")
    }

    @MainActor
    func testSubscribedCommunitiesLoadAndRestoreAccountFavorites() async throws {
        let accountID = AccountID()
        UserDefaults.standard.set(["swift"], forKey: "communities.favorites.\(accountID.description)")
        defer {
            UserDefaults.standard.removeObject(forKey: "communities.favorites.\(accountID.description)")
        }
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t5","data":{"display_name":"Swift","display_name_prefixed":"r/Swift","subscribers":300000,"user_is_subscriber":true}}]}}"#
                .utf8)
        let client = FixtureRedditClient(communitiesData: data)
        let store = LedditFeatureStore(reddit: client, accountID: accountID)

        await store.refreshCommunities()

        XCTAssertEqual(store.communities.map(\.name), ["swift"])
        XCTAssertEqual(store.communities.first?.isSubscribed, true)
        XCTAssertEqual(store.communities.first?.isFavorite, true)
        XCTAssertEqual(store.communitiesState, .loaded)
    }

    func testCommunityNamesNormalizeForFeedIdentity() {
        let descriptor = FeedDescriptor(destination: .combined(["Swift", "r/iOS", "swift"]))
        XCTAssertEqual(descriptor.normalizedKey, "combined:swift+ios+swift")
        XCTAssertEqual(CommunityReference(name: "r/Swift").id, "swift")
    }

    func testUnknownSortValuesArePreserved() {
        let postSort = PostSort(rawValue: "future-sort")
        let commentSort = CommentSort(rawValue: "future-comment-sort")
        XCTAssertEqual(postSort.rawValue, "future-sort")
        XCTAssertEqual(commentSort.rawValue, "future-comment-sort")
    }

    func testPostMediaKeepsOriginalURL() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/asset.bin"))
        let media = PostMedia.unsupported(permalink: url, kind: "future_kind")
        XCTAssertEqual(media.primaryURL, url)
        XCTAssertEqual(media.kind, "unsupported")
    }

    func testFixtureContainsDeletedAndMoreCommentStates() {
        XCTAssertEqual(FixtureData.comments.count, 3)
        XCTAssertTrue(
            FixtureData.comments.contains {
                if case .more = $0 { return true }
                return false
            })
        XCTAssertTrue(
            FixtureData.comments.contains {
                if case .deleted = $0 { return true }
                return false
            })
    }

    func testRedditPostAndCommunityLinksBecomeFeatureRoutes() throws {
        let postURL = try XCTUnwrap(
            URL(string: "https://www.reddit.com/r/swift/comments/abc123/a-title"))
        let communityURL = try XCTUnwrap(URL(string: "https://www.reddit.com/r/Swift/"))

        guard case .postURL(let routedPost) = LedditFeatureURLRouter.route(postURL) else {
            return XCTFail("Expected a post route")
        }
        guard case .community(let community) = LedditFeatureURLRouter.route(communityURL) else {
            return XCTFail("Expected a community route")
        }

        XCTAssertEqual(routedPost, postURL)
        XCTAssertEqual(community, "Swift")
        XCTAssertEqual(PostCardModel(deepLinkURL: routedPost).id, "abc123")
    }

    func testShortAndDirectMediaLinksBecomeNativeRoutes() throws {
        let shortURL = try XCTUnwrap(URL(string: "https://redd.it/abc123"))
        let imageURL = try XCTUnwrap(URL(string: "https://i.redd.it/example.jpg"))
        let videoURL = try XCTUnwrap(URL(string: "https://v.redd.it/example"))

        guard case .postURL(let shortPostURL) = LedditFeatureURLRouter.route(shortURL) else {
            return XCTFail("Expected a short-link post route")
        }
        guard case .mediaURL(let routedImageURL) = LedditFeatureURLRouter.route(imageURL) else {
            return XCTFail("Expected an image route")
        }
        guard case .mediaURL(let routedVideoURL) = LedditFeatureURLRouter.route(videoURL) else {
            return XCTFail("Expected a video route")
        }

        XCTAssertEqual(shortPostURL.path, "/comments/abc123")
        XCTAssertEqual(routedImageURL, imageURL)
        XCTAssertEqual(routedVideoURL, videoURL)
    }

    func testCustomLedditRoutesAreRecognized() throws {
        let feedURL = try XCTUnwrap(URL(string: "leddit://feed/home"))
        let searchURL = try XCTUnwrap(URL(string: "leddit://search?q=swift%20concurrency"))
        let settingsURL = try XCTUnwrap(URL(string: "leddit://settings"))

        guard case .feed(let feed) = LedditFeatureURLRouter.route(feedURL) else {
            return XCTFail("Expected a feed route")
        }
        guard case .search(let query) = LedditFeatureURLRouter.route(searchURL) else {
            return XCTFail("Expected a search route")
        }
        guard case .settings(.general) = LedditFeatureURLRouter.route(settingsURL) else {
            return XCTFail("Expected a settings route")
        }

        XCTAssertEqual(feed, .home)
        XCTAssertEqual(query, "swift concurrency")
    }

    func testPostCardMapsGalleryAndVideoAudioURLs() throws {
        let imageURL = try XCTUnwrap(URL(string: "https://i.redd.it/one.jpg"))
        let secondURL = try XCTUnwrap(URL(string: "https://i.redd.it/two.jpg"))
        let audioURL = try XCTUnwrap(URL(string: "https://v.redd.it/audio.m4a"))
        let post = Post(
            id: "abc",
            permalink: URL(string: "https://www.reddit.com/r/swift/comments/abc")!,
            community: CommunityReference(name: "swift"),
            title: "Media",
            media: .video(url: imageURL, audioURL: audioURL, thumbnailURL: secondURL, isGIF: false)
        )

        let mapped = PostCardModel(post: post)
        XCTAssertEqual(mapped.mediaURL, imageURL)
        XCTAssertEqual(mapped.thumbnailURL, secondURL)
        XCTAssertEqual(mapped.audioURL, audioURL)
        XCTAssertEqual(mapped.mediaKind, "video")
    }

    func testPostCardDoesNotRepeatImageURLAsBodyText() throws {
        let imageURL = try XCTUnwrap(
            URL(string: "https://preview.redd.it/example.png?width=786&format=png&auto=webp")
        )
        let post = Post(
            id: "image-url-body",
            permalink: URL(string: "https://www.reddit.com/r/swift/comments/image-url-body")!,
            community: CommunityReference(name: "swift"),
            title: "Image",
            body: RichText(
                plainText: "  https://preview.redd.it/example.png?width=786&amp;format=png&amp;auto=webp\n"
            ),
            media: .image(url: imageURL, thumbnailURL: nil, width: nil, height: nil)
        )

        XCTAssertTrue(PostCardModel(post: post).body.isEmpty)
    }

    func testRedditGalleryMetadataBecomesOrderedNativeMedia() async throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"gallery1","name":"t3_gallery1","permalink":"/r/sydney/comments/gallery1/central_station/","title":"Central Station","subreddit":"sydney","url":"https://www.reddit.com/gallery/gallery1","is_self":false,"gallery_data":{"items":[{"media_id":"second","caption":"Police rescue"},{"media_id":"first"}]},"media_metadata":{"first":{"id":"first","s":{"u":"https://preview.redd.it/first.jpg?width=1200&amp;format=pjpg","x":1200,"y":900},"p":[{"u":"https://preview.redd.it/first-thumb.jpg?width=216&amp;crop=smart","x":216,"y":162}]},"second":{"id":"second","s":{"u":"https://preview.redd.it/second.jpg","x":1000,"y":1400},"p":[{"u":"https://preview.redd.it/second-thumb.jpg","x":216,"y":302}]}}}}]}}"#
                .utf8)
        let client = FixtureRedditClient(listingData: data)

        let listing = try await client.listing(
            ListingRequest(feed: FeedDescriptor(destination: .home)),
            account: nil
        )
        let post = try XCTUnwrap(listing.items.first)

        guard case .gallery(let items) = post.media else {
            return XCTFail("Expected gallery media")
        }
        XCTAssertEqual(items.map(\.id), ["second", "first"])
        XCTAssertEqual(items.first?.caption, "Police rescue")
        XCTAssertEqual(items.first?.width, 1000)
        XCTAssertEqual(
            items.last?.url.absoluteString, "https://preview.redd.it/first.jpg?width=1200&format=pjpg")

        let card = PostCardModel(post: post)
        XCTAssertEqual(card.mediaKind, "gallery")
        XCTAssertEqual(card.galleryURLs.count, 2)
        XCTAssertEqual(card.thumbnailURL?.absoluteString, "https://preview.redd.it/second-thumb.jpg")
    }

    func testRedditHostedVideoBecomesNativeVideoWithAudioAndPreview() async throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"video1","name":"t3_video1","permalink":"/r/videos/comments/video1/example/","title":"Example video","subreddit":"videos","url":"https://v.redd.it/clip123","is_self":false,"is_video":true,"post_hint":"hosted:video","secure_media":{"reddit_video":{"fallback_url":"https://v.redd.it/clip123/DASH_720.mp4?source=fallback","hls_url":"https://v.redd.it/clip123/HLSPlaylist.m3u8","has_audio":true,"is_gif":false}},"preview":{"images":[{"source":{"url":"https://preview.redd.it/clip123.jpg?width=1080&amp;format=pjpg"}}]}}}]}}"#
                .utf8)
        let client = FixtureRedditClient(listingData: data)

        let listing = try await client.listing(
            ListingRequest(feed: FeedDescriptor(destination: .home)),
            account: nil
        )
        let post = try XCTUnwrap(listing.items.first)

        guard case .video(let videoURL, let audioURL, let thumbnailURL, let isGIF) = post.media else {
            return XCTFail("Expected native video media")
        }
        XCTAssertEqual(videoURL.absoluteString, "https://v.redd.it/clip123/DASH_720.mp4?source=fallback")
        XCTAssertEqual(audioURL?.absoluteString, "https://v.redd.it/clip123/DASH_AUDIO_128.mp4?source=fallback")
        XCTAssertEqual(thumbnailURL?.absoluteString, "https://preview.redd.it/clip123.jpg?width=1080&format=pjpg")
        XCTAssertFalse(isGIF)
    }

    func testBareRedditVideoLinkUsesPlayableHLSURL() async throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"video2","name":"t3_video2","permalink":"/r/videos/comments/video2/example/","title":"Bare video","subreddit":"videos","url":"https://v.redd.it/clip456","is_self":false}}]}}"#
                .utf8)
        let client = FixtureRedditClient(listingData: data)

        let listing = try await client.listing(
            ListingRequest(feed: FeedDescriptor(destination: .home)),
            account: nil
        )
        let post = try XCTUnwrap(listing.items.first)

        guard case .video(let videoURL, _, _, _) = post.media else {
            return XCTFail("Expected a bare v.redd.it link to be treated as video")
        }
        XCTAssertEqual(videoURL.absoluteString, "https://v.redd.it/clip456/HLSPlaylist.m3u8")
    }

    func testCrosspostUsesParentRedditVideoPayload() async throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"crosspost1","name":"t3_crosspost1","permalink":"/r/funny/comments/crosspost1/example/","title":"Crossposted video","subreddit":"funny","url":"https://v.redd.it/parentclip","is_self":false,"crosspost_parent_list":[{"thumbnail":"https://preview.redd.it/parentclip.jpg","secure_media":{"reddit_video":{"fallback_url":"https://v.redd.it/parentclip/DASH_480.mp4","has_audio":false,"is_gif":false}}}]}}]}}"#
                .utf8)
        let client = FixtureRedditClient(listingData: data)

        let listing = try await client.listing(
            ListingRequest(feed: FeedDescriptor(destination: .home)),
            account: nil
        )
        let post = try XCTUnwrap(listing.items.first)

        guard case .video(let videoURL, _, let thumbnailURL, _) = post.media else {
            return XCTFail("Expected crosspost parent video media")
        }
        XCTAssertEqual(videoURL.absoluteString, "https://v.redd.it/parentclip/DASH_480.mp4")
        XCTAssertEqual(thumbnailURL?.absoluteString, "https://preview.redd.it/parentclip.jpg")
    }

    func testDirectImageURLInSelfTextBecomesNativeImage() async throws {
        let imageURL = "https://preview.redd.it/example.png?width=786&format=png&auto=webp&s=abc123"
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"body-image","name":"t3_body-image","permalink":"/r/anthropic/comments/body-image/post/","title":"Image in self text","subreddit":"anthropic","is_self":true,"url":"https://www.reddit.com/r/anthropic/comments/body-image/post/","selftext":"\#(imageURL)"}}]}}"#
                .utf8)
        let client = FixtureRedditClient(listingData: data)

        let listing = try await client.listing(
            ListingRequest(feed: FeedDescriptor(destination: .home)),
            account: nil
        )
        let post = try XCTUnwrap(listing.items.first)

        guard case .image(let decodedURL, _, _, _) = post.media else {
            return XCTFail("Expected image media")
        }
        XCTAssertEqual(decodedURL.absoluteString, imageURL)
        XCTAssertNil(post.body)

        let card = PostCardModel(post: post)
        XCTAssertEqual(card.mediaKind, "image")
        XCTAssertEqual(card.mediaURL?.absoluteString, imageURL)
        XCTAssertTrue(card.body.isEmpty)
    }

    func testUserProfileCodecPreservesKarmaAndAbout() throws {
        let data = Data(
            #"""
            {
              "name":"swift_reader",
              "icon_img":"https://example.com/avatar.png",
              "created_utc":1700000000,
              "total_karma":12345,
              "subreddit":{"public_description":"Swift and native UI."},
              "is_friend":true
            }
            """#.utf8)

        let profile = try RedditJSONCodec.decodeUserProfile(data)

        XCTAssertEqual(profile.reference.username, "swift_reader")
        XCTAssertEqual(profile.karma, 12_345)
        XCTAssertEqual(profile.about?.plainText, "Swift and native UI.")
        XCTAssertTrue(profile.isFollowing)
        XCTAssertEqual(profile.avatarURL?.host, "example.com")
    }

    func testUserCommentsCodecPreservesParentPostRoute() throws {
        let data = Data(
            #"""
            {
              "data": {
                "after": null,
                "before": null,
                "children": [{
                  "kind":"t1",
                  "data": {
                    "id":"comment-1",
                    "name":"t1_comment-1",
                    "author":"swift_reader",
                    "body":"A useful comment",
                    "score":42,
                    "created_utc":1700000000,
                    "link_title":"A native SwiftUI post",
                    "link_permalink":"/r/swift/comments/post-1/a-post/",
                    "subreddit":"swift",
                    "subreddit_name_prefixed":"r/swift"
                  }
                }]
              }
            }
            """#.utf8)

        let listing = try RedditJSONCodec.decodeUserComments(data)
        let comment = try XCTUnwrap(listing.items.first)
        let card = UserCommentCardModel(comment: comment)

        XCTAssertEqual(card.postTitle, "A native SwiftUI post")
        XCTAssertEqual(
            card.postURL?.absoluteString, "https://www.reddit.com/r/swift/comments/post-1/a-post/")
        XCTAssertEqual(card.community, "swift")
        XCTAssertEqual(card.score, 42)
    }
}
