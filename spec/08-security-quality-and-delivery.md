# Security, quality, and delivery

## Security requirements

`SEC-001` Reddit session cookies and modhashes are secrets. Store them only in Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, without synchronization. Access is limited to the account coordinator and Reddit transport.

`SEC-002` Never log, display, export, back up, or place credentials on the pasteboard. Redaction tests must cover request headers, URL query values, web-view callbacks, Keychain errors, and crash descriptions.

`SEC-003` All remote traffic uses HTTPS and App Transport Security. No broad arbitrary-load exception is allowed. An exception for a specific media host requires a documented test and review.

`SEC-004` Redirect handling strips Reddit credentials before following any redirect whose destination is outside the exact Reddit allowlist. Upload destinations use the one-time fields returned by Reddit and receive no Reddit cookie.

`SEC-005` Login uses a nonpersistent `WKWebsiteDataStore` per attempt. On success, cancellation, or failure, destroy the web view and remove its temporary website data. No app script reads login form contents.

`SEC-006` Sanitize Reddit HTML and Markdown. Disallow scripts, styles, event handlers, inline frames, dangerous URL schemes, and invisible interaction overlays. External links pass through the URL router.

`SEC-007` Link metadata fetching rejects loopback, link-local, private network, file, data, JavaScript, and non-HTTPS targets. Revalidate each redirect and cap response bytes and duration.

`SEC-008` Imported themes, link rules, and settings are inert data with schema versions and size limits. They cannot include executable JavaScript, Swift, HTML, regular-expression denial-of-service patterns, or arbitrary file paths.

`SEC-009` Uploaded images remove location metadata by default. Temporary uploads and media exports use file protection, are excluded from backup, and are deleted on cancellation or expiry.

`SEC-010` Local model prompts stay in memory unless represented by the summary cache rules. Do not place private messages, account credentials, browsing history, or drafts into a model prompt except the exact user-visible text being intentionally processed.

`SEC-011` Account selection is explicit in every authenticated transport call. There is no mutable global cookie header. A generation number prevents responses from an old account updating the new account's UI.

`SEC-012` Destructive Reddit actions require confirmation. Destructive local actions enumerate their target. No retry loop repeats a non-idempotent request silently.

`SEC-013` Provide an Apple privacy manifest covering used required-reason APIs. Keep third-party SDKs out of release one unless their data practices are separately specified and disclosed.

## Privacy behavior

`PRIV-001` Octonaut has no analytics, advertising identifier, subscription SDK, hosted AI call, or developer-operated account service in release one.

`PRIV-002` Logged-out requests still disclose normal network information to Reddit and media hosts. Privacy copy must say this clearly rather than implying offline browsing.

`PRIV-003` Local statistics are counters, not a detailed event stream. They never contain a post title, comment body, message body, search query, or timestamped browsing trail.

`PRIV-004` The privacy screen accurately lists stored data and provides deletion controls. App deletion remains the final complete removal mechanism for device-local data.

## Accessibility

`A11Y-001` All text supports Dynamic Type through accessibility sizes. Core reading, voting, commenting, account, and settings flows must not require horizontal scrolling at large sizes.

`A11Y-002` VoiceOver labels a post with title, community, author when present, score state, comment count, media type/count, NSFW/spoiler state, and seen state. Actions expose custom accessibility actions for vote, save, reply, collapse, and share.

`A11Y-003` Comments announce depth, collapsed state, author, distinguished status, score, and child count. Colored depth rails are never the sole expression of hierarchy or state.

`A11Y-004` Media controls have labels, values, and adjustable actions. Captions and alternate audio are exposed when the source provides them. Autoplay honors Reduce Motion and never starts audible playback without user action.

`A11Y-005` Color is not the only vote, saved, error, filter, or moderation indicator. Themes meet readable contrast. Differentiate Without Color remains usable.

`A11Y-006` Swipe actions have equivalent context-menu and accessible actions. No feature depends only on a long press, precise drag, or multi-finger gesture.

`A11Y-007` Loading progress, newly inserted comments, failed actions, account switches, and generated summary completion issue restrained accessibility announcements without interrupting continuous reading.

