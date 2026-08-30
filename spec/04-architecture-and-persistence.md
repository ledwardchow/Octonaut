# Architecture and persistence

## Technical baseline

Octonaut is a Swift 6 application using SwiftUI, structured concurrency, Observation, SwiftData, Keychain Services, URLSession, WebKit, AVFoundation, VisionKit, NaturalLanguage, and Foundation Models. The deployment targets are iOS and iPadOS 26, and macOS 26. Newer API use stays behind availability checks. Do not put business logic in SwiftUI view bodies.

The iOS and macOS targets share domain models, Reddit transport, authentication, persistence, search, and intelligence services. Each platform has its own app entry point and interface shell.

`ARCH-001` Build feature code against protocols. Live Reddit, local fixture, and test implementations must be replaceable through one dependency container.

`ARCH-002` Treat account selection, Reddit request execution, persistence, media exports, and model sessions as actor-isolated resources. Swift 6 strict concurrency warnings are build failures.

`ARCH-003` UI-owned observable state runs on `@MainActor`. Decoding, HTML cleaning, image processing, indexing, filtering, and export work runs away from the main actor.

## Suggested package layout

```text
OctonautApp/
  App/                 OctonautApp, AppDependencies, scene and URL routing
  DesignSystem/        theme tokens and reusable native components
  Features/
    Posts/ Inbox/ Account/ Search/ Settings/
    PostDetail/ Community/ Composer/ Media/ Gallery/
  Domain/              stable models, value types, use cases, protocols
  RedditTransport/     requests, DTOs, decoding, web-session authentication
  Persistence/         SwiftData models, repositories, settings, Keychain
  Intelligence/        Foundation Models, filtering, docs retrieval, fallbacks
  Media/               images, AVPlayer, export, Live Text
  Support/             logging, reachability, clocks, HTML/Markdown, fixtures
OctonautShareExtension/
OctonautTests/
OctonautUITests/
```

Features may be Swift Package targets if compile-time boundaries remain practical. `Domain` must not import SwiftUI, WebKit, SwiftData, or a concrete networking implementation.

## Dependency container

`ARCH-010` The app creates long-lived services once and injects them through the SwiftUI environment. Suggested contracts:

```swift
@MainActor @Observable
final class AppDependencies {
    let accounts: AccountCoordinator
    let reddit: any RedditClient
    let persistence: any PersistenceStore
    let media: any MediaService
    let intelligence: any IntelligenceService
    let links: any LinkRouter
    let settings: SettingsStore
}

protocol RedditClient: Sendable {
    func listing(_ request: ListingRequest, account: AccountID?) async throws -> Listing<Post>
    func post(_ permalink: URL, sort: CommentSort, account: AccountID?) async throws -> PostThread
    func perform(_ action: RedditAction, account: AccountID) async throws -> ActionResult
}

protocol IntelligenceService: Sendable {
    var availability: IntelligenceAvailability { get async }
    func summarizePost(_ input: PostSummaryInput) async throws -> ContentSummary
    func summarizeComments(_ input: CommentSummaryInput) async throws -> ContentSummary
    func classify(_ inputs: [FilterInput], rule: SemanticRule) async throws -> [FilterDecision]
    func answerHelp(_ question: String) async throws -> HelpAnswer
}
```

Use narrower subprotocols or clients if the concrete `RedditClient` becomes too broad. Feature stores receive only what they use.

## Navigation and presentation

`ARCH-020` Each tab has an `@MainActor @Observable` router with a typed `[AppRoute]` path. Modal presentation is an optional `SheetRoute` enum. Do not use independent Boolean flags for every sheet.

`ARCH-021` Restorable route state contains stable IDs and URLs only. Never retain decoded post trees, view models, credentials, or `AVPlayer` objects in navigation state.

`ARCH-022` iPhone uses a navigation stack. iPad may render feed and detail in `NavigationSplitView`; it uses the same routes and feature stores, and collapses predictably to the iPhone order.

