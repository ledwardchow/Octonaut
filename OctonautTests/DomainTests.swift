import AVFoundation
import SwiftUI
import XCTest

@testable import Octonaut

private actor ControlledSubscriptionService: AuthenticatedRedditService {
    private(set) var requests: [(action: RedditAction, account: AccountID)] = []
    private var pending: CheckedContinuation<ActionResult, Never>?
    private var requestWaiter: CheckedContinuation<Void, Never>?

    func fetchInbox(section: InboxSection, accountID: AccountID) async throws -> Listing<InboxItem> {
        Listing(items: [])
    }

    func fetchConversation(messageID: String, accountID: AccountID) async throws -> [Message] { [] }

    func perform(_ action: RedditAction, accountID: AccountID) async throws -> ActionResult {
        requests.append((action, accountID))
        return await withCheckedContinuation { continuation in
            pending = continuation
            requestWaiter?.resume()
            requestWaiter = nil
        }
    }

    func waitForRequest() async {
        if pending != nil { return }
        await withCheckedContinuation { requestWaiter = $0 }
    }

    func complete(_ result: ActionResult) {
        let continuation = pending
        pending = nil
        continuation?.resume(returning: result)
    }
}

final class DomainTests: XCTestCase {
    @MainActor
    func testSubscriptionSuccessInvalidatesCacheAndReloadsCommunities() async throws {
        let account = AccountID()
        let client = FixtureRedditClient(communitiesData: subscriptionFixture)
        let service = ControlledSubscriptionService()
        let store = OctonautFeatureStore(reddit: client, authenticated: service, accountID: account)
        await store.refreshCommunities()
        let cachedBefore = await SubscribedCommunitiesCache.shared.value(for: account)
        XCTAssertNotNil(cachedBefore)

        store.toggleSubscribe(communityID: "swift")
        await service.waitForRequest()
        await service.complete(ActionResult(succeeded: true))
        await waitForSubscription(store)

        let cachedAfter = await SubscribedCommunitiesCache.shared.value(for: account)
        XCTAssertNil(cachedAfter)
        await store.refreshCommunities()
        let reads = await client.subscribedCommunitiesRequests()
        XCTAssertEqual(reads, 2, "Returning to Communities must fetch the updated subscriptions")
        await SubscribedCommunitiesCache.shared.remove(for: account)
    }

    @MainActor
    func testSubscriptionIgnoresRepeatedTapsAndAllowsRetryAfterFailure() async throws {
        let account = AccountID()
        let client = FixtureRedditClient(communitiesData: subscriptionFixture)
        let service = ControlledSubscriptionService()
        let store = OctonautFeatureStore(reddit: client, authenticated: service, accountID: account)
        await store.refreshCommunities()

        store.toggleSubscribe(communityID: "swift")
        store.toggleSubscribe(communityID: "swift")
        await service.waitForRequest()
        store.toggleSubscribe(communityID: "swift")
        let firstRequests = await service.requests
        XCTAssertEqual(firstRequests.count, 1)
        XCTAssertEqual(firstRequests.first?.account, account)
        if case .subscribe(let community, let subscribed) = firstRequests.first?.action {
            XCTAssertEqual(community, "swift")
            XCTAssertFalse(subscribed)
        } else { XCTFail("Expected a website subscription action") }
        XCTAssertEqual(store.communities.first?.isSubscribed, false)

        await service.complete(ActionResult(succeeded: false, message: "Denied"))
        await waitForSubscription(store)
        XCTAssertEqual(store.communities.first?.isSubscribed, true)
        let cached = await SubscribedCommunitiesCache.shared.value(for: account)
        XCTAssertNotNil(cached, "A rejected change must preserve the cache")

        store.toggleSubscribe(communityID: "swift")
        await service.waitForRequest()
        await service.complete(ActionResult(succeeded: true))
        await waitForSubscription(store)
        let retryRequests = await service.requests
        XCTAssertEqual(retryRequests.count, 2)
        XCTAssertEqual(store.communities.first?.isSubscribed, false)
        await SubscribedCommunitiesCache.shared.remove(for: account)
    }

    @MainActor
    func testSubscriptionCompletionInvalidatesOriginalAccountAfterSwitch() async throws {
        let first = AccountID()
        let second = AccountID()
        let client = FixtureRedditClient(communitiesData: subscriptionFixture)
        let service = ControlledSubscriptionService()
        let store = OctonautFeatureStore(reddit: client, authenticated: service, accountID: first)
        await store.refreshCommunities()
        store.toggleSubscribe(communityID: "swift")
        await service.waitForRequest()
        store.synchronizeAccount(id: second, generation: 1, accounts: [])
        await store.refreshCommunities()

        await service.complete(ActionResult(succeeded: true))
        // Return to the original account so the pending-state check observes its request.
        store.synchronizeAccount(id: first, generation: 2, accounts: [])
        await waitForSubscription(store)
        let firstCache = await SubscribedCommunitiesCache.shared.value(for: first)
        let secondCache = await SubscribedCommunitiesCache.shared.value(for: second)
        XCTAssertNil(firstCache)
        XCTAssertNotNil(secondCache)
        await SubscribedCommunitiesCache.shared.remove(for: first)
        await SubscribedCommunitiesCache.shared.remove(for: second)
    }