## Performance budgets

Budgets are measured on the oldest supported Apple Intelligence-capable phone and a representative non-capable iOS 26 phone using release builds and fixture-backed repeatable tests.

`PERF-001` Warm launch should present the app shell and cached visible content within 500 ms. Cold launch should present an interactive shell within 1.5 seconds. Login validation and AI initialization do not block first paint.

`PERF-002` Feed and comment scrolling should sustain the device refresh rate under ordinary mixed content. Main-thread stalls longer than 100 ms are defects. Avoid unstable row IDs, eager full-list formatting, synchronous image decode, and one observer per visibility pixel change.

`PERF-003` Keep only visible and near-visible rendered media. Memory warnings cancel prefetch, discard decoded off-screen images, stop unused players, and trim local model/session work.

`PERF-004` First listing fetch is bounded to a practical page size, normally 25 to 50. Flattened comment presentation recomputes incrementally where practical and must handle at least 2,000 decoded nodes without recursion crashes.

`PERF-005` AI work has lower priority than visible network, input, media, and navigation work. Only one generation task runs at a time by default. Semantic classification batches requests and never launches a session per row.

`PERF-006` Media export and help indexing show progress, support cancellation, run away from the main actor, and survive ordinary scene transitions. They do not need to survive force quit in release one.

## Reliability and offline behavior

`QUAL-001` Cached public feeds and opened posts may be read offline with a visible Last Updated value. Mutations are disabled offline. Do not queue votes, comments, messages, or deletes for later automatic sending.

`QUAL-002` Drafts, settings, favorites, filters, themes, statistics, and bundled help remain usable offline. Local model features work when Apple reports the model available without a network connection.

`QUAL-003` Database migrations are additive and version-tested. Before a destructive migration, preserve credentials and drafts or stop and show a recovery message. A failed migration must not silently recreate an empty store.

`QUAL-004` Unknown Reddit fields and object kinds do not crash decoding. Preserve an open-in-browser fallback for unsupported content.

`QUAL-005` Handle memory pressure, backgrounding, protected-data unavailability before first unlock, time changes, locale changes, and account removal while screens are open.

## Test plan

### Unit tests

- URL normalization and internal routing for every supported Reddit host and route.
- Form encoding, allowed hosts, credential attachment, redirect stripping, modhash renewal, and rate-limit parsing.
- DTO decoding for every fixture described by `ARCH-090`, including partial failure.
- Pagination deduplication, repeated cursors, filtered empty pages, cancellation, and account-generation guards.
- Vote/save optimistic transitions and rollback.
- Comment tree construction, `more` insertion, collapsing, flattening, and next/previous navigation.
- Markdown/HTML sanitization with common XSS and dangerous URL payloads.
- Filter normalization, Unicode whole-word matching, expiry, precedence, and override behavior.
- Summary input selection, content hashing, cache invalidation, structured output validation, and unavailable fallbacks.
- Theme validation, settings migrations, SwiftData pruning, draft ownership, and statistics counters.
- Media mapping and temporary-file cleanup.

### Integration tests

- A fixture URL protocol drives the live request builder without contacting Reddit.
- Keychain tests use a dedicated access group and prove separate accounts cannot read each other's selected secret.
- A fake login cookie store covers success, cancellation, multiple Reddit domains, invalid identity, and reauthentication.
- SwiftData migration tests open stores produced by every released schema version.
- Foundation Models integration is tested on supported hardware for availability, response shape, cancellation, context overflow, safety refusal, and sequential session use. CI uses a deterministic fake service.
- AVFoundation fixtures cover images, silent videos, separate Reddit audio/video, failed ranges, cancellation, and export.

### UI tests

1. Launch logged out, browse Popular, open a post, expand comments, open media, and search.
2. Add two fixture accounts, switch between them, and verify identity, inbox, vote, and draft isolation.
3. Browse full and compact feeds, change sort, refresh, paginate, filter, and restore scroll position.
4. Vote, save, subscribe, comment, edit, delete with confirmation, compose a post, and recover a draft.
5. Use every swipe through its default and configured mapping, then perform the equivalent accessible/context action.
6. Open Inbox, mark an item read, reply, mark all read, and confirm badge state.
7. Browse gallery, page between posts and gallery assets, zoom an image, use Live Text, play and export video.
8. Generate post/comment summaries on supported hardware and exercise the unavailable state on a fake unsupported device.
9. Exercise every settings group, import/export a theme, clear each data category, and verify credentials survive cache clearing.
10. Open deep links and share-extension URLs from terminated, background, and foreground states.

