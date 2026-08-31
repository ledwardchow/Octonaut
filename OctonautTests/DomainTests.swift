import AVFoundation
import XCTest

@testable import Octonaut

final class DomainTests: XCTestCase {
    @MainActor
    func testPostsSplitStateRoutesFeedsAndPostsToTheirColumns() throws {
        let state = PostsSplitState()
        let post = PostCardModel.sample

        XCTAssertFalse(state.select(.post(post)))
        XCTAssertEqual(state.sidebarCommunity, post.community)

        XCTAssertTrue(state.select(.community("swift")))
        XCTAssertEqual(state.selectedFeed.kind, .community)
        XCTAssertEqual(state.selectedFeed.name, "swift")
        XCTAssertEqual(state.sidebarCommunity, "swift")

        let url = try XCTUnwrap(URL(string: "https://www.reddit.com/r/apple/comments/example"))
        XCTAssertFalse(state.select(.postURL(url)))
        XCTAssertEqual(state.sidebarCommunity, "apple")
        XCTAssertFalse(state.select(.web(url)))
        XCTAssertEqual(state.sidebarCommunity, "apple")

        state.updateContext(for: nil)
        XCTAssertEqual(state.sidebarCommunity, "swift")
    }

    @MainActor
    func testVideoPlayerDoesNotPublishSystemNowPlayingControls() {
        let controller = OctonautSystemIsolatedVideoPlayer.makeViewController(
            player: AVPlayer(),
            showsPlaybackControls: true
        )

        XCTAssertFalse(controller.updatesNowPlayingInfoCenter)
        XCTAssertFalse(controller.allowsPictureInPicturePlayback)
    }

    func testVideoAutoplayPolicyHonorsSettingAndConnection() {
        XCTAssertFalse(AutoplayVideo.never.shouldAutoplay(isConnectedViaWiFi: true))
        XCTAssertFalse(AutoplayVideo.wifi.shouldAutoplay(isConnectedViaWiFi: false))
        XCTAssertTrue(AutoplayVideo.wifi.shouldAutoplay(isConnectedViaWiFi: true))
        XCTAssertTrue(AutoplayVideo.always.shouldAutoplay(isConnectedViaWiFi: false))
    }

    func testRedditMediaDownloadUsesWebsiteHeadersWithoutCredentials() throws {
        let url = try XCTUnwrap(URL(string: "https://v.redd.it/clip/DASH_720.mp4?source=fallback"))

        let request = try MediaDownloadTransport.request(for: url)

        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNotNil(request.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://www.reddit.com/")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    }

    func testMediaDownloadRejectsNonHTTPSURL() throws {
        let url = try XCTUnwrap(URL(string: "http://v.redd.it/clip/DASH_720.mp4"))

        XCTAssertThrowsError(try MediaDownloadTransport.request(for: url))
    }

    func testMediaDownloadRejectsPermissionResponse() throws {
        let url = try XCTUnwrap(URL(string: "https://v.redd.it/clip/DASH_720.mp4"))
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 403,
                httpVersion: nil,
                headerFields: ["Content-Type": "text/html"]
            )
        )

        XCTAssertThrowsError(try MediaDownloadTransport.validate(response))
    }