## Async screen state

Every remotely loaded feature uses an explicit state:

```swift
enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value, refreshedAt: Date)
    case failed(DisplayableError, previous: Value?)
}
```

`ARCH-030` A view shows cached or previous content during refresh and recoverable failures. A request has a stable identity consisting of route, sort, active account, and filter revision. Changing identity cancels the old task.

`ARCH-031` Feature stores expose intent methods such as `refresh()`, `loadNextPage()`, and `vote(_:)`. Views must not assemble transport requests.

`ARCH-032` Use task cancellation as normal control flow. A cancelled request must not display an error. Retry policy applies only to idempotent reads unless a mutation has an idempotency guarantee.

## Domain models

All Reddit names use their fullname when available, for example `t3_postID` and `t1_commentID`. Raw DTOs remain internal to `RedditTransport`.

```swift
struct Listing<Element: Sendable>: Sendable {
    var items: [Element]
    var after: String?
    var before: String?
}

struct Post: Identifiable, Sendable {
    let id: String
    let fullname: String
    let permalink: URL
    let community: CommunityReference
    let author: UserReference?
    var title: String
    var body: RichText?
    var flair: Flair?
    var createdAt: Date
    var score: Int
    var commentCount: Int
    var vote: VoteState
    var isSaved: Bool
    var isHidden: Bool
    var isNSFW: Bool
    var isSpoiler: Bool
    var isLocked: Bool
    var isArchived: Bool
    var isSticky: Bool
    var media: PostMedia
    var crosspost: CrosspostReference?
}

struct CommentNode: Identifiable, Sendable {
    let id: String
    let fullname: String
    let parentFullname: String
    var author: UserReference?
    var body: RichText?
    var createdAt: Date
    var score: Int
    var vote: VoteState
    var isSaved: Bool
    var isLocked: Bool
    var isDistinguished: Bool
    var children: [CommentTreeNode]
}

enum CommentTreeNode: Identifiable, Sendable {
    case comment(CommentNode)
    case more(MoreCommentsNode)
    case deleted(DeletedCommentNode)
}
```

Also define `Community`, `CommunityReference`, `UserProfile`, `UserReference`, `InboxItem`, `Message`, `Multireddit`, `WikiPage`, `Rule`, `Flair`, `RichText`, `LinkMetadata`, `PostMedia`, `VoteState`, `FeedDescriptor`, and all sort enums. Domain types must tolerate missing fields and unknown media without losing the original permalink.

`ARCH-040` `RichText` stores plain text plus parsed display spans and links, or a sanitized document tree. Never render Reddit-provided HTML in an unrestricted web view. Decode entities, allow a small tag set, reject scripts/styles/iframes, normalize links, and render with `AttributedString` or native subviews.

`ARCH-041` Unknown enum values decode to `.unknown(rawValue)` or an equivalent tolerant representation. One malformed child must not discard a whole listing.

## Persistence ownership

Use SwiftData for structured local records, Keychain for secrets, `UserDefaults` or `@AppStorage` for small preferences, and `URLCache` or files for replaceable network/media caches.

### SwiftData entities

`AccountRecord`

- Stable local UUID, Reddit username, avatar URL, created date, last-used date, last validation date, and health state.
- Keychain lookup key only. Never contains the cookie or modhash.

`SeenPostRecord`

- Post ID, first seen date, last seen date, and source.
- Unique on post ID. Oldest last-seen records are pruned beyond 5,000.

`DraftRecord`

- UUID, composer kind, account ID, target descriptor, title, body, link, selected flair, created date, modified date, and optional upload recovery metadata.
- Pruned beyond 100 according to `FUN-COMPOSE-005`.

`FavoriteCommunityRecord`

- Normalized name, display name, icon URL, manual position, created date.

`FilteredCommunityRecord`

- Normalized name, created date, optional expiration date, source post ID.

`KeywordRuleRecord`