    private var subscriptionFixture: Data {
        Data(#"{"data":{"after":null,"before":null,"children":[{"kind":"t5","data":{"display_name":"Swift","user_is_subscriber":true}}]}}"#.utf8)
    }

    @MainActor
    private func waitForSubscription(_ store: OctonautFeatureStore) async {
        for _ in 0..<1000 {
            if !store.isSubscriptionSaving(communityID: "swift") { return }
            await Task.yield()
        }
        XCTFail("Subscription request did not finish")
    }
    @MainActor
    func testSearchUsesSelectedAccountAndReturnsToAnonymous() async {
        let client = FixtureRedditClient()
        let model = SearchFeatureModel(reddit: client)
        let account = AccountID()
        for scope in FeatureSearchScope.allCases {
            await model.submit(query: "swift", scope: scope, account: account)
        }
        await model.loadTrendingCommunities(account: account)
        await model.submit(query: "swift", scope: .posts, account: nil)
        let accounts = await client.searchAccounts
        XCTAssertEqual(accounts, [account, account, account, account, nil])
    }

    func testBlockedAnonymousResponsesOfferLogin() throws {
        for status in [401, 403, 200] {
            let response = HTTPURLResponse(url: URL(string: "https://www.reddit.com/hot.json")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            let data = Data((status == 200 ? "  <html>Blocked</html>" : "{}").utf8)
            XCTAssertThrowsError(try URLSessionRedditClient.validateResponse(data, response: response, isAnonymous: true)) { error in
                XCTAssertEqual(error as? RedditClientError, .anonymousAccessBlocked)
                XCTAssertEqual(OctonautLoadState.failure(error), .loginRequired)
            }
        }
    }

    func testSignedInAndRateLimitErrorsDoNotOfferAnonymousLogin() throws {
        for (status, anonymous, expected) in [(403, false, RedditClientError.accessDenied), (401, false, .authenticationRequired), (429, true, .rateLimited(retryAfter: 10)), (404, true, .notFound), (500, true, .http(statusCode: 500, message: nil))] {
            let response = HTTPURLResponse(url: URL(string: "https://www.reddit.com/hot.json")!, statusCode: status, httpVersion: nil, headerFields: ["Retry-After": "10"])!
            XCTAssertThrowsError(try URLSessionRedditClient.validateResponse(Data("{}".utf8), response: response, isAnonymous: anonymous)) { error in
                XCTAssertEqual(error as? RedditClientError, expected)
                XCTAssertNotEqual(OctonautLoadState.failure(error), .loginRequired)
            }
        }
        let response = HTTPURLResponse(url: URL(string: "https://www.reddit.com/hot.json")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        XCTAssertNoThrow(try URLSessionRedditClient.validateResponse(Data("{}".utf8), response: response, isAnonymous: true))
    }

    func testWideInterfaceFollowsHorizontalSizeClass() {
        XCTAssertTrue(OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: .regular))
        XCTAssertFalse(OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: .compact))
        XCTAssertFalse(OctonautAdaptiveLayout.usesWideInterface(horizontalSizeClass: nil))
    }

    func testGalleryIncludesEveryAlbumImageAndKeepsViewerPage() {
        var album = PostCardModel.sample
        album.hasMedia = true
        album.mediaKind = "gallery"
        album.galleryURLs = (0..<120).map { URL(string: "https://i.redd.it/image-\($0).jpg")! }
        let items = GalleryMediaItem.items(from: [album])
        XCTAssertEqual(items.count, 120)
        XCTAssertEqual(items.last?.page, 119)
        XCTAssertEqual(items.last?.url, album.galleryURLs.last)
        XCTAssertEqual(Set(items.map(\.id)).count, 120)
    }

    func testGalleryUsesFullImageAndVideoThumbnail() {
        var post = PostCardModel.sample
        post.hasMedia = true
        post.galleryURLs = []
        post.mediaKind = "image"
        post.isVideo = false
        post.mediaURL = URL(string: "https://i.redd.it/full.jpg")!
        post.thumbnailURL = URL(string: "https://preview.redd.it/thumb.jpg")!
        XCTAssertEqual(GalleryMediaItem.items(from: [post]).first?.previewURL, post.mediaURL)
        post.mediaKind = "video"
        XCTAssertEqual(GalleryMediaItem.items(from: [post]).first?.previewURL, post.thumbnailURL)
        post.hasMedia = false
        XCTAssertTrue(GalleryMediaItem.items(from: [post]).isEmpty)
    }

    @MainActor
    func testGalleryCanPagePastEmptyResultsAndStopsOnRepeatedCursor() async {
        let data = Data(#"{"data":{"after":"next-page","children":[]}}"#.utf8)
        let client = FixtureRedditClient(listingData: data)
        let store = OctonautFeatureStore(reddit: client)
        await store.refreshPosts(for: .popular)
        XCTAssertEqual(store.galleryPageCursor(for: .popular), "next-page")
        XCTAssertNil(store.galleryPageCursor(for: .home))
        await store.loadMorePosts(for: .popular)
        XCTAssertNil(store.galleryPageCursor(for: .popular))
        let requests = await client.listingRequests()
        XCTAssertEqual(requests, 2)
    }

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

    func testRedditVideoPlaybackUsesPlaylistForSeparateAudio() throws {
        for filename in ["DASH_720.mp4", "CMAF_360.mp4"] {
            let source = try XCTUnwrap(URL(string: "https://v.redd.it/clip/\(filename)?source=fallback#fragment"))
            XCTAssertEqual(
                RedditVideoPlayback.url(for: source, isGIF: false).absoluteString,
                "https://v.redd.it/clip/HLSPlaylist.m3u8"
            )
            XCTAssertEqual(RedditVideoPlayback.url(for: source, isGIF: true), source)
        }
    }

    func testRedditVideoPlaybackPreservesOtherSources() throws {
        for value in [
            "https://v.redd.it/clip/HLSPlaylist.m3u8?f=hd",
            "https://example.com/movie.mp4",
            "https://v.redd.it.example.com/clip/CMAF_360.mp4",
            "http://v.redd.it/clip/CMAF_360.mp4",
            "https://user:password@v.redd.it/clip/CMAF_360.mp4",
            "https://v.redd.it:8443/clip/CMAF_360.mp4",
            "https://v.redd.it/CMAF_360.mp4"
        ] {
            let source = try XCTUnwrap(URL(string: value))
            XCTAssertEqual(RedditVideoPlayback.url(for: source, isGIF: false), source)
        }
    }

    func testRedditVideoPlaybackExplainsAudioOutputFailure() {
        let outputError = NSError(domain: NSOSStatusErrorDomain, code: 2003329396)
        let wrapped = NSError(domain: AVFoundationErrorDomain, code: -11800, userInfo: [NSUnderlyingErrorKey: outputError])
        XCTAssertTrue(RedditVideoPlayback.failureMessage(for: wrapped).contains("audio output could not start"))
        XCTAssertEqual(RedditVideoPlayback.failureMessage(for: outputError), RedditVideoPlayback.failureMessage(for: wrapped))
        XCTAssertEqual(RedditVideoPlayback.failureMessage(for: nil), "The video could not play. Reopen it to try again.")
        XCTAssertEqual(
            RedditVideoPlayback.failureMessage(for: NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)),
            RedditVideoPlayback.failureMessage(for: nil)
        )
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

    func testTextPostBuildsWebsiteSubmitRequest() {
        let request = URLSessionRedditClient.mutationRequest(
            for: .submitPost(
                community: "swift",
                title: "A native macOS post",
                text: "Post body",
                link: nil,
                sendReplies: true
            )
        )

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/submit")
        XCTAssertEqual(request.fields["sr"], "swift")
        XCTAssertEqual(request.fields["title"], "A native macOS post")
        XCTAssertEqual(request.fields["text"], "Post body")
        XCTAssertEqual(request.fields["kind"], "self")
        XCTAssertEqual(request.fields["sendreplies"], "true")
        XCTAssertEqual(request.fields["api_type"], "json")
    }

    func testCommentBuildsWebsiteCommentRequest() {
        let postID = IDNormalization.fullname("example", kind: "t3")
        let request = URLSessionRedditClient.mutationRequest(for: .comment(thingID: postID, text: "A comment"))

        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/comment")
        XCTAssertEqual(request.fields["thing_id"], "t3_example")
        XCTAssertEqual(request.fields["text"], "A comment")
        XCTAssertEqual(request.fields["api_type"], "json")

        let commentID = IDNormalization.fullname("reply", kind: "t1")
        let replyRequest = URLSessionRedditClient.mutationRequest(
            for: .comment(thingID: commentID, text: "A reply")
        )
        XCTAssertEqual(replyRequest.path, "/api/comment")
        XCTAssertEqual(replyRequest.fields["thing_id"], "t1_reply")
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

    func testTrendingCommunitiesBuildsPublicWebsiteJSONRoute() {
        let route = URLSessionRedditClient.trendingCommunitiesRoute(limit: 500)
        let query = Dictionary(uniqueKeysWithValues: route.query.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(route.path, "/subreddits/popular.json")
        XCTAssertEqual(query["limit"], "100")
        XCTAssertEqual(query["raw_json"], "1")
    }

    func testMoreCommentsBuildsPublicWebsiteJSONRoute() {
        let route = URLSessionRedditClient.moreCommentsRoute(
            postFullname: "t3_sample",
            childIDs: ["first", "second"],
            sort: .top
        )
        let query = Dictionary(uniqueKeysWithValues: route.query.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        XCTAssertEqual(route.path, "/api/morechildren")
        XCTAssertEqual(query["api_type"], "json")
        XCTAssertEqual(query["link_id"], "t3_sample")
        XCTAssertEqual(query["children"], "first,second")
        XCTAssertEqual(query["limit_children"], "false")
        XCTAssertEqual(query["sort"], "top")
        XCTAssertEqual(query["raw_json"], "1")

        let bestRoute = URLSessionRedditClient.moreCommentsRoute(
            postFullname: "t3_sample",
            childIDs: ["first"],
            sort: .best
        )
        XCTAssertEqual(bestRoute.query.first(where: { $0.name == "sort" })?.value, "confidence")
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

    @MainActor
    func testTrendingCommunitiesLoadSeparatelyFromSearchResults() async {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t5","data":{"display_name":"AskReddit","subscribers":58184146,"community_icon":"https://styles.redditmedia.com/askreddit.png"}}]}}"#.utf8
        )
        let model = SearchFeatureModel(reddit: FixtureRedditClient(communitiesData: data))

        await model.loadTrendingCommunities()

        XCTAssertEqual(model.trendingState, .loaded)
        XCTAssertEqual(model.trendingCommunities.map(\.name), ["askreddit"])
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
            "▎ quoted text\n\n• first item\n• second item\n\n[Reveal spoiler]"
        )
    }

    func testSpoilersRevealIndependentlyAndPreserveLinks() {
        let source = "Before >!**secret** [link](https://example.com)!< and >!second!< after"
        let hidden = RedditPostMarkdown.attributedString(from: source)
        XCTAssertEqual(String(hidden.characters), "Before [Reveal spoiler] and [Reveal spoiler] after")
        XCTAssertFalse(hidden.runs.contains { $0.link?.host == "example.com" })
        let revealed = RedditPostMarkdown.attributedString(from: source, revealedSpoilers: [0])
        XCTAssertEqual(String(revealed.characters), "Before secret link and [Reveal spoiler] after")
        XCTAssertTrue(revealed.runs.contains { $0.link?.host == "example.com" })
    }

    func testSpoilerSyntaxInCodeAndEscapedTextStaysLiteral() {
        for source in ["`>!literal!<`", "```\n>!literal!<\n```", #"\>!literal!<"#] {
            let text = RedditPostMarkdown.attributedString(from: source)
            XCTAssertEqual(String(text.characters), ">!literal!<")
            XCTAssertFalse(text.runs.contains { $0.link != nil })
        }
    }

    func testSpoilerImageDoesNotBecomeVisibleImageBlock() {
        let source = ">![Secret](https://i.redd.it/secret.png)!<"
        XCTAssertEqual(RedditPostMarkdown.blocks(from: source), [.text(source)])
        XCTAssertEqual(String(RedditPostMarkdown.attributedString(from: source).characters), "[Reveal spoiler]")
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

    func testPostPreviewUsesTextBeforeTableAndKeepsSpoilersHidden() {
        let source = "Welcome to [the roundup](https://example.com). >!secret!<\n\n|Thread|Votes|\n|:-|:-|\n|A long story|42|"

        XCTAssertEqual(
            RedditPostMarkdown.previewText(from: source),
            "Welcome to the roundup. [Reveal spoiler]"
        )
        XCTAssertEqual(
            RedditPostMarkdown.previewText(from: "|Thread|Votes|\n|:-|:-|\n|A long story|42|"),
            ""
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
    func testLoadingMoreCommentsKeepsTheVisibleTreeThenReplacesThePlaceholder() async throws {
        let moreCommentsData = Data(
            #"{"json":{"errors":[],"data":{"things":[{"kind":"t1","data":{"id":"child","name":"t1_child","parent_id":"t1_parent","author":"reader","body":"Loaded comment","created_utc":0,"replies":""}},{"kind":"t1","data":{"id":"grandchild","name":"t1_grandchild","parent_id":"t1_child","author":"another_reader","body":"Nested reply","created_utc":0,"replies":""}}]}}}"#.utf8
        )
        let client = FixtureRedditClient(
            moreCommentsData: moreCommentsData,
            moreCommentsDelay: .milliseconds(100)
        )
        let store = OctonautFeatureStore(reddit: client)
        let more = CommentCardModel.more(
            MoreCommentsNode(
                id: "more-comments",
                parentFullname: "t1_parent",
                childIDs: ["child", "grandchild"],
                count: 2
            ),
            depth: 1
        )
        let parent = CommentCardModel(
            id: "parent", author: "reader", body: "Keep me visible", score: 1,
            age: "now", vote: 0, depth: 0, isModerator: false, isCollapsed: false,
            children: [more])
        store.comments = [parent]
        store.detailState = .loaded

        let loadTask = Task {
            await store.loadMoreComments("more-comments", for: .sample)
        }
        try await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(store.comments[0].children.map(\.id), ["more-comments"])
        XCTAssertEqual(store.detailState, .loaded)
        XCTAssertTrue(store.moreLoadingIDs.contains("more-comments"))

        await loadTask.value

        XCTAssertEqual(store.comments.map(\.id), ["parent"])
        XCTAssertEqual(store.comments[0].children.map(\.id), ["child"])
        XCTAssertEqual(store.comments[0].children[0].children.map(\.id), ["grandchild"])
        XCTAssertEqual(store.comments[0].children[0].depth, 1)
        XCTAssertEqual(store.comments[0].children[0].children[0].depth, 2)
        XCTAssertEqual(store.detailState, .loaded)
        XCTAssertFalse(store.moreLoadingIDs.contains("more-comments"))
        XCTAssertFalse(store.moreFailedIDs.contains("more-comments"))
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

    func testLoginNavigationPolicyKeepsMainFrameOnReddit() {
        XCTAssertTrue(
            RedditLoginNavigationPolicy.allows(
                URL(string: "https://www.reddit.com/login/"),
                isMainFrame: true
            )
        )
        XCTAssertFalse(
            RedditLoginNavigationPolicy.allows(
                URL(string: "https://www.google.com/recaptcha/api2/anchor"),
                isMainFrame: true
            )
        )
        XCTAssertFalse(
            RedditLoginNavigationPolicy.allows(
                URL(string: "http://www.reddit.com/login/"),
                isMainFrame: true
            )
        )
    }

    func testLoginNavigationPolicyAllowsRequiredEmbeddedFrames() {
        for address in [
            "https://www.google.com/recaptcha/api2/anchor",
            "https://recaptcha.google.com/recaptcha/api2/bframe",
            "https://accounts.google.com/gsi/fedcm/listaccounts",
            "about:blank",
        ] {
            XCTAssertTrue(
                RedditLoginNavigationPolicy.allows(
                    URL(string: address),
                    isMainFrame: false
                ),
                address
            )
        }

        XCTAssertFalse(
            RedditLoginNavigationPolicy.allows(
                URL(string: "https://example.com/embedded"),
                isMainFrame: false
            )
        )
        XCTAssertFalse(
            RedditLoginNavigationPolicy.allows(
                URL(string: "https://www.google.com/search?q=reddit"),
                isMainFrame: false
            )
        )
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
    func testSubscriptionsRestartWhenSameAccountLogsInAgain() async throws {
        let accountID = AccountID()
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t5","data":{"display_name":"Swift","user_is_subscriber":true}}]}}"#.utf8
        )
        let client = FixtureRedditClient(
            communitiesData: data,
            subscribedCommunitiesDelay: .milliseconds(100)
        )
        let store = OctonautFeatureStore(reddit: client, accountID: accountID)
        let initialLoad = Task { await store.refreshCommunities() }
        while await client.subscribedCommunitiesRequests() == 0 {
            await Task.yield()
        }

        store.synchronizeAccount(id: accountID, generation: 1, accounts: [])
        await store.refreshCommunities()
        await initialLoad.value

        XCTAssertEqual(store.communities.map(\.name), ["swift"])
        XCTAssertEqual(store.communitiesState, .loaded)
        let requestCount = await client.subscribedCommunitiesRequests()
        XCTAssertEqual(requestCount, 2)
        await SubscribedCommunitiesCache.shared.remove(for: accountID)
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
            media: .video(url: imageURL, audioURL: audioURL, thumbnailURL: secondURL, isGIF: false, width: 1280, height: 720)
        )

        let mapped = PostCardModel(post: post)
        XCTAssertEqual(mapped.mediaURL, imageURL)
        XCTAssertEqual(mapped.thumbnailURL, secondURL)
        XCTAssertEqual(mapped.audioURL, audioURL)
        XCTAssertEqual(mapped.mediaKind, "video")
        XCTAssertEqual(try XCTUnwrap(mapped.mediaAspectRatio), 1280.0 / 720.0, accuracy: 0.0001)
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

    func testRedditHostedVideoPrefersTheHLSPlaylistOverTheDASHFallback() async throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"video1","name":"t3_video1","permalink":"/r/videos/comments/video1/example/","title":"Example video","subreddit":"videos","url":"https://v.redd.it/clip123","is_self":false,"is_video":true,"post_hint":"hosted:video","secure_media":{"reddit_video":{"fallback_url":"https://v.redd.it/clip123/DASH_720.mp4?source=fallback","hls_url":"https://v.redd.it/clip123/HLSPlaylist.m3u8","has_audio":true,"is_gif":false,"width":1920,"height":1080}},"preview":{"images":[{"source":{"url":"https://preview.redd.it/clip123.jpg?width=1080&amp;format=pjpg"}}]}}}]}}"#
                .utf8)
        let client = FixtureRedditClient(listingData: data)

        let listing = try await client.listing(
            ListingRequest(feed: FeedDescriptor(destination: .home)),
            account: nil
        )
        let post = try XCTUnwrap(listing.items.first)

        guard case .video(let videoURL, let audioURL, let thumbnailURL, let isGIF, let width, let height) = post.media else {
            return XCTFail("Expected native video media")
        }
        // The playlist carries audio in-stream, so nothing has to be guessed,
        // fetched or composed before the video can play.
        XCTAssertEqual(videoURL.absoluteString, "https://v.redd.it/clip123/HLSPlaylist.m3u8")
        XCTAssertNil(audioURL)
        XCTAssertEqual(thumbnailURL?.absoluteString, "https://preview.redd.it/clip123.jpg?width=1080&format=pjpg")
        XCTAssertFalse(isGIF)
        XCTAssertEqual(width, 1920)
        XCTAssertEqual(height, 1080)
    }

    func testRedditHostedVideoWithoutAPlaylistStillComposesTheDASHAudio() async throws {
        let data = Data(
            #"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"video2","name":"t3_video2","permalink":"/r/videos/comments/video2/example/","title":"Example video","subreddit":"videos","url":"https://v.redd.it/clip789","is_self":false,"is_video":true,"post_hint":"hosted:video","secure_media":{"reddit_video":{"fallback_url":"https://v.redd.it/clip789/DASH_720.mp4?source=fallback","has_audio":true,"is_gif":false}}}}]}}"#
                .utf8)
        let client = FixtureRedditClient(listingData: data)

        let listing = try await client.listing(
            ListingRequest(feed: FeedDescriptor(destination: .home)),
            account: nil
        )
        let post = try XCTUnwrap(listing.items.first)

        guard case .video(let videoURL, let audioURL, _, _, _, _) = post.media else {
            return XCTFail("Expected native video media")
        }
        XCTAssertEqual(videoURL.absoluteString, "https://v.redd.it/clip789/DASH_720.mp4?source=fallback")
        XCTAssertEqual(audioURL?.absoluteString, "https://v.redd.it/clip789/DASH_AUDIO_128.mp4?source=fallback")
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

        guard case .video(let videoURL, _, _, _, _, _) = post.media else {
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

        guard case .video(let videoURL, _, let thumbnailURL, _, _, _) = post.media else {
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
              "subreddit":{"public_description":"Swift and native UI.","user_is_subscriber":true},
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

    func testAnimatedGIFPostResolvesToTheMP4VariantAsLoopingVideo() throws {
        let data = Data(
            ##"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"gif1","name":"t3_gif1","permalink":"/r/aww/comments/gif1/a-cat/","title":"A cat","subreddit":"aww","url":"https://i.redd.it/abc123.gif","post_hint":"image","preview":{"images":[{"source":{"url":"https://preview.redd.it/abc123.gif?width=640","width":640,"height":480},"variants":{"mp4":{"source":{"url":"https://preview.redd.it/abc123.gif?format=mp4&amp;s=sig","width":640,"height":480}}}}]}}}]}}"##.utf8
        )

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        let card = PostCardModel(post: post)

        XCTAssertEqual(card.mediaKind, "gif")
        XCTAssertTrue(card.isVideo)
        XCTAssertEqual(
            card.mediaURL?.absoluteString,
            "https://preview.redd.it/abc123.gif?format=mp4&s=sig"
        )
        XCTAssertNil(card.audioURL)
    }

    func testImgurGIFWithoutAPreviewVariantFallsBackToTheMP4Path() throws {
        let data = Data(
            ##"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"gif2","name":"t3_gif2","permalink":"/r/funny/comments/gif2/a-clip/","title":"A clip","subreddit":"funny","url":"https://i.imgur.com/xyz789.gif"}}]}}"##.utf8
        )

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        let card = PostCardModel(post: post)

        XCTAssertEqual(card.mediaKind, "gif")
        XCTAssertEqual(card.mediaURL?.absoluteString, "https://i.imgur.com/xyz789.mp4")
    }

    func testStaticImagePostIsStillDecodedAsAnImage() throws {
        let data = Data(
            ##"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"img1","name":"t3_img1","permalink":"/r/pics/comments/img1/a-photo/","title":"A photo","subreddit":"pics","url":"https://i.redd.it/static123.jpg","post_hint":"image","preview":{"images":[{"source":{"url":"https://preview.redd.it/static123.jpg","width":1920,"height":1080},"variants":{}}]}}}]}}"##.utf8
        )

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        let card = PostCardModel(post: post)

        XCTAssertEqual(card.mediaKind, "image")
        XCTAssertFalse(card.isVideo)
    }

    func testRedditHostedGIFVideoStillKeepsItsSilentTrack() throws {
        let data = Data(
            ##"{"data":{"after":null,"before":null,"children":[{"kind":"t3","data":{"id":"gif3","name":"t3_gif3","permalink":"/r/aww/comments/gif3/a-pup/","title":"A pup","subreddit":"aww","url":"https://v.redd.it/pup123","secure_media":{"reddit_video":{"fallback_url":"https://v.redd.it/pup123/DASH_720.mp4","is_gif":true,"has_audio":false}}}}]}}"##.utf8
        )

        let post = try XCTUnwrap(RedditJSONCodec.decodePosts(data).items.first)
        let card = PostCardModel(post: post)

        XCTAssertEqual(card.mediaKind, "gif")
        XCTAssertEqual(card.mediaURL?.absoluteString, "https://v.redd.it/pup123/DASH_720.mp4")
        XCTAssertNil(card.audioURL)
    }

    @MainActor
    func testVideoLooperRestartsPlaybackWhenTheItemEnds() async throws {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let player = AVPlayer(playerItem: item)
        let looper = OctonautVideoLooper()

        looper.attach(to: player)

        // Without this the player stalls on the last frame instead of looping.
        XCTAssertEqual(player.actionAtItemEnd, .none)

        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        await Task.yield()

        XCTAssertEqual(player.rate, 1, accuracy: 0.01)

        looper.detach()
        player.pause()

        // After detaching, an end notification must no longer restart playback.
        NotificationCenter.default.post(
            name: AVPlayerItem.didPlayToEndTimeNotification,
            object: item
        )
        await Task.yield()

        XCTAssertEqual(player.rate, 0, accuracy: 0.01)
    }

    @MainActor
    func testPlaybackCoordinatorHandsThePlayheadBetweenFeedAndViewer() throws {
        let coordinator = OctonautPlaybackCoordinator.shared
        let url = try XCTUnwrap(URL(string: "https://v.redd.it/handoff/DASH_720.mp4"))

        coordinator.endFullScreen()
        XCTAssertFalse(coordinator.isFullScreenActive)

        // The feed row records as it plays, so the viewer can pick it up.
        coordinator.record(12.5, for: url)
        XCTAssertEqual(try XCTUnwrap(coordinator.position(for: url)), 12.5, accuracy: 0.001)

        coordinator.beginFullScreen()
        XCTAssertTrue(coordinator.isFullScreenActive)

        // The viewer advances it, and the row resumes from there on dismissal.
        coordinator.record(30, for: url)
        coordinator.endFullScreen()
        XCTAssertFalse(coordinator.isFullScreenActive)
        XCTAssertEqual(try XCTUnwrap(coordinator.position(for: url)), 30, accuracy: 0.001)

        // Garbage from a not-yet-ready player must not clobber a good position.
        coordinator.record(.nan, for: url)
        coordinator.record(-4, for: url)
        XCTAssertEqual(try XCTUnwrap(coordinator.position(for: url)), 30, accuracy: 0.001)

        let unseen = try XCTUnwrap(URL(string: "https://v.redd.it/unseen/DASH_720.mp4"))
        XCTAssertNil(coordinator.position(for: unseen))
    }

    func testMuxOutcomeReportsOnlyGenuineFailures() {
        XCTAssertNil(OctonautMuxOutcome.notApplicable.failureReason)
        XCTAssertNil(OctonautMuxOutcome.merged.failureReason)
        XCTAssertEqual(
            OctonautMuxOutcome.videoOnly(reason: "audio URL returned no audio track").failureReason,
            "audio URL returned no audio track"
        )
    }

    @MainActor
    func testOnlyOneFeedRowOwnsAudioAtATime() throws {
        var activations = 0
        var deactivations = 0
        let coordinator = OctonautPlaybackCoordinator(
            activateAudio: { activations += 1 },
            deactivateAudio: { deactivations += 1 }
        )
        let first = try XCTUnwrap(URL(string: "https://v.redd.it/first/DASH_720.mp4"))
        let second = try XCTUnwrap(URL(string: "https://v.redd.it/second/DASH_720.mp4"))

        XCTAssertFalse(coordinator.isAudioOwner(first))

        coordinator.claimAudio(for: first)
        XCTAssertTrue(coordinator.isAudioOwner(first))
        XCTAssertFalse(coordinator.isAudioOwner(second))
        XCTAssertEqual(activations, 1)

        coordinator.claimAudio(for: first)
        XCTAssertEqual(activations, 1)

        // Moving ownership keeps the same audio-session activation.
        coordinator.claimAudio(for: second)
        XCTAssertFalse(coordinator.isAudioOwner(first))
        XCTAssertTrue(coordinator.isAudioOwner(second))
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(deactivations, 0)

        // A row that no longer owns audio must not be able to release it.
        coordinator.releaseAudio(for: first)
        XCTAssertTrue(coordinator.isAudioOwner(second))
        XCTAssertEqual(deactivations, 0)

        // The feed must release its activation even when a viewer is open.
        coordinator.beginFullScreen()
        coordinator.releaseAudio(for: second)
        XCTAssertFalse(coordinator.isAudioOwner(second))
        XCTAssertEqual(deactivations, 1)
        coordinator.endFullScreen()

        coordinator.claimAudio(for: first)
        coordinator.releaseAudio(for: first)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(deactivations, 2)
    }
}

extension DomainTests {
    @MainActor
    func testCancelledRecoveryDoesNotAdoptItsLateResult() async {
        let recovery = OctonautPlaybackRecovery()
        let started = expectation(description: "Recovery started")
        let adopted = expectation(description: "Cancelled result adopted")
        adopted.isInverted = true
        var pending: CheckedContinuation<Int, Never>?
        recovery.start(load: {
            await withCheckedContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }, onReady: { _ in adopted.fulfill() })
        await fulfillment(of: [started], timeout: 1)
        recovery.cancel()
        pending?.resume(returning: 1)
        await fulfillment(of: [adopted], timeout: 0.1)
    }

    @MainActor
    func testNewRecoveryReplacesThePendingRequest() async {
        let recovery = OctonautPlaybackRecovery()
        let started = expectation(description: "First recovery started")
        let current = expectation(description: "Current result adopted")
        let stale = expectation(description: "Old result adopted")
        stale.isInverted = true
        var pending: CheckedContinuation<Int, Never>?
        recovery.start(load: {
            await withCheckedContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }, onReady: { _ in stale.fulfill() })
        await fulfillment(of: [started], timeout: 1)
        recovery.start(load: { 2 }, onReady: { value in
            XCTAssertEqual(value, 2)
            current.fulfill()
        })
        pending?.resume(returning: 1)
        await fulfillment(of: [current, stale], timeout: 0.1)
    }

    func testStreamingVideoDimensionsUsePortraitSizeAndIgnoreUnloadedSizes() {
        XCTAssertEqual(OctonautVideoDimensions.aspectRatio(for: CGSize(width: 720, height: 1280)), 0.5625)
        XCTAssertNil(OctonautVideoDimensions.aspectRatio(for: .zero))
        XCTAssertNil(OctonautVideoDimensions.aspectRatio(for: CGSize(width: 720, height: 0)))
        XCTAssertNil(OctonautVideoDimensions.aspectRatio(for: CGSize(width: CGFloat.infinity, height: 1280)))
    }

    func testLinkHostNameDropsOnlyALeadingWWW() throws {
        func host(_ string: String) throws -> String {
            LinkHostName.display(for: try XCTUnwrap(URL(string: string)))
        }

        XCTAssertEqual(try host("https://www.theverge.com/2026/story"), "theverge.com")
        XCTAssertEqual(try host("https://WWW.Example.com"), "Example.com")
        XCTAssertEqual(try host("https://theverge.com/story"), "theverge.com")
        // Not a `www.` prefix, however much it looks like one.
        XCTAssertEqual(try host("https://www2.example.com"), "www2.example.com")
        XCTAssertEqual(try host("https://wwwtheverge.com"), "wwwtheverge.com")
        // Nothing to take a host from falls back to the whole thing.
        XCTAssertEqual(try host("mailto:someone@example.com"), "mailto:someone@example.com")
    }

    private static func listingJSON(ids: [String], after: String?) -> Data {
        let children = ids.map { id in
            #"{"kind":"t3","data":{"id":"\#(id)","name":"t3_\#(id)","title":"Post \#(id)","subreddit":"swift","permalink":"/r/swift/comments/\#(id)/title/","author":"reader"}}"#
        }
        let afterValue = after.map { "\"\($0)\"" } ?? "null"
        return Data(#"{"data":{"children":[\#(children.joined(separator: ","))],"after":\#(afterValue)}}"#.utf8)
    }

    @MainActor
    private static func sortSettings(
        rememberCommunity: Bool = false,
        rememberMultireddit: Bool = false
    ) -> SettingsStore {
        let settings = SettingsStore(defaults: UserDefaults(suiteName: "OctonautTests.\(UUID())")!)
        settings.rememberSortPerCommunity = rememberCommunity
        settings.rememberSortPerMultireddit = rememberMultireddit
        return settings
    }

    /// The sort a community was last read with comes back when the reader
    /// returns to it, and does not follow them to another community.
    @MainActor
    func testSortIsRememberedPerCommunity() async throws {
        let persistence = InMemoryPersistenceStore()
        let client = FixtureRedditClient(listingData: Self.listingJSON(ids: ["a"], after: nil))
        let swift = FeedDescriptorModel(kind: .community, name: "swift")
        let apple = FeedDescriptorModel(kind: .community, name: "apple")
        let store = OctonautFeatureStore(
            reddit: client, settings: Self.sortSettings(rememberCommunity: true),
            persistence: persistence)

        await store.refreshPosts(for: swift)
        await store.applySort(.top, topTime: .week, for: swift)
        XCTAssertEqual(store.selectedSort, .top)

        // A different community does not inherit it.
        await store.refreshPosts(for: apple)
        XCTAssertEqual(store.selectedSort, .best)

        // Returning does.
        await store.refreshPosts(for: swift)
        XCTAssertEqual(store.selectedSort, .top)
        XCTAssertEqual(store.selectedTopTime, .week)
    }

    /// The record survives the store, which is the point of writing it.
    @MainActor
    func testARememberedSortOutlivesTheStore() async throws {
        let persistence = InMemoryPersistenceStore()
        let client = FixtureRedditClient(listingData: Self.listingJSON(ids: ["a"], after: nil))
        let swift = FeedDescriptorModel(kind: .community, name: "swift")

        let first = OctonautFeatureStore(
            reddit: client, settings: Self.sortSettings(rememberCommunity: true),
            persistence: persistence)
        await first.refreshPosts(for: swift)
        await first.applySort(.new, for: swift)

        let second = OctonautFeatureStore(
            reddit: client, settings: Self.sortSettings(rememberCommunity: true),
            persistence: persistence)
        await second.refreshPosts(for: swift)

        XCTAssertEqual(second.selectedSort, .new)
    }

    /// With the setting off, sort behaves as it always has: one value that
    /// follows the reader between feeds for the session, and nothing stored.
    @MainActor
    func testSortIsNotRememberedWhenTheSettingIsOff() async throws {
        let persistence = InMemoryPersistenceStore()
        let client = FixtureRedditClient(listingData: Self.listingJSON(ids: ["a"], after: nil))
        let swift = FeedDescriptorModel(kind: .community, name: "swift")
        let apple = FeedDescriptorModel(kind: .community, name: "apple")
        let store = OctonautFeatureStore(
            reddit: client, settings: Self.sortSettings(), persistence: persistence)

        await store.refreshPosts(for: swift)
        await store.applySort(.top, for: swift)
        await store.refreshPosts(for: apple)

        XCTAssertEqual(store.selectedSort, .top, "Sort still carries across feeds when nothing is remembered")
        let stored = try await persistence.loadFeedPreference(
            feedKey: "community:swift", accountScope: "anonymous")
        XCTAssertNil(stored)
    }

    /// Switching account resolves again, so the sort one reader left on a
    /// community does not carry into another reader's session.
    @MainActor
    func testARememberedSortDoesNotCarryAcrossAnAccountSwitch() async throws {
        let persistence = InMemoryPersistenceStore()
        let client = FixtureRedditClient(listingData: Self.listingJSON(ids: ["a"], after: nil))
        let swift = FeedDescriptorModel(kind: .community, name: "swift")
        let store = OctonautFeatureStore(
            reddit: client, accountID: AccountID(),
            settings: Self.sortSettings(rememberCommunity: true),
            persistence: persistence)

        await store.refreshPosts(for: swift)
        await store.applySort(.top, topTime: .week, for: swift)
        XCTAssertEqual(store.selectedSort, .top)

        store.synchronizeAccount(id: AccountID(), generation: 1, accounts: [])
        await store.refreshPosts(for: swift)

        // The second reader has no record for this community, so it opens at
        // the configured default and not on the first reader's Top.
        XCTAssertEqual(store.selectedSort, .best)
    }

    /// Communities and multireddits are governed by their own settings.
    @MainActor
    func testMultiredditSortIsGovernedByItsOwnSetting() async throws {
        let persistence = InMemoryPersistenceStore()
        let client = FixtureRedditClient(listingData: Self.listingJSON(ids: ["a"], after: nil))
        let multi = FeedDescriptorModel(kind: .multireddit, name: "devtools")
        let store = OctonautFeatureStore(
            reddit: client, settings: Self.sortSettings(rememberCommunity: true),
            persistence: persistence)

        await store.refreshPosts(for: multi)
        await store.applySort(.rising, for: multi)

        let stored = try await persistence.loadFeedPreference(
            feedKey: "multireddit:devtools", accountScope: "anonymous")
        XCTAssertNil(stored)
    }
}


extension DomainTests {
    @MainActor
    func testReenablingRememberSortReloadsCommunityPreference() async throws {
        try await checkReenabledSort(kind: .community)
    }

    @MainActor
    func testReenablingRememberSortReloadsMultiredditPreference() async throws {
        try await checkReenabledSort(kind: .multireddit)
    }

    @MainActor
    private func checkReenabledSort(kind: FeedDescriptorModel.Kind) async throws {
        let persistence = InMemoryPersistenceStore()
        let settings = Self.sortSettings(
            rememberCommunity: kind == .community, rememberMultireddit: kind == .multireddit)
        let client = FixtureRedditClient(listingData: Self.listingJSON(ids: ["a"], after: nil))
        let feed = FeedDescriptorModel(kind: kind, name: "swift")
        try await persistence.saveFeedPreference(
            FeedSortPreference(sort: .top, topTime: .week),
            feedKey: "\(kind.rawValue):swift", accountScope: "anonymous")
        let store = OctonautFeatureStore(reddit: client, settings: settings, persistence: persistence)
        await store.refreshPosts(for: feed)
        XCTAssertEqual(store.selectedSort, .top)
        if kind == .community {
            settings.rememberSortPerCommunity = false
        } else {
            settings.rememberSortPerMultireddit = false
        }
        await store.applySort(.new, for: feed)
        if kind == .community {
            settings.rememberSortPerCommunity = true
        } else {
            settings.rememberSortPerMultireddit = true
        }
        await store.refreshPosts(for: feed)
        XCTAssertEqual(store.selectedSort, .top)
        XCTAssertEqual(store.selectedTopTime, .week)

        // Keep the other setting on, then toggle without loading a feed in between.
        if kind == .community {
            settings.rememberSortPerMultireddit = true
        } else {
            settings.rememberSortPerCommunity = true
        }
        await store.refreshPosts(for: feed)
        try await persistence.saveFeedPreference(
            FeedSortPreference(sort: .rising),
            feedKey: "\(kind.rawValue):swift", accountScope: "anonymous")
        if kind == .community {
            settings.rememberSortPerCommunity = false
            settings.rememberSortPerCommunity = true
        } else {
            settings.rememberSortPerMultireddit = false
            settings.rememberSortPerMultireddit = true
        }
        await store.refreshPosts(for: feed)
        XCTAssertEqual(store.selectedSort, .rising)
    }

    @MainActor
    func testCancelledPreferenceReadLeavesCurrentFeedAlone() async throws {
        try await checkStalePreferenceRead(cancelOldLoad: true)
    }

    @MainActor
    func testSupersededPreferenceReadLeavesCurrentFeedAlone() async throws {
        try await checkStalePreferenceRead(cancelOldLoad: false)
    }

    @MainActor
    private func checkStalePreferenceRead(cancelOldLoad: Bool) async throws {
        let backing = InMemoryPersistenceStore()
        let persistence = PausedFeedPreferenceStore(backing: backing, feedKey: "community:swift")
        let settings = Self.sortSettings(rememberCommunity: true)
        let client = FixtureRedditClient(listingData: Self.listingJSON(ids: ["a"], after: nil))
        let swift = FeedDescriptorModel(kind: .community, name: "swift")
        let apple = FeedDescriptorModel(kind: .community, name: "apple")
        try await backing.saveFeedPreference(
            FeedSortPreference(sort: .top, topTime: .week),
            feedKey: "community:swift", accountScope: "anonymous")
        try await backing.saveFeedPreference(
            FeedSortPreference(sort: .new), feedKey: "community:apple", accountScope: "anonymous")
        let store = OctonautFeatureStore(reddit: client, settings: settings, persistence: persistence)
        await store.refreshPosts(for: apple)
        let oldLoad = Task { await store.refreshPosts(for: swift) }
        await persistence.waitForRead()
        if cancelOldLoad {
            // No replacement request: cancellation alone must reject the result.
            oldLoad.cancel()
        } else {
            store.clearVisibleFeed()
            await store.refreshPosts(for: apple)
        }
        XCTAssertEqual(store.selectedSort, .new)
        XCTAssertEqual(store.feedState, .loaded)
        let currentPosts = store.posts.map(\.id)
        await persistence.resumeRead()
        await oldLoad.value
        XCTAssertEqual(store.selectedSort, .new)
        XCTAssertEqual(store.feedState, .loaded)
        XCTAssertEqual(store.posts.map(\.id), currentPosts)
    }
}

/// Holds one preference read until the test has switched feeds.
private actor PausedFeedPreferenceStore: PersistenceStore {
    let backing: InMemoryPersistenceStore
    private var pausedFeedKey: String?
    private var readStarted = false
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var readContinuation: CheckedContinuation<Void, Never>?

    init(backing: InMemoryPersistenceStore, feedKey: String) {
        self.backing = backing
        pausedFeedKey = feedKey
    }

    func waitForRead() async {
        if readStarted { return }
        await withCheckedContinuation { startContinuation = $0 }
    }

    func resumeRead() {
        readContinuation?.resume()
        readContinuation = nil
    }

    func loadFeedPreference(feedKey: String, accountScope: String) async throws -> FeedSortPreference? {
        if feedKey == pausedFeedKey {
            pausedFeedKey = nil
            readStarted = true
            startContinuation?.resume()
            startContinuation = nil
            // Ignore cancellation so the caller must reject the stale result itself.
            await withCheckedContinuation { readContinuation = $0 }
        }
        return try await backing.loadFeedPreference(feedKey: feedKey, accountScope: accountScope)
    }

    func loadAccounts() async throws -> [Account] {
        return try await backing.loadAccounts()
    }

    func saveAccount(_ account: Account) async throws {
        try await backing.saveAccount(account)
    }

    func deleteAccount(_ id: AccountID) async throws {
        try await backing.deleteAccount(id)
    }

    func loadSeenPostIDs() async throws -> [String] {
        return try await backing.loadSeenPostIDs()
    }

    func markPostSeen(_ id: String, seenAt: Date) async throws {
        try await backing.markPostSeen(id, seenAt: seenAt)
    }

    func removePostSeen(_ id: String) async throws {
        try await backing.removePostSeen(id)
    }

    func clearSeenPosts() async throws {
        try await backing.clearSeenPosts()
    }

    func loadDrafts(accountID: AccountID?) async throws -> [Draft] {
        return try await backing.loadDrafts(accountID: accountID)
    }

    func saveDraft(_ draft: Draft) async throws {
        try await backing.saveDraft(draft)
    }

    func deleteDraft(_ id: UUID) async throws {
        try await backing.deleteDraft(id)
    }

    func clearDrafts(accountID: AccountID?) async throws {
        try await backing.clearDrafts(accountID: accountID)
    }

    func saveFeedPreference(_ preference: FeedSortPreference, feedKey: String, accountScope: String) async throws {
        try await backing.saveFeedPreference(preference, feedKey: feedKey, accountScope: accountScope)
    }

    func loadUsageStatistics() async throws -> UsageStatistics {
        return try await backing.loadUsageStatistics()
    }

    func incrementStatistic(_ counter: UsageStatistic, by amount: Int) async throws {
        try await backing.incrementStatistic(counter, by: amount)
    }

    func beginUsageSession() async {
        await backing.beginUsageSession()
    }

    func recordCommunityVisit(_ community: String) async throws {
        try await backing.recordCommunityVisit(community)
    }

    func resetUsageStatistics() async throws {
        try await backing.resetUsageStatistics()
    }

    func removeAllData() async throws {
        try await backing.removeAllData()
    }
}


extension DomainTests {
    func testUsernameProfileDestinationsRejectDeletedUsersAndUnsafePaths() {
        XCTAssertEqual(OctonautUserDestination.route(for: "some_user-1"), .account("some_user-1"))
        for invalid in ["", "[deleted]", "../settings", "user?x=1", "https://example.com", "user name"] {
            XCTAssertNil(OctonautUserDestination.route(for: invalid))
            XCTAssertNil(OctonautUserDestination.profileURL(for: invalid))
        }
        XCTAssertEqual(OctonautUserDestination.profileURL(for: "some_user")?.absoluteString,
                       "https://www.reddit.com/user/some_user/")
    }

    func testFollowUsesProfileSubscriptionAndUnfollowReversesIt() {
        let follow = URLSessionRedditClient.mutationRequest(for: .follow(username: "some_user", following: true))
        XCTAssertEqual(follow.method, "POST")
        XCTAssertEqual(follow.path, "/api/subscribe")
        XCTAssertEqual(follow.fields["sr_name"], "u_some_user")
        XCTAssertEqual(follow.fields["action"], "sub")
        let unfollow = URLSessionRedditClient.mutationRequest(for: .follow(username: "some_user", following: false))
        XCTAssertEqual(unfollow.fields["action"], "unsub")
    }

    func testBlockRequestNamesTheSelectedUser() {
        let request = URLSessionRedditClient.mutationRequest(for: .block(username: "some_user", blocked: true))
        XCTAssertEqual(request.path, "/api/block_user")
        XCTAssertEqual(request.fields["name"], "some_user")
        XCTAssertEqual(request.fields["api_type"], "json")
    }

    func testProfileFollowingUsesSubscriptionRatherThanFriendStatus() throws {
        let data = Data(#"{"data":{"name":"some_user","is_friend":false,"subreddit":{"user_is_subscriber":true}}}"#.utf8)
        XCTAssertTrue(try RedditJSONCodec.decodeUserProfile(data).isFollowing)
        let friend = Data(#"{"data":{"name":"some_user","is_friend":true,"subreddit":{"user_is_subscriber":false}}}"#.utf8)
        XCTAssertFalse(try RedditJSONCodec.decodeUserProfile(friend).isFollowing)
    }
}


extension DomainTests {
    @MainActor
    func testProfileActionsUpdateOnlyAfterSuccessAndAccountSwitchClearsProfile() async throws {
        let account = AccountID()
        let store = OctonautFeatureStore(reddit: FixtureRedditClient(), accountID: account)
        await store.loadUserProfile(username: "reader", forceRefresh: true)
        try await store.performProfileAction(.follow(username: "reader", following: true), username: "reader", accountID: account)
        XCTAssertEqual(store.userProfile?.isFollowing, true)
        try await store.performProfileAction(.follow(username: "reader", following: false), username: "reader", accountID: account)
        XCTAssertEqual(store.userProfile?.isFollowing, false)
        try await store.performProfileAction(.block(username: "reader", blocked: true), username: "reader", accountID: account)
        XCTAssertEqual(store.userProfile?.isBlocked, true)
        try await store.performProfileAction(.block(username: "reader", blocked: false), username: "reader", accountID: account)
        XCTAssertEqual(store.userProfile?.isBlocked, false)
        store.setAccountID(AccountID())
        XCTAssertNil(store.userProfile)
        XCTAssertTrue(store.userProfilePosts.isEmpty)
        do {
            try await store.performProfileAction(.follow(username: "reader", following: true), username: "reader", accountID: account)
            XCTFail("Old account must not perform a profile action")
        } catch {
            XCTAssertEqual(error as? RedditClientError, .authenticationRequired)
        }
    }

    @MainActor
    func testFailedProfileActionPreservesRelationshipState() async {
        let account = AccountID()
        let client = FixtureRedditClient(actionResult: ActionResult(succeeded: false, message: "Action denied"))
        let store = OctonautFeatureStore(reddit: client, accountID: account)
        await store.loadUserProfile(username: "reader", forceRefresh: true)
        do {
            try await store.performProfileAction(.follow(username: "reader", following: true), username: "reader", accountID: account)
            XCTFail("Failed action must report the error")
        } catch {
            XCTAssertEqual(error as? RedditClientError, .reddit(errors: ["Action denied"]))
        }
        XCTAssertEqual(store.userProfile?.isFollowing, false)
    }
}


extension DomainTests {
    func testUnblockRemovesTheBlockedRelationship() {
        let request = URLSessionRedditClient.mutationRequest(for: .block(username: "reader", blocked: false))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/api/unfriend")
        XCTAssertEqual(request.fields["name"], "reader")
        XCTAssertEqual(request.fields["type"], "enemy")
        XCTAssertNil(request.fields["container"])
    }
}

@MainActor
final class LoginRequirementTests: XCTestCase {
    func testAnonymousActionsRequestLogin() {
        let dependencies = AppDependencies.preview()
        XCTAssertFalse(dependencies.accounts.requireLogin())
        XCTAssertTrue(dependencies.accounts.showingLoginRequired)
        dependencies.accounts.showingLoginRequired = false
        XCTAssertNil(dependencies.accounts.selectedAccountID)
    }

    func testHealthyAccountAllowsActionsAndExpiredAccountRequestsLogin() async throws {
        let dependencies = AppDependencies.preview()
        let healthy = Account(username: "reader", health: .healthy)
        try await dependencies.persistence.saveAccount(healthy)
        await dependencies.accounts.load()
        XCTAssertTrue(dependencies.accounts.requireLogin())
        XCTAssertFalse(dependencies.accounts.showingLoginRequired)
        let router = OctonautFeatureRouter()
        router.accounts = dependencies.accounts
        router.push(.account("reader"))
        XCTAssertEqual(router.path, [.account("reader")])
        router.presentedSheet = .composer(.post, community: "swift")
        XCTAssertEqual(router.presentedSheet, .composer(.post, community: "swift"))
        await dependencies.accounts.markNeedsLogin(healthy.id)
        XCTAssertFalse(dependencies.accounts.requireLogin())
        XCTAssertTrue(dependencies.accounts.showingLoginRequired)
    }

    func testProtectedRoutesAndComposerStayClosedWhenAnonymous() {
        let dependencies = AppDependencies.preview()
        let router = OctonautFeatureRouter(path: [.feed(.home)])
        router.accounts = dependencies.accounts
        router.push(.account("reader"))
        XCTAssertEqual(router.path, [.feed(.home)])
        router.path = [.composer(.post)]
        XCTAssertEqual(router.path, [.feed(.home)])
        router.presentedSheet = .composer(.post, community: "swift")
        XCTAssertNil(router.presentedSheet)
        XCTAssertTrue(dependencies.accounts.showingLoginRequired)
        router.push(.community("swift"))
        XCTAssertEqual(router.path.last, .community("swift"))
    }
}

@MainActor
final class AccountLogoutTests: XCTestCase {
    func testLogoutStaysAnonymousAfterAccountListReloads() async throws {
        let dependencies = AppDependencies.preview()
        let account = Account(username: "reader", health: .healthy)
        try await dependencies.persistence.saveAccount(account)
        await dependencies.accounts.load()
        XCTAssertEqual(dependencies.accounts.selectedAccountID, account.id)
        let previousToken = dependencies.accounts.token()

        try await dependencies.accounts.logOut()
        await dependencies.accounts.load()
        await dependencies.accounts.load()

        XCTAssertNil(dependencies.accounts.selectedAccountID)
        XCTAssertNil(dependencies.accounts.selectedAccount)
        XCTAssertTrue(dependencies.accounts.accounts.isEmpty)
        XCTAssertFalse(dependencies.accounts.isCurrent(previousToken))
        XCTAssertFalse(dependencies.accounts.requireLogin())
    }

    func testAnonymousSelectionBeforeInitialLoadIsPreserved() async throws {
        let dependencies = AppDependencies.preview()
        try await dependencies.persistence.saveAccount(Account(username: "reader", health: .healthy))
        try await dependencies.accounts.select(nil)
        await dependencies.accounts.load()
        XCTAssertNil(dependencies.accounts.selectedAccountID)
    }

    func testLogoutAndExplicitAccountSelectionSurviveRestart() async throws {
        let suite = "OctonautTests.account-selection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let persistence = InMemoryPersistenceStore()
        let vault = InMemoryCredentialVault()
        let account = Account(username: "reader", health: .healthy)
        try await persistence.saveAccount(account)
        func coordinator() -> AccountCoordinator {
            AccountCoordinator(persistence: persistence, secrets: CredentialVaultSecretStore(vault: vault), selectionDefaults: defaults)
        }
        let first = coordinator()
        await first.load()
        try await first.logOut()

        let restarted = coordinator()
        await restarted.load()
        XCTAssertNil(restarted.selectedAccountID)
        let remainingAccounts = try await persistence.loadAccounts()
        XCTAssertTrue(remainingAccounts.isEmpty)
        try await persistence.saveAccount(account)
        await restarted.load()
        try await restarted.select(account.id)

        let selectedAgain = coordinator()
        await selectedAgain.load()
        XCTAssertEqual(selectedAgain.selectedAccountID, account.id)
    }
}

@MainActor
final class LogoutCredentialTests: XCTestCase {
    func testLogoutDeletesCredentialAndKeepsOtherAccountsUnselected() async throws {
        let persistence = InMemoryPersistenceStore()
        let vault = InMemoryCredentialVault()
        let secrets = CredentialVaultSecretStore(vault: vault)
        let coordinator = AccountCoordinator(persistence: persistence, secrets: secrets)
        let other = Account(username: "other", health: .healthy)
        let selected = Account(username: "reader", health: .healthy)
        let secret = SessionSecret(cookieName: "reddit_session", cookieValue: "synthetic-session", modhash: "synthetic-modhash", redditUser: "reader", validatedAt: .now)
        try await coordinator.add(other, secret: secret)
        try await coordinator.add(selected, secret: secret)
        try await coordinator.logOut()
        await coordinator.load()

        XCTAssertNil(coordinator.selectedAccountID)
        XCTAssertEqual(coordinator.accounts.map(\.id), [other.id])
        let deletedCredential = try await vault.credential(for: selected.id)
        let otherCredential = try await vault.credential(for: other.id)
        XCTAssertNil(deletedCredential)
        XCTAssertNotNil(otherCredential)
        let savedAccounts = try await persistence.loadAccounts()
        XCTAssertEqual(savedAccounts.map(\.id), [other.id])
    }
}
