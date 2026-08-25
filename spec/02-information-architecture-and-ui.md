# Information architecture and UI

## App shell

`UI-001` Leddit must use a system `TabView` with five tabs in this order:

1. **Posts**, symbol `rectangle.stack`
2. **Inbox**, symbol `envelope`
3. **Account**, symbol `person.crop.circle`
4. **Search**, symbol `magnifyingglass`
5. **Settings**, symbol `gearshape`

The Inbox tab shows the current unread count as a badge. The Account label shows the active username when “Show username” is enabled, otherwise “Account.” When logged out, its root title is “Accounts.”

`UI-002` Each tab owns an independent `NavigationStack` and route path. Switching tabs preserves the tab's navigation and scroll position. Tapping the active tab while it is nested pops one level. Tapping it at the root scrolls the primary list to the top.

`UI-003` Long-pressing Search presents Quick Community Search. Long-pressing Account presents Quick Account Switcher when at least one session exists. Use item-driven sheets or popovers, not custom full-screen overlays, except when a visual transition requires full-screen presentation.

`UI-004` Use native navigation bars, toolbar menus, context menus, `confirmationDialog`, `ShareLink` or activity sheets, `Form`, and `ContentUnavailableView`. Preserve Hydra's dark, content-dense character through theme tokens rather than recreating Android-like controls.

## Routing

The route model must carry identifiers and URLs, never view instances.

```swift
enum AppRoute: Hashable {
    case feed(FeedDescriptor)
    case post(permalink: URL, focusedCommentID: String?)
    case community(name: String)
    case communitySearch(name: String, query: String)
    case communityInfo(name: String)
    case wiki(name: String, page: String)
    case user(name: String, section: UserSection)
    case multireddit(owner: String, name: String)
    case gallery(FeedDescriptor)
    case conversation(messageID: String)
    case settings(SettingsRoute)
    case accounts
    case web(URL)
}
```

The root URL router recognizes `reddit.com`, `www.reddit.com`, `old.reddit.com`, `new.reddit.com`, `redd.it`, `i.redd.it`, `preview.redd.it`, and `v.redd.it`. It resolves short links before routing. Unknown Reddit paths show an error screen with Open in Browser and Copy Link actions. Non-Reddit URLs use the configured external-link behavior.

## Posts tab

### Communities root

`UI-POST-001` The Posts root is a list containing these sections:

- Feed shortcuts: Home, Popular, All.
- Favorites, in user-defined order.
- Multireddits.
- Subscribed communities, alphabetical.
- Moderated communities, if any.

Logged-out mode shows Home as Reddit's public front page, Popular, All, and discoverable/trending communities. A search field filters local community names. A plus menu offers Add Favorite by Name and, when logged in, Create Multireddit.

Community rows show icon when data mode permits, `r/name`, subscription state, and optional member count. Swipe or context actions allow Favorite/Unfavorite and Subscribe/Unsubscribe. Multireddit rows allow rename where Reddit supports it, add/remove communities, and delete with confirmation.

### Feed screen

`UI-POST-010` A feed screen contains:

- Centered title for Home, Popular, All, `r/community`, user feed, or multireddit.
- Sort control in the trailing toolbar. Top and Controversial expose a time range: hour, day, week, month, year, all.
- Overflow menu with actions appropriate to the feed.
- Optional search field for subreddit-scoped search.
- Refreshable, paginated post list.

Home overflow actions: Gallery Mode, Show/Hide Seen Posts, Share.

Community overflow actions: Gallery Mode, New Post, Subscribe/Unsubscribe, Favorite/Unfavorite, Add to Multireddit, Show/Hide Seen Posts, Community Info, Wiki, Share, and Report in Browser.

Multireddit overflow actions: Gallery Mode and Share, plus edit actions from its management screen.

`UI-POST-011` Loading renders four stable redacted post rows. Empty feeds use `ContentUnavailableView` and explain whether the feed is empty, private, banned, or probably exhausted by filters. Errors provide Retry. Pull-to-refresh replaces the listing from page one. Infinite scroll starts before the last visible row and must coalesce duplicate requests.

### Full post row

`UI-POST-020` The full row uses this vertical order:

1. Optional subreddit identity row with icon, subreddit, author, flair, and moderation/sticky indicators.
2. Title, with configurable maximum lines.
3. Optional self-text preview or external-link description.
4. Inline media or link preview.
5. Metadata row with vote score, comment count, relative time, saved state, and locked/archived state.

Media uses the row width, its known aspect ratio, and a capped height. Gallery media shows a count indicator. Video shows play/mute state and duration when available. Polls show choices and total votes but voting may open the Reddit webpage if no stable endpoint is available. Crossposts render a bordered compact representation of the source post.