### Accessibility and visual tests

- VoiceOver traversal and actions on all primary screens.
- Dynamic Type through the largest size, Bold Text, Button Shapes, Reduce Motion, Differentiate Without Color, Increase Contrast, and right-to-left layout.
- Light, dark, pure-black, and each built-in theme snapshots on small iPhone, large iPhone, and iPad split view.
- Long titles, long usernames, missing thumbnails, hidden scores, localized numbers/dates, and keyboard interaction.

### Security tests

- Search built products, logs, preferences, databases, and diagnostics for fixture cookie and modhash canaries.
- Verify credentials are never sent to media, upload, short-link, or external hosts across redirects.
- Fuzz HTML sanitization, route parsing, imported JSON, and Reddit listing decoding.
- Confirm nonpersistent login data disappears after every completion path.
- Confirm account switching during active reads and writes cannot cross credentials or UI updates.

## Delivery phases

### Phase 0 - foundations

- Project targets, strict concurrency, dependency container, domain models, fixture transport, theme tokens, SwiftData schema, Keychain vault, and typed routing.
- CI builds and tests iPhone and iPad targets. Warnings are treated as errors for Octonaut code.

### Phase 1 - read-only client

- Logged-out Posts, communities, feeds, post detail, comments, search, users, links, images, video, gallery, caching, themes, and core settings.
- This phase is shippable to internal testers without authentication.

### Phase 2 - accounts and participation

- Isolated web login, multiple accounts, personalized feeds, votes, saves, subscriptions, inbox, messages, composers, drafts, uploads, editing, deletion, multireddits, and account pages.

### Phase 3 - local power features

- Seen history, all filters, local statistics, on-device summaries, semantic filtering, local documentation search/answers, share-as-image, Live Text, richer media export, and share extension.

### Phase 4 - hardening and release

- Accessibility pass, performance profiles, migration tests, security tests, privacy manifest, App Store privacy copy, legal naming review, unsupported-route fallbacks, and beta feedback fixes.

### Later companion service

- Specify, threat-model, implement, and independently deploy the opt-in notification server in `SERVER-FUTURE-*`. It is not a condition for the native app's first release.

## Release-one acceptance checklist

Release one is acceptable when:

- All `must` requirements in these documents are implemented or a written spec revision removes them.
- The five tabs and all primary routes work on iPhone and iPad.
- Logged-out browsing and at least two isolated signed-in accounts pass the UI flows.
- Core actions, comments, composers, inbox, media, filters, themes, drafts, and local data controls pass their tests.
- Apple on-device summaries work on a supported device, and every unavailable state degrades as specified.
- A captured fixture credential does not appear outside Keychain or on a non-Reddit request.
- No RevenueCat, Hydra server dependency, hosted AI call, analytics SDK, or push-notification permission is present.
- VoiceOver and accessibility text sizes can complete reading, voting, replying, account switching, and settings flows.
- Performance budgets are measured and serious regressions are fixed or documented with a scoped follow-up.
- App Store disclosures accurately describe web-session authentication and direct communication with Reddit.

## Known product risks

- Reddit web-session access is unofficial and may stop working or conflict with policy. The OAuth boundary and logged-out mode limit the impact but do not remove it.
- Reddit JSON and legacy mutation routes are loosely documented and can change. Fixture coverage and tolerant decoding are required.
- Apple Intelligence availability depends on device, user settings, language, region, and downloaded model state. Local AI cannot be assumed from OS version alone.
- Media hosts and Reddit DASH formats vary. Every failure needs an Open Original fallback.
- iOS may suspend background refresh for long periods. Release one cannot promise timely inbox alerts.
- Third-party-inspired theme names and alternate icons need a final trademark and asset review before distribution.