- UUID, enabled state, newline-delimited terms, fields to search, whole-word state, case behavior, and creation date.

`SemanticRuleRecord`

- UUID, name, natural-language instruction, enabled state, creation date, update date.

`FeedPreferenceRecord`

- Account ID or anonymous scope, normalized feed key, sort, top time, and optional URL rewrite override.

`CustomThemeRecord`

- UUID, name, token payload version, light token set, optional dark token set, and modified date.

`StatisticRecord` and `CommunityVisitRecord`

- Counter name and integer value, or normalized community and visit count. Do not save event-by-event history.

`SummaryCacheRecord`

- Content kind, content ID, SHA-256 input hash, prompt version, model family, generated text, creation date, and last-used date. No raw Reddit body is duplicated here.

`HelpIndexRecord`

- Document ID, section ID, title, normalized text, bundle version, and lexical index fields. Embedding vectors may be kept in a versioned binary sidecar.

### Preferences

`ARCH-050` Preferences have typed keys, declared defaults, validation, and migration versions. Export omits credentials, account identifiers, history, drafts, and cached content unless the user separately requests those items.

`ARCH-051` Theme changes are immediately visible. Network-affecting settings increment a configuration revision and apply to new requests. Filter changes increment a filter revision and re-evaluate visible listings without refetching when inputs are present.

### Account scoping

`ARCH-052` Reddit-derived personalized cache, inbox state, feed preferences, and drafts carry an account ID. Anonymous content uses a distinct anonymous scope. Favorites, appearance, filters, and general settings are device-wide. Tests must prove that data cannot leak between account scopes.

## Networking and cache

`ARCH-060` Use an ephemeral or deliberately configured URLSession. Credentials are attached by the Reddit transport per request. Do not put Reddit session cookies into the process-wide shared cookie store.

`ARCH-061` Cache public GET responses according to HTTP headers, with a conservative app maximum. Personalized responses may be cached encrypted or held only in memory; release one should prefer memory plus small account-scoped disk entries that are removed on sign-out.

`ARCH-062` Image decoding and resizing happen off-main. Cache the rendered size class, not just original bytes. Prefetch only near visible rows and cancel when direction changes. Low Data Mode disables full media prefetch.

`ARCH-063` Link preview fetches use HTTPS, a small byte and redirect limit, and reject private/local network destinations to prevent server-side request style behavior on the device. Parse only enough HTML for title, description, image, and site name.

## Media architecture

`ARCH-070` A shared playback coordinator owns inline playback priority and audio-session state. Rows own lightweight view state, not long-lived player instances. Full-screen playback may transfer the active item.

`ARCH-071` Media export is an actor-managed job with ID, progress, cancellation, source URLs, output URL, and cleanup deadline. Temporary outputs live in Caches or tmp and are excluded from backup.

`ARCH-072` Use `ImageAnalyzer` and `ImageAnalysisInteraction` through a small UIKit adapter for Live Text. The adapter must not retain an old image analysis after the displayed asset changes.

## Diagnostics and logging

`ARCH-080` Use `Logger` categories for app, accounts, reddit, persistence, media, intelligence, and routing. Production logs may include route families, status codes, durations, byte counts, and anonymous error categories. They must not include cookies, modhashes, passwords, message bodies, post/comment bodies, queries, or complete private URLs.

`ARCH-081` A user-triggered diagnostic export contains app/build/OS versions, settings with private fields removed, recent sanitized errors, cache sizes, AI availability, and account count. It never includes account names unless the user enables that field on the export confirmation screen.

## Fixtures and previews

`ARCH-090` Keep redacted JSON fixtures for each listing and mutation shape, including malformed and missing fields, rate limits, private/quarantined communities, deep comments, `more` nodes, all media types, inbox types, and expired sessions.

`ARCH-091` Every major screen has SwiftUI previews using deterministic fixture services for loaded, loading, empty, failed, NSFW, long text, right-to-left, and accessibility text-size states.
