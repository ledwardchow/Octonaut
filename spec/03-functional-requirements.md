# Functional requirements

This document defines behavior shared by the screens in [Information architecture and UI](02-information-architecture-and-ui.md). UI state must be driven by these rules rather than duplicated in individual views.

## Accounts and sessions

`FUN-AUTH-001` Public feeds, posts, comments, communities, users, search, wiki pages, links, and media must work without an account. An action that needs authentication presents the account picker. It resumes the action after a successful login when safe to do so.

`FUN-AUTH-002` Add Account presents Reddit's login page in an isolated web view. Success requires both a Reddit session cookie and a successful identity request. Cancelling or failing login must not alter existing sessions.

`FUN-AUTH-003` Leddit supports any number of saved accounts. Each account has a username, optional avatar, session secret, modhash, last validation time, and health state. The session secret is kept in Keychain. Other metadata may be kept in SwiftData.

`FUN-AUTH-004` Switching accounts is atomic. Cancel work owned by the old account, select the new credential, clear account-bound in-memory caches, fetch the new identity, and refresh visible personalized screens. A request created before the switch must either finish against the old account without affecting the new UI, or be cancelled. It must never inherit the new or old account's credential by accident.

`FUN-AUTH-005` A rejected or expired session changes that account to Needs Login. Public browsing continues. The app offers Sign In Again and Remove Account. Reauthentication replaces only the selected account's secret.

`FUN-AUTH-006` Removing an account requires confirmation. It removes its Keychain item and account-scoped cached data. It does not delete Reddit content or affect other accounts. Removing the active account selects another saved account, or logged-out mode if none remains.

## Listings and refresh

`FUN-LIST-001` Every Reddit listing is represented by a descriptor, items, `after` cursor, refresh date, and load state. First load, refresh, and next-page load are separate states. A next-page failure leaves existing rows visible and provides an inline Retry row.

`FUN-LIST-002` Pagination must ignore duplicate fullnames while preserving the order returned by Reddit. Only one next-page task may run per listing. Stop when `after` is absent or repeats.

`FUN-LIST-003` Pull-to-refresh requests page one, applies filtering, replaces matching items, and keeps the user's visible anchor where practical. A manual refresh always contacts Reddit. A warm screen may show cached rows immediately.

`FUN-LIST-004` Post filters run before rows are published. The order is blocked or invalid content, filtered communities, keyword rules, semantic rules, and hide-seen. The app records how many items each rule removed. If a page becomes empty after filtering, fetch up to two more pages automatically. After that, show a clear end state instead of an endless spinner.

`FUN-LIST-005` A post becomes seen when its detail is opened. If Auto-mark while scrolling is enabled, it also becomes seen after at least 60 percent of the row has remained visible for 750 milliseconds. Seen state is reversible.

`FUN-LIST-006` The app stores at most 5,000 seen post IDs. When the limit is exceeded, remove the oldest records. Seen history is local and common to all accounts unless a future migration explicitly makes it account-specific.

## Sorting

`FUN-SORT-001` Supported post sorts are Best, Hot, New, Top, Rising, and Controversial, limited to the current Reddit route. Top and Controversial accept hour, day, week, month, year, or all where Reddit supports them.

`FUN-SORT-002` Comment sorts are Best, New, Top, Controversial, Old, and Q&A. Multireddit sorts are Hot, New, Top, Rising, and Controversial.

`FUN-SORT-003` A feed uses, in order: its explicit remembered choice, the configured default for that feed kind, then Reddit's normal default. Remembered values are stored by normalized feed identity and account when Remember per feed is enabled.

## Post and comment actions

`FUN-ACTION-001` Voting is optimistic. Update the visible vote and score immediately, send the request, then keep the server result or roll back with a non-blocking error. Tapping the current vote again clears it.

`FUN-ACTION-002` Save, unsave, subscribe, unsubscribe, follow, unfollow, block, unblock, hide, unhide, and inbox read state follow the same optimistic rule when rollback is unambiguous. Delete is never optimistic.

`FUN-ACTION-003` Editing and deleting are shown only for content owned by the active account. Deleting requires confirmation, waits for Reddit success, then replaces the item with a deleted state or removes it as appropriate.

