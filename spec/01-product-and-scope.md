# Product and scope

## Product intent

Octonaut is a fast, configurable Reddit reader and client built specifically for Apple platforms. It supports logged-out browsing, multiple Reddit accounts, dense or media-rich feeds, threaded comments, search, posting, messaging, media viewing and export, local filters, local usage statistics, and on-device summaries.

The product should feel native on iPhone, iPad, and Mac rather than like a webpage wrapper. Reddit login may use an embedded Reddit webpage because the authentication method relies on a Reddit web session. All browsing and interaction screens remain native.

## Product principles

1. **Reading comes first.** Feed and comment scrolling must remain smooth with media-heavy content and deep threads.
2. **Local by default.** Preferences, drafts, history, statistics, filters, summaries, and documentation search should stay on device.
3. **Power without clutter.** Common actions remain visible. Less common actions live in context menus, toolbar menus, and configurable swipes.
4. **No account required.** Public content works immediately in logged-out mode.
5. **Multiple accounts are first-class.** Switching accounts must be fast and must never mix sessions or personalized data.
6. **Graceful degradation.** Unsupported media, unavailable local AI, expired sessions, private communities, and rate limits must produce useful fallback UI.
7. **Replaceable integrations.** Reddit authentication, AI execution, link metadata, and any future server use protocols with live and test implementations.

## Release-one scope

### Included

- Five-tab application shell: Posts, Inbox, Account, Search, Settings.
- Logged-out public Reddit browsing.
- Web-session Reddit login and secure multi-account storage.
- Home, popular, all, subreddit, combined subreddit, and multireddit feeds.
- Best, Hot, New, Top, Rising, and Controversial sorting where Reddit supports them.
- Full and compact post rows.
- Text, link, image, gallery, video, GIF, poll display, and crosspost display.
- Post detail and threaded comments, including load-more nodes and collapse state.
- Voting, saving, subscribing, posting, commenting, editing, deleting, messaging, blocking, and following where supported by the active Reddit session.
- Subreddit favorites and multireddit management.
- Search across posts, subreddits, and users, plus subreddit-scoped search.
- Inbox and private-message conversations while the app is active.
- Native image and video viewers, download, share, Live Text, and Reddit video audio merging.
- Gallery mode.
- Seen-post tracking, subreddit filters, keyword filters, and on-device semantic filters.
- On-device post and comment summaries.
- Local searchable help and optional on-device documentation answers.
- Local drafts and local usage statistics.
- Themes, custom themes, alternate icons, data-use controls, gestures, sorting, link handling, and privacy controls.
- iPad feed-detail split view.
- Mac sidebar, feed, and detail interface with native menus, keyboard shortcuts, and Settings window.
- Deep links, Universal Links where entitlement/domain setup allows them, custom `octonaut://` links, share extension, and clipboard link detection when enabled.

### Explicitly deferred

- Remote push notifications.
- Reliable inbox polling while the app is terminated.
- Uploading Reddit session cookies to a server.
- Cross-device settings, draft, seen-history, or account sync.
- A hosted AI fallback paid by the app developer.
- RevenueCat, subscriptions, trials, customer registration, and entitlement checks.
- The Hydra server task dashboard, SQL console, proxy pool, Discord alerts, and server cost accounting.
- Moderator-specific tooling beyond what naturally appears in Reddit data.
- Account creation inside the app.

### Optional after release one

- Approved Reddit OAuth transport.
- A companion notification service using an explicit opt-in and revocable device credential.
- iCloud sync for non-sensitive preferences and custom themes.
- Widgets and App Intents for opening favorite communities.

## Personas and primary jobs

### Logged-out reader

Wants to open the app and browse public communities, posts, comments, search, links, and media without setup.

### Signed-in participant

Wants to see a personalized home feed, vote, save, subscribe, comment, post, send messages, and manage their Reddit identity.

### Multi-account user

Wants to keep several Reddit sessions and switch without entering credentials again. Every screen must immediately reflect the selected account.

### Dense-feed reader

Wants compact rows, remembered sorts, aggressive filtering, seen-post handling, and gestures that minimize taps.

### Media browser

Wants inline playback, gallery browsing, full-screen vertical and horizontal paging, zoom, Live Text, downloading, and sharing.

### Privacy-conscious user

Wants all app-added intelligence and statistics to work locally and wants a clear record of any data that could leave the device.

## Success measures

- Cold launch reaches usable logged-out content without an account prompt.
- A warm feed shows cached rows immediately and refreshes without losing scroll position.
- Feed scrolling stays responsive with mixed images and auto-playing video.
- Account switching cannot send a request with the previous account's cookie.
- Draft text survives termination.
- Local AI unavailability never blocks ordinary reading.
- All destructive actions require clear confirmation and update local state only after Reddit acknowledges them.
- VoiceOver users can identify content, vote state, media count, comment depth, collapsed state, and every action.