Seen posts are visibly dimmed but remain readable. Spoiler and NSFW media use a blur plus a clear label and Reveal button. Reveal state is local to that post presentation.

### Compact post row

`UI-POST-021` Compact mode uses a dense horizontal row. A square thumbnail appears on the configured side. The content column contains title, subreddit and author, then score, comments, and age. Gallery count and video-play badges overlay the thumbnail. Text-only posts use a type symbol placeholder. Separators are one pixel in the divider token.

### Post row interactions

`UI-POST-030` Tapping opens detail. Tapping media may open the viewer directly if the user taps the visible media affordance. Long press opens actions: Upvote, Downvote, Save/Unsave, Mark Seen/Unseen, Filter Community, Share Link, Share as Image, Open External Link, Open in Browser, and author/community navigation. Edit and Delete appear for owned content.

Configurable short and long swipes show the action color and symbol while dragging. Crossing the first threshold selects the short action. Crossing the second selects the long action. Reversing before release cancels. Trigger one selection haptic at each threshold and a completion haptic after success.

## Post detail and comments

`UI-DETAIL-001` The detail screen starts with the expanded post using the same visual language as the feed, followed by optional Post Summary, optional Comments Summary, the comment-sort control, and the comment tree. A bottom action area exposes vote, reply, save, share, and external-link actions without covering content.

Tapping the post content collapses or expands it when enabled. Locked or archived posts disable reply and explain why.

`UI-DETAIL-010` Summary cards have a header, disclosure indicator, loading state, body text, Retry action, and collapse state. When “start collapsed” is enabled, do not generate the summary until expanded. Do not regenerate during the same detail-screen lifetime unless Retry is selected.

`UI-COMMENT-001` A comment row contains:

- A colored depth rail on the leading edge.
- Author, OP/moderator badge, flair, score or hidden-score marker, relative time, edited marker, sticky marker, and current vote state.
- Rendered body supporting paragraphs, links, emphasis, quotes, code, lists, spoilers, and inline supported media.
- A load-more row when Reddit supplies unresolved child IDs.

Depth rails repeat a six-color accessible sequence. Do not indent indefinitely. After a configurable visual depth cap, keep the text column width stable and continue indicating logical depth through the rail color and accessibility value.

Tap collapses the thread when enabled. “Collapse children only” leaves the selected comment visible and replaces descendants with a “N replies” row. AutoModerator starts collapsed when configured. Child collapse states survive collapsing and reopening a parent during the current screen session.

`UI-COMMENT-010` Long press actions: Upvote, Downvote, Reply, Save/Unsave, Share Link, Share as Image, Select Text, Collapse, Collapse Thread, Open Parent, and user navigation. Owned comments also show Edit and Delete.

`UI-COMMENT-020` A floating next-comment button sits at a user-selected snap point. Tap jumps to the next top-level comment. Long press jumps to the previous one. A separate edit-position mode may be entered from its context menu, showing safe-area-aware snap points.

## Gallery mode and media viewer

`UI-GALLERY-001` Gallery mode filters out posts without displayable image or video media and uses a two-column masonry layout. Each tile shows media, title when space permits, video/gallery badge, and NSFW/spoiler treatment. It supports the same sort, seen-filter override, refresh, and pagination as the source feed.

`UI-GALLERY-010` Full-screen gallery uses vertical paging between posts and horizontal paging within a post's media. Axis intent must lock after the initial drag to prevent diagonal page changes. Tap toggles overlay visibility. The overlay shows title, community, author, score, comments, current media position, Open Post, Save, and Share.

`UI-MEDIA-001` The image viewer supports pinch zoom, pan, double-tap between 1x and 2x, horizontal album paging at 1x, swipe-down dismissal at 1x, Live Text, save, and share. It announces “Image X of Y” to VoiceOver.

`UI-MEDIA-010` The video viewer uses `AVPlayer` and provides play/pause, mute, scrubber, elapsed and remaining time, 10-second seek, playback speed choices 0.5x/1x/1.5x/2x, save progress, share, and media paging. Controls appear initially and fade after inactivity while playing. Tap toggles them. Respect silent mode conventions and never auto-play audible audio.

## Inbox tab

`UI-INBOX-001` Logged-out mode shows a sign-in empty state. Logged-in mode shows a refreshable, paginated list of replies and private messages. Unread rows use a tinted background or leading unread marker.

Reply rows show post title, community, author, body preview, score, and time. Message rows show subject, sender, body preview, and time. Tapping marks read, then opens the reply in context or opens its conversation. Toolbar actions include Mark All Read and Compose Message.