    func testRedditDASHManifestSelectsHighestQualityTracks() throws {
        let mediaURL = try XCTUnwrap(
            URL(string: "https://v.redd.it/clip123/HLSPlaylist.m3u8?source=fallback")
        )
        let manifestURL = try XCTUnwrap(RedditDASHManifest.manifestURL(for: mediaURL))
        let manifest = Data(
            #"""
            <MPD>
              <Period>
                <AdaptationSet mimeType="video/mp4">
                  <Representation bandwidth="400000" height="360"><BaseURL>DASH_360.mp4</BaseURL></Representation>
                  <Representation bandwidth="1200000" height="720"><BaseURL>DASH_720.mp4</BaseURL></Representation>
                </AdaptationSet>
                <AdaptationSet mimeType="audio/mp4">
                  <Representation bandwidth="64000"><BaseURL>DASH_AUDIO_64.mp4</BaseURL></Representation>
                  <Representation bandwidth="128000"><BaseURL>DASH_AUDIO_128.mp4</BaseURL></Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """#.utf8
        )

        let media = try XCTUnwrap(RedditDASHManifest.media(from: manifest, manifestURL: manifestURL))

        XCTAssertEqual(manifestURL.absoluteString, "https://v.redd.it/clip123/DASHPlaylist.mpd")
        XCTAssertEqual(media.video.absoluteString, "https://v.redd.it/clip123/DASH_720.mp4")
        XCTAssertEqual(media.audio?.absoluteString, "https://v.redd.it/clip123/DASH_AUDIO_128.mp4")
    }

    func testCrosspostBuildsWebsiteSubmitRequest() {
        let post = PostCardModel(post: FixtureData.posts[0])
        let request = URLSessionRedditClient.mutationRequest(
            for: .crosspost(
                community: "swift",
                title: post.title,
                sourceFullname: post.fullname,
                sendReplies: true
            )
        )

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/submit")
        XCTAssertEqual(request.fields["sr"], "swift")
        XCTAssertEqual(request.fields["title"], post.title)
        XCTAssertEqual(request.fields["kind"], "crosspost")
        XCTAssertEqual(request.fields["crosspost_fullname"], FixtureData.posts[0].fullname)
        XCTAssertEqual(request.fields["sendreplies"], "true")
        XCTAssertEqual(request.fields["api_type"], "json")
    }

    func testUserSearchBuildsPublicWebsiteJSONRoute() {
        let route = URLSessionRedditClient.userSearchRoute(
            for: RedditUserSearchRequest(query: "swift reader", limit: 500)
        )
        let query = Dictionary(uniqueKeysWithValues: route.query.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(route.path, "/users/search.json")
        XCTAssertEqual(query["q"], "swift reader")
        XCTAssertEqual(query["sort"], "relevance")
        XCTAssertEqual(query["limit"], "100")
        XCTAssertEqual(query["raw_json"], "1")
    }

    func testCommunityCodecPrefersCommunityIconAndFallsBackToLegacyIcon() throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t5","data":{"display_name":"Swift","community_icon":"https://styles.redditmedia.com/swift.png","icon_img":"https://styles.redditmedia.com/legacy-swift.png"}},{"kind":"t5","data":{"display_name":"iPhone","community_icon":"","icon_img":"https://styles.redditmedia.com/iphone.png"}}]}}"#.utf8
        )

        let listing = try RedditJSONCodec.decodeCommunities(data)

        XCTAssertEqual(listing.items[0].reference.iconURL?.absoluteString, "https://styles.redditmedia.com/swift.png")
        XCTAssertEqual(listing.items[1].reference.iconURL?.absoluteString, "https://styles.redditmedia.com/iphone.png")
    }

    func testUserSearchCodecDecodesProfileSubredditListing() throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t5","data":{"display_name":"u_swift_reader","display_name_prefixed":"u/Swift_Reader","title":"Swift_Reader","url":"/user/Swift_Reader/","icon_img":"https://styles.redditmedia.com/profile.png","public_description":"Writes about Swift."}}]}}"#.utf8
        )

        let listing = try RedditJSONCodec.decodeUserSearch(data)
        let user = try XCTUnwrap(listing.items.first)

        XCTAssertEqual(user.reference.username, "Swift_Reader")
        XCTAssertEqual(user.avatarURL?.absoluteString, "https://styles.redditmedia.com/profile.png")
        XCTAssertEqual(user.about?.plainText, "Writes about Swift.")
    }

    @MainActor
    func testUserSearchModelReturnsNavigableProfiles() async {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t5","data":{"display_name_prefixed":"u/Swift_Reader","title":"Swift_Reader","url":"/user/Swift_Reader/","public_description":"Writes about Swift."}}]}}"#.utf8
        )
        let model = SearchFeatureModel(reddit: FixtureRedditClient(usersData: data))

        await model.submit(query: "swift", scope: .users)

        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.users.map(\.reference.username), ["Swift_Reader"])
        XCTAssertTrue(model.posts.isEmpty)
        XCTAssertTrue(model.communities.isEmpty)
    }

    func testMarkdownLinksRenderAsLinkedDisplayText() throws {
        let url = try XCTUnwrap(URL(string: "https://www.instagram.com/p/example/"))
        let attributed = RedditPostMarkdown.attributedString(
            from: "[Source](https://www.instagram.com/p/example/)"
        )

        XCTAssertEqual(String(attributed.characters), "Source")
        XCTAssertTrue(attributed.runs.contains { $0.link == url })
    }

    func testMarkdownLinksInsertMissingSpaceBeforeFollowingText() {
        let labelledLink = RedditPostMarkdown.attributedString(
            from: "[Source](https://example.com)Next"
        )
        let bareLink = RedditPostMarkdown.attributedString(
            from: "https://streamable.com/example\nNext"
        )

        XCTAssertEqual(String(labelledLink.characters), "Source Next")
        XCTAssertEqual(String(bareLink.characters), "https://streamable.com/example Next")
    }

    func testMarkdownTurnsLinkedRedditImagesIntoImageBlocks() throws {
        let imageURL = try XCTUnwrap(
            URL(string: "https://preview.redd.it/example.png?width=1080&format=png")
        )
        let blocks = RedditPostMarkdown.blocks(
            from: "Before\n[Example image](https://preview.redd.it/example.png?width=1080&amp;format=png)\nAfter"
        )

        XCTAssertEqual(
            blocks,
            [
                .text("Before\n"),
                .image(RedditMarkdownImage(url: imageURL, altText: "Example image")),
                .text("\nAfter"),
            ]
        )
    }

    func testMarkdownTurnsBareRedditImageURLsIntoImageBlocks() throws {
        let imageURL = try XCTUnwrap(URL(string: "https://i.redd.it/example.jpeg"))

        XCTAssertEqual(
            RedditPostMarkdown.blocks(from: "Image: https://i.redd.it/example.jpeg."),
            [
                .text("Image: "),
                .image(RedditMarkdownImage(url: imageURL, altText: nil)),
                .text("."),
            ]
        )
    }

    func testMarkdownResolvesRedditMediaImageLinks() throws {
        let imageURL = try XCTUnwrap(URL(string: "https://i.redd.it/wrapped.png"))

        XCTAssertEqual(
            RedditPostMarkdown.blocks(
                from: "[Image](https://www.reddit.com/media?url=https%3A%2F%2Fi.redd.it%2Fwrapped.png)"
            ),
            [.image(RedditMarkdownImage(url: imageURL, altText: "Image"))]
        )
    }

    func testMarkdownLeavesExternalAndCodeImageLinksAsText() {
        let source = "[External](https://example.com/image.png)\n```\nhttps://i.redd.it/code.png\n```"

        XCTAssertEqual(RedditPostMarkdown.blocks(from: source), [.text(source)])
    }

    func testMarkdownPreservesParagraphBreaksAndHeadingText() {
        let attributed = RedditPostMarkdown.attributedString(
            from: "Hello everyone!\n\n## Google Employee Flair\n\nDetails here.\n\nThanks!"
        )

        XCTAssertEqual(
            String(attributed.characters),
            "Hello everyone!\n\nGoogle Employee Flair\n\nDetails here.\n\nThanks!"
        )
    }

    func testMarkdownRendersFencedCodeAsLiteralMonospacedText() {
        let attributed = RedditPostMarkdown.attributedString(
            from: "Before\n```swift\nlet value = **literal**\nprint(value)\n```\nAfter"
        )

        XCTAssertEqual(
            String(attributed.characters),
            "Before\nlet value = **literal**\nprint(value)\nAfter"
        )
        XCTAssertTrue(attributed.runs.contains { $0.font != nil })
    }

    func testMarkdownSupportsTildeAndUnclosedCodeFences() {
        let tildeFence = RedditPostMarkdown.attributedString(
            from: "~~~json\n{\"enabled\": true}\n~~~"
        )
        let unclosedFence = RedditPostMarkdown.attributedString(
            from: "Text\n```\n[not a link](https://example.com)"
        )

        XCTAssertEqual(String(tildeFence.characters), "{\"enabled\": true}")
        XCTAssertEqual(
            String(unclosedFence.characters),
            "Text\n[not a link](https://example.com)"
        )
    }

    func testMarkdownRendersRedditQuotesListsAndSpoilersWithoutSyntaxMarkers() {
        let attributed = RedditPostMarkdown.attributedString(
            from: "> quoted **text**\n\n- first item\n* second item\n\n>!spoiler text!<"
        )

        XCTAssertEqual(
            String(attributed.characters),
            "▎ quoted text\n\n• first item\n• second item\n\nspoiler text"
        )
    }

    func testMarkdownParsesPipeTablesAsBlocks() {
        let blocks = RedditPostMarkdown.blocks(
            from: "Before\n\n|Model|Input|Output|\n|:-|:-|:-|\n|Sol|$4.00|$20.00|\n|Luna|$0.20|$1.20|\n\nAfter"
        )

        XCTAssertEqual(
            blocks,
            [
                .text("Before\n"),
                .table(RedditMarkdownTable(
                    headers: ["Model", "Input", "Output"],
                    rows: [["Sol", "$4.00", "$20.00"], ["Luna", "$0.20", "$1.20"]]
                )),
                .text("\nAfter"),
            ]
        )
    }

    func testPostCardPreservesRedditFlairMetadata() throws {
        let data = Data(
            ##"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"flair1","name":"t3_flair1","permalink":"/r/google_antigravity/comments/flair1/update/","title":"Update","subreddit":"google_antigravity","selftext":"Body","link_flair_text":"News / Updates","link_flair_template_id":"news","link_flair_background_color":"#1478DB","link_flair_text_color":"light"}}]}}"##.utf8
        )

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        let flair = try XCTUnwrap(PostCardModel(post: post).flair)

        XCTAssertEqual(flair.text, "News / Updates")
        XCTAssertEqual(flair.backgroundColor, "#1478DB")
        XCTAssertEqual(flair.textColor, "light")
    }

    func testPostCardPreservesAuthorFlairMetadata() throws {
        let data = Data(
            ##"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"author-flair","name":"t3_author-flair","permalink":"/r/swift/comments/author-flair/update/","title":"Update","subreddit":"swift","author":"octonaut_reader","author_flair_text":"iOS Engineer","author_flair_template_id":"ios-engineer","author_flair_background_color":"#1478DB","author_flair_text_color":"light"}}]}}"##.utf8
        )

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        let flair = try XCTUnwrap(PostCardModel(post: post).authorFlair)

        XCTAssertEqual(flair.text, "iOS Engineer")
        XCTAssertEqual(flair.backgroundColor, "#1478DB")
        XCTAssertEqual(flair.textColor, "light")
    }

    func testCommentCardPreservesAuthorFlairMetadata() throws {
        let data = Data(
            ##"[{"data":{"children":[{"kind":"t3","data":{"id":"thread","name":"t3_thread","permalink":"/r/swift/comments/thread/update/","title":"Update","subreddit":"swift"}}]}},{"data":{"children":[{"kind":"t1","data":{"id":"comment","name":"t1_comment","parent_id":"t3_thread","author":"octonaut_reader","author_flair_text":":swift: Contributor","author_flair_richtext":[{"e":"emoji","a":":swift:","u":"https://emoji.redditmedia.com/example/swift"},{"e":"text","t":" Contributor"}],"author_flair_background_color":"#FF9500","author_flair_text_color":"dark","body":"Hello","created_utc":1724000000,"replies":""}}]}}]"##.utf8
        )

        let thread = try RedditJSONCodec.decodeThread(data)
        guard case .comment(let comment) = try XCTUnwrap(thread.comments.first) else {
            return XCTFail("Expected a comment node")
        }
        let flair = try XCTUnwrap(CommentCardModel(comment: comment).authorFlair)

        XCTAssertEqual(flair.text, "Contributor")
        XCTAssertEqual(flair.backgroundColor, "#FF9500")
        XCTAssertEqual(flair.textColor, "dark")
        XCTAssertEqual(flair.emojiURLs.map(\.absoluteString), ["https://emoji.redditmedia.com/example/swift"])
    }

    func testPreviouslyStoredFlairWithoutEmojiURLsStillDecodes() throws {
        let data = Data(
            ##"{"id":"contributor","text":"Contributor","backgroundColor":"#FF9500","textColor":"dark"}"##.utf8
        )

        let flair = try JSONDecoder().decode(Flair.self, from: data)

        XCTAssertEqual(flair.text, "Contributor")
        XCTAssertTrue(flair.emojiURLs.isEmpty)
    }

    func testStreamableLinkInSelfTextBecomesEmbeddedVideo() throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"streamable1","name":"t3_streamable1","permalink":"/r/videos/comments/streamable1/example/","title":"Example","subreddit":"videos","url":"https://www.reddit.com/r/videos/comments/streamable1/example/","is_self":true,"selftext":"https://streamable.com/2e0gum\nGemini video details"}}]}}"#.utf8
        )

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        let card = PostCardModel(post: post)
        let mediaURL = try XCTUnwrap(post.media.primaryURL)
        let embedURL = try XCTUnwrap(EmbeddedVideoURL.embedURL(for: mediaURL))

        XCTAssertEqual(post.media.kind, "embeddedVideo")
        XCTAssertEqual(embedURL.absoluteString, "https://streamable.com/s/2e0gum")
        XCTAssertTrue(card.isVideo)
        XCTAssertTrue(card.hasMedia)
        XCTAssertEqual(card.body, "Gemini video details")
    }

    func testDirectVideoLinkBecomesNativeVideo() throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"direct-video","name":"t3_direct-video","permalink":"/r/videos/comments/direct-video/example/","title":"Example","subreddit":"videos","url":"https://cdn.example.com/video.mp4","is_self":false}}]}}"#.utf8
        )

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)

        XCTAssertEqual(post.media.kind, "video")
        XCTAssertEqual(post.media.primaryURL?.absoluteString, "https://cdn.example.com/video.mp4")
    }

    func testShortMediaPostPrefersMediaFirstPresentation() {
        var card = PostCardModel.mediaSample
        card.mediaKind = "gallery"
        card.galleryURLs = [URL(string: "https://i.redd.it/example.jpg")!]

        XCTAssertTrue(card.prefersMediaFirstPresentation)

        card.body = String(repeating: "A", count: 281)
        XCTAssertFalse(card.prefersMediaFirstPresentation)
    }

    @MainActor
    func testCommentTreeCanCollapseAndExpandParentAndNestedComments() {
        let store = OctonautFeatureStore()
        store.comments = CommentCardModel.samples

        store.toggleComment(id: "t1_comment-1")
        XCTAssertTrue(store.comments[0].isCollapsed)

        store.toggleComment(id: "t1_comment-1")
        XCTAssertFalse(store.comments[0].isCollapsed)

        store.toggleComment(id: "t1_comment-1a")
        XCTAssertTrue(store.comments[0].children[0].isCollapsed)
    }

    func testCommentIdentifiesOriginalPosterIgnoringUsernameCase() {
        let comment = CommentCardModel(
            id: "t1_op", author: "Example_Author", body: "An update from the OP", score: 1,
            age: "now", vote: 0, depth: 0, isModerator: false, isCollapsed: false,
            children: [])

        XCTAssertTrue(comment.isOriginalPoster(postAuthor: "example_author"))
        XCTAssertFalse(comment.isOriginalPoster(postAuthor: "someone_else"))
        XCTAssertFalse(comment.isOriginalPoster(postAuthor: ""))
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
        let store = OctonautFeatureStore(reddit: client, accountID: accountID)

        await store.refreshCommunities()

        XCTAssertEqual(store.communities.map(\.name), ["swift"])
        XCTAssertEqual(store.communities.first?.isSubscribed, true)
        XCTAssertEqual(store.communities.first?.isFavorite, true)
        XCTAssertEqual(store.communitiesState, .loaded)
    }

    @MainActor
    func testSubscribedCommunitiesFinishCachingWhenViewTaskIsCancelled() async throws {
        let accountID = AccountID()
        await SubscribedCommunitiesCache.shared.remove(for: accountID)
        defer {
            Task { await SubscribedCommunitiesCache.shared.remove(for: accountID) }
        }
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t5","data":{"display_name":"Swift","display_name_prefixed":"r/Swift","subscribers":300000,"user_is_subscriber":true}}]}}"#.utf8
        )
        let client = FixtureRedditClient(
            communitiesData: data,
            subscribedCommunitiesDelay: .milliseconds(100)
        )
        let store = OctonautFeatureStore(reddit: client, accountID: accountID)

        let viewTask = Task { await store.refreshCommunities() }
        try await Task.sleep(for: .milliseconds(10))
        viewTask.cancel()
        await viewTask.value

        XCTAssertEqual(store.communities.map(\.name), ["swift"])
        XCTAssertEqual(store.communitiesState, .loaded)
        await store.refreshCommunities()
        let requestCount = await client.subscribedCommunitiesRequests()
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testHomeFeedReturnsFromMemoryCacheWithoutAnotherRequest() async throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"home1","name":"t3_home1","permalink":"/r/swift/comments/home1/example/","title":"Cached home post","subreddit":"swift","is_self":true}}]}}"#.utf8
        )
        let client = FixtureRedditClient(listingData: data)
        let store = OctonautFeatureStore(reddit: client, accountID: AccountID())

        await store.refreshPosts(for: .home)
        await store.refreshPosts(for: .popular)
        await store.refreshPosts(for: .home)

        XCTAssertEqual(store.posts.map(\.id), ["home1"])
        XCTAssertEqual(store.feedState, .loaded)
        let requestCount = await client.listingRequests()
        XCTAssertEqual(requestCount, 2)
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

        guard case .postURL(let routedPost) = OctonautFeatureURLRouter.route(postURL) else {
            return XCTFail("Expected a post route")
        }
        guard case .community(let community) = OctonautFeatureURLRouter.route(communityURL) else {
            return XCTFail("Expected a community route")
        }

        XCTAssertEqual(routedPost, postURL)
        XCTAssertEqual(community, "Swift")
        XCTAssertEqual(PostCardModel(deepLinkURL: routedPost).id, "abc123")
    }

    func testRedditCommentPermalinkBecomesInAppPostRoute() throws {
        let commentURL = try XCTUnwrap(
            URL(string: "https://www.reddit.com/r/swift/comments/abc123/a-title/def456/?context=3")
        )

        guard case .postURL(let routedURL) = OctonautFeatureURLRouter.route(commentURL) else {
            return XCTFail("Expected a Reddit comment permalink to use the in-app post route")
        }

        XCTAssertEqual(routedURL, commentURL)
        XCTAssertEqual(PostCardModel(deepLinkURL: routedURL).id, "abc123")
    }

    func testShortAndDirectMediaLinksBecomeNativeRoutes() throws {
        let shortURL = try XCTUnwrap(URL(string: "https://redd.it/abc123"))
        let imageURL = try XCTUnwrap(URL(string: "https://i.redd.it/example.jpg"))
        let videoURL = try XCTUnwrap(URL(string: "https://v.redd.it/example"))

        guard case .postURL(let shortPostURL) = OctonautFeatureURLRouter.route(shortURL) else {
            return XCTFail("Expected a short-link post route")
        }
        guard case .mediaURL(let routedImageURL) = OctonautFeatureURLRouter.route(imageURL) else {
            return XCTFail("Expected an image route")
        }
        guard case .mediaURL(let routedVideoURL) = OctonautFeatureURLRouter.route(videoURL) else {
            return XCTFail("Expected a video route")
        }

        XCTAssertEqual(shortPostURL.path, "/comments/abc123")
        XCTAssertEqual(routedImageURL, imageURL)
        XCTAssertEqual(routedVideoURL, videoURL)
    }

    func testCustomOctonautRoutesAreRecognized() throws {
        let feedURL = try XCTUnwrap(URL(string: "octonaut://feed/home"))
        let searchURL = try XCTUnwrap(URL(string: "octonaut://search?q=swift%20concurrency"))
        let settingsURL = try XCTUnwrap(URL(string: "octonaut://settings"))

        guard case .feed(let feed) = OctonautFeatureURLRouter.route(feedURL) else {
            return XCTFail("Expected a feed route")
        }
        guard case .search(let query) = OctonautFeatureURLRouter.route(searchURL) else {
            return XCTFail("Expected a search route")
        }
        guard case .settings(.general) = OctonautFeatureURLRouter.route(settingsURL) else {
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

    func testPostCardRemovesDisplayedImageURLButKeepsFollowingBodyText() throws {
        let imageURL = try XCTUnwrap(
            URL(string: "https://preview.redd.it/example.png?width=786&format=png&auto=webp")
        )
        let post = Post(
            id: "image-url-and-body",
            permalink: URL(string: "https://www.reddit.com/r/swift/comments/image-url-and-body")!,
            community: CommunityReference(name: "swift"),
            title: "Image with explanation",
            body: RichText(
                plainText: "https://preview.redd.it/example.png?width=786&amp;format=png&amp;auto=webp\nIt might repeat dozens of times."
            ),
            flair: Flair(
                id: "bug",
                text: "Bug / Troubleshooting",
                backgroundColor: "#EA4335",
                textColor: "light"
            ),
            media: .image(url: imageURL, thumbnailURL: nil, width: nil, height: nil)
        )

        let card = PostCardModel(post: post)

        XCTAssertEqual(card.body, "It might repeat dozens of times.")
        XCTAssertEqual(card.flair?.text, "Bug / Troubleshooting")
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

    func testDirectImageURLDoesNotRequirePostHint() throws {
        let imageURL = "https://i.redd.it/no-hint.jpeg"
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"image-no-hint","name":"t3_image-no-hint","permalink":"/r/pics/comments/image-no-hint/post/","title":"Image without a hint","subreddit":"pics","is_self":false,"url_overridden_by_dest":"\#(imageURL)"}}]}}"#.utf8)

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        guard case .image(let decodedURL, _, _, _) = post.media else {
            return XCTFail("Expected a direct image URL to become native image media")
        }
        XCTAssertEqual(decodedURL.absoluteString, imageURL)
    }

    func testCrosspostParentImageBecomesNativeMedia() throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"crosspost-image","name":"t3_crosspost-image","permalink":"/r/yeoreum/comments/crosspost-image/update/","title":"Instagram update","subreddit":"yeoreum","is_self":false,"url":"https://www.reddit.com/r/elsewhere/comments/source/update/","crosspost_parent_list":[{"post_hint":"image","url_overridden_by_dest":"https://i.redd.it/source-image.jpg","preview":{"images":[{"source":{"url":"https://preview.redd.it/source-image.jpg?width=1080&amp;format=pjpg","width":1080,"height":1350}}]}}]}}]}}"#.utf8)

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        guard case .image(let imageURL, let thumbnailURL, _, _) = post.media else {
            return XCTFail("Expected the crosspost parent image to become native media")
        }
        XCTAssertEqual(imageURL.absoluteString, "https://i.redd.it/source-image.jpg")
        XCTAssertEqual(thumbnailURL?.host, "preview.redd.it")
    }

    func testExternalLinkKeepsRedditPreviewImage() throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"external-preview","name":"t3_external-preview","permalink":"/r/apple/comments/external-preview/story/","title":"A story","subreddit":"apple","is_self":false,"url_overridden_by_dest":"https://example.com/story","secure_media":{"oembed":{"provider_name":"Example","thumbnail_url":"https://cdn.example.com/story.jpg"}},"preview":{"images":[{"source":{"url":"https://preview.redd.it/story.jpg?width=1080&amp;format=pjpg","width":1080,"height":720}}]}}}]}}"#.utf8)

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        guard case .link(let url, let metadata) = post.media else {
            return XCTFail("Expected an external destination to remain a link")
        }
        XCTAssertEqual(url.absoluteString, "https://example.com/story")
        XCTAssertEqual(metadata?.siteName, "Example")
        XCTAssertEqual(metadata?.imageURL?.host, "preview.redd.it")
        XCTAssertEqual(PostCardModel(post: post).thumbnailURL?.host, "preview.redd.it")
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

    func testUserProfileCodecHandlesWrappedThingEnvelope() throws {
        let data = Data(
            #"""
            {
              "kind": "t2",
              "data": {
                "name": "Maranthis",
                "icon_img": "https://example.com/maranthis.png",
                "created_utc": 1700000000,
                "total_karma": 9999,
                "subreddit": {"public_description": "Hello world"},
                "is_friend": false
              }
            }
            """#.utf8)

        let profile = try RedditJSONCodec.decodeUserProfile(data)

        XCTAssertEqual(profile.reference.username, "Maranthis")
        XCTAssertEqual(profile.karma, 9_999)
        XCTAssertEqual(profile.about?.plainText, "Hello world")
        XCTAssertFalse(profile.isFollowing)
        XCTAssertEqual(profile.avatarURL?.host, "example.com")
    }

    func testUserProfileCacheKeepsPostsAndMediaFreshForOneHour() async throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let cache = UserProfileCache(directoryURL: directoryURL)
        let storedAt = Date(timeIntervalSince1970: 1_000_000)
        let profile = UserProfile(
            reference: UserReference(username: "swift_reader"),
            avatarURL: URL(string: "https://example.com/avatar.png"),
            createdAt: storedAt,
            karma: 42,
            about: nil,
            isBlocked: false,
            isFollowing: false
        )
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"image1","name":"t3_image1","permalink":"/r/swift/comments/image1/example/","title":"Example","subreddit":"swift","url":"https://i.redd.it/image1.jpg","post_hint":"image","is_self":false}}]}}"#.utf8
        )
        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)

        await cache.store(
            profile: profile,
            posts: [post],
            comments: [],
            for: "Swift_Reader",
            account: nil,
            now: storedAt
        )

        let freshValue = await cache.value(
            for: "swift_reader",
            account: nil,
            now: storedAt.addingTimeInterval(60 * 60 - 1)
        )
        let fresh = try XCTUnwrap(freshValue)
        XCTAssertTrue(fresh.isFresh)
        XCTAssertEqual(fresh.posts.map(\.id), ["image1"])
        XCTAssertEqual(PostCardModel(post: fresh.posts[0]).mediaURL?.absoluteString, "https://i.redd.it/image1.jpg")

        let staleValue = await cache.value(
            for: "swift_reader",
            account: nil,
            now: storedAt.addingTimeInterval(60 * 60 + 1)
        )
        let stale = try XCTUnwrap(staleValue)
        XCTAssertFalse(stale.isFresh)
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