`FUN-ACTION-004` Report may open Reddit's native webpage until a stable transport is implemented. The menu must describe this before leaving the app.

`FUN-ACTION-005` Share Link provides the canonical public Reddit permalink. Share as Image renders the post or comment in the active theme, includes its community and attribution, excludes account-only controls, and applies no Leddit watermark.

## Communities and multireddits

`FUN-COMMUNITY-001` A community exposes its feed, About data, rules, wiki index and pages, subscription state, favorite state, quarantine status, and moderators when returned by Reddit.

`FUN-COMMUNITY-002` Favorites are local, work while logged out, and are manually ordered. Subscriptions and multireddits are Reddit account data. If the same community is both subscribed and favorited, it appears in both appropriate sections.

`FUN-COMMUNITY-003` Combined communities such as `r/swift+ios` are valid feed descriptors. Normalize names, remove duplicates, and preserve the user-visible order.

`FUN-COMMUNITY-004` Multireddit management supports listing owned multireddits, opening one, adding or removing communities, creating, renaming where supported, and deleting with confirmation. Refresh the affected feed and root list after mutation.

`FUN-COMMUNITY-005` Private, banned, quarantined, and gated communities have distinct messages. A quarantined community may present a Continue action using the Reddit confirmation route. Never represent an access denial as an empty feed.

## Search

`FUN-SEARCH-001` Global search has Posts, Communities, and Users scopes. Post search paginates. Community search paginates if the response supports it. User search may stop after one page if Reddit does not return a reliable cursor.

`FUN-SEARCH-002` Empty global search shows suggested or trending communities when obtainable without private data. Search starts after submission or a 350 millisecond debounce once the query contains two non-space characters. Cancel stale queries.

`FUN-SEARCH-003` Community search limits post results to that community and makes the scope visible. Recent queries are local, capped at 30, individually removable, and clearable. Private browsing is not inferred and searches are not sent to Leddit servers.

## Comments

`FUN-COMMENT-001` Decode comments into a stable tree while preserving Reddit order, depth, parent fullname, score, author, flair, distinguished state, vote, saved state, body, and child count.

`FUN-COMMENT-002` Collapse state is view-local and keyed by comment ID. Start Collapsed applies on first presentation. Auto-collapse AutoModerator applies independently. Collapse Children Only hides descendants while retaining the selected comment. Collapse Thread hides the selected comment and descendants except for a one-row expansion marker.

`FUN-COMMENT-003` A `more` item is a real tree node. Selecting it requests its child IDs, inserts returned comments at the same position, preserves their parent relationships, and retains a Retry node on failure. Large ID sets may be chunked.

`FUN-COMMENT-004` Next and Previous navigation uses the currently visible flattened tree after collapse and filtering. The default target is a top-level comment. A later setting may allow all comments.

`FUN-COMMENT-005` Comment summary input uses visible comment text, not collapsed presentation state. Deleted, removed, and bot comments may be omitted. Summary generation never changes the tree.

## Composing and drafts

`FUN-COMPOSE-001` Leddit supports new text and link posts, comments, comment and self-post edits, private messages, and message replies. Unsupported Reddit post types may open Reddit's web composer.

`FUN-COMPOSE-002` A composer validates required fields before enabling Send. It displays the target account and community or recipient. Sending disables duplicate submission and remains cancel-safe until the network request begins.

`FUN-COMPOSE-003` The formatting bar inserts link, bold, italic, quote, strikethrough, and spoiler syntax around the selection or at the insertion point. Preview renders the same Markdown subset used in reading. Reply and edit composers can show Parent and Old Version panels.

`FUN-COMPOSE-004` Drafts save locally after a 500 millisecond idle period and whenever the scene backgrounds. A draft key includes composer kind, account, and target. Sending successfully deletes its draft. Discard requires confirmation when text is non-empty.

`FUN-COMPOSE-005` Keep at most 100 drafts, preferring unsent recent drafts. A draft from a different account cannot be sent until the user explicitly switches to that account or copies it into a new draft.