Reply swipes support vote and read/unread. Message swipes support read/unread. Context menus expose the same actions.

`UI-INBOX-010` Conversation view is chronological. Current-user messages align trailing with the accent surface. Other messages align leading with the secondary surface. Each bubble includes author and timestamp. A bottom safe-area inset contains Reply and opens a draft-preserving composer.

## Account tab

`UI-ACCOUNT-001` Logged-out root is Account Manager. Logged-in root is the active profile.

Profile header shows avatar, username, account age, post karma, comment karma, friend/follow state, and moderator status when present. A section picker or menu navigates Overview, Submitted, Comments, Saved, Upvoted, Downvoted, and Hidden where the signed-in API allows them. Saved supports Posts and Comments filters.

Other-user actions include Follow/Unfollow, Message, Block, Share, and Gallery Mode when their selected section contains posts. User content rows reuse post and comment components.

`UI-ACCOUNT-010` Account Manager lists Logged Out followed by saved usernames. Tap switches. Add presents Reddit Login. Swipe or context Delete removes the stored session after confirmation. The active account has a checkmark. Switching resets account-sensitive tab roots, cancels old-account requests, clears memory caches that contain private responses, and refreshes subscriptions and inbox.

## Search tab

`UI-SEARCH-001` Search uses native `.searchable` with scopes Posts, Communities, and Users. Input is debounced by 350 milliseconds after submission or may use an explicit Search keyboard action. Empty input shows trending communities. Results reuse post, community, and user rows.

Search supports pagination except user search, which may be one page. It preserves the query when pushing a result. Subreddit feed search uses the Posts scope with `restrict_sr=true`. Search operators are passed through unchanged.

Quick Community Search searches favorites and subscriptions immediately, then may request Reddit results. Selecting a result dismisses the sheet and routes the originating tab to the community.

## Composer screens

`UI-COMPOSE-001` Post, comment, edit, message, and reply composers are sheets with their own `NavigationStack`. They own Cancel and Submit actions. Drafts save after a short debounce and on scene deactivation.

The editor contains a multiline `TextEditor`, formatting toolbar, and Preview. Reply/edit flows add Parent or Old Version as applicable. Formatting actions support link, bold, italic, quote, strikethrough, and spoiler. Selected text is wrapped; otherwise insertion tokens are placed at the cursor.

New Post supports Text, Link, and Image. Fields include community, title, body or URL/media, flair, and send-replies setting. Image upload shows progress. Submission validation must explain missing title, community, URL, media, or unsupported flair.

## Settings tab

Settings use an inset-grouped `Form`. Root sections and exact controls are defined in [Settings reference](07-settings-reference.md). The root includes General, Guide, Theme, Appearance, App Icon, Account, Data Use, Statistics, Privacy, Advanced, and About. There is no subscription screen.

## Visual system

`UI-VIS-001` Use semantic tokens rather than raw colors in feature views:

- primary background, secondary surface, elevated surface, divider
- primary, secondary, and tertiary text
- accent, accent text, primary and secondary icon
- upvote, downvote, destructive, seen/hide, reply, save, share, collapse, moderator
- six comment-depth colors

Default follows the system light/dark appearance. Built-in Hydra-inspired themes may override tokens. System typography and Dynamic Type are required. Use rounded system design only for compact metadata where it improves scanning. Body text must remain at least `.body`; metadata may use `.caption`.

Rows should be visually flat with deliberate separators. Avoid enclosing every post in a rounded card. Primary tap targets are at least 44 by 44 points. Custom themes must be contrast-checked and warn, rather than block, when a pair fails WCAG AA for normal text.

## Adaptive layout

`UI-IPAD-001` On regular-width iPad, the Posts tab may use `NavigationSplitView` with feed in the content column and selected post in detail. Selecting a row changes detail without losing feed position. Other tabs use appropriate wider forms and lists. When split view is disabled, use the same push navigation as iPhone.

Sheets use form sheets on iPad and appropriate detents on iPhone. Context menus remain available with pointer and keyboard. Support standard keyboard commands for Search, Refresh, New Post, Back, and switching tabs.

## Accessibility and motion

`UI-A11Y-001` Every post and comment must expose a concise combined label and separate accessible actions for vote, save, reply, and open. Do not rely on rail or vote color alone. Announce loading completion, filter failures, and destructive success where the visual change is not obvious.

Support Dynamic Type through accessibility sizes without clipping titles or toolbar actions. Respect Reduce Motion, Reduce Transparency, Bold Text, Increased Contrast, and Differentiate Without Color. Replace custom paging motion with cross-fades or no animation when Reduce Motion is enabled.