`FUN-COMPOSE-006` Image upload strips location metadata by default, shows byte progress, and allows cancellation. Do not create the final Reddit post until all required uploads succeed.

## Inbox and messages

`FUN-INBOX-001` The inbox supports all, unread, comment replies, post replies, mentions, and private messages when Reddit returns them. The unread tab badge reflects the most recently fetched count.

`FUN-INBOX-002` Opening an unread item marks it read optimistically and routes to the referenced post/comment or message conversation. Mark All Read requires confirmation and updates the badge after Reddit acknowledges the request.

`FUN-INBOX-003` Pull-to-refresh and foreground refresh are supported. Release one does not promise polling while the app is suspended or terminated and does not register for remote notifications.

`FUN-INBOX-004` Message conversations show chronological messages and allow reply. Vote controls appear only on inbox items that represent votable Reddit things.

## Media

`FUN-MEDIA-001` Media normalization produces image, gallery, animated image, direct video, Reddit video, external embed, link preview, poll, or unsupported. Unsupported media shows its domain and an Open Link action.

`FUN-MEDIA-002` Inline autoplay occurs only while a video is sufficiently visible, the app is active, Reduced Motion permits it, and the data mode allows it. Only one inline video plays with sound. Leaving the row pauses it.

`FUN-MEDIA-003` Full-screen images support pinch zoom, double-tap zoom, pan, and swipe-down dismissal when at base zoom. Live Text is available when enabled and supported. Spoiler and NSFW reveal state must carry into the viewer.

`FUN-MEDIA-004` Full-screen video supports play/pause, mute, scrubbing, 10-second skip, playback speeds 0.5x, 1x, 1.5x, and 2x, AirPlay where available, share, and save.

`FUN-MEDIA-005` Reddit DASH video may provide separate audio and video streams. Playback should use an `AVPlayerItem` composition or compatible stream. Export writes a merged temporary file with `AVAssetExportSession`, reports progress, supports cancellation, and removes temporary files after sharing or after 24 hours.

`FUN-MEDIA-006` Gallery mode is a two-column adaptive masonry-like grid. Full-screen gallery paging is vertical between posts and horizontal between media inside a post. Page identity must remain stable when more feed pages load.

## Links and deep links

`FUN-LINK-001` Canonical Reddit links route inside Leddit. The share extension accepts a Reddit URL and opens the matching native route. `leddit://` supports feed, community, post, user, search, and settings routes.

`FUN-LINK-002` External links open in an in-app Safari view by default. Other choices are the system browser or an installed supported browser. Reader Mode is used only when selected and available.

`FUN-LINK-003` Link rewrite rules are declarative host/path/query transforms. They must not execute user-entered JavaScript. Detect rewrite loops and cap transformations at five.

`FUN-LINK-004` Optional clipboard detection reads the pasteboard only after a user gesture or through Apple's paste affordance. It must not poll the pasteboard on launch.

## Local data and statistics

`FUN-LOCAL-001` Leddit records app launches, foreground entries, estimated feed scroll distance, posts viewed, post and comment upvotes/downvotes, posts/comments created, and per-community visits. These counters stay on device and can be reset.

`FUN-LOCAL-002` A visit is counted at most once per community per foreground session. Scroll distance is approximate and must not retain a detailed movement log.

`FUN-LOCAL-003` Cache clearing has separate controls for images/media, Reddit response cache, link previews, summaries, seen history, search history, drafts, and statistics. Clearing credentials is only performed by Remove Account or Remove All Accounts.

`FUN-LOCAL-004` Bundled help remains available offline. Documentation content carries a version so its search index can be rebuilt when the bundle changes.

## Background and lifecycle

`FUN-LIFE-001` On backgrounding, save drafts, persistent navigation state where practical, pending local settings, and last visible feed anchors. Pause playback and cancel nonessential prefetch or AI work.

`FUN-LIFE-002` On foregrounding, validate network reachability, refresh the unread count when signed in, and resume the visible screen according to its staleness policy. Do not force every tab to reload.

`FUN-LIFE-003` A Background App Refresh task may refresh a small amount of inbox or feed data when the system grants time. It is best-effort and must never be described as reliable notification delivery.
