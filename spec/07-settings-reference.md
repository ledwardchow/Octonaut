# Settings reference

Every setting has a typed key, the default below, and a short explanation in the UI. Search indexes setting titles and explanations. Settings that cannot currently take effect remain visible only when they help explain an unavailable feature.

## Appearance

| Setting | Type and default | Behavior |
| --- | --- | --- |
| Feed layout | Full / Compact, default Full | Selects the post row defined in `UI-POST-020` or `UI-POST-021`. |
| Compact thumbnail side | Left / Right, default Left | Positions the compact thumbnail. |
| Use split view on iPad | Bool, default On | Uses feed-detail `NavigationSplitView` in regular width. |
| Show community header | Bool, default On | Shows icon/name above community feeds. |
| Show community icons | Bool, default On | Applies unless data mode disables icon fetching. |
| Title maximum lines | Integer 1 to 10, default 2 | `0` may be offered as unlimited. |
| Self-text preview lines | Integer 0 to 20, default 3 | Zero hides self-text preview in feeds. |
| Link-description lines | Integer 0 to 20, default 10 | Zero hides fetched descriptions. |
| Show post flair | Bool, default On | Displays flair when present. |
| Blur spoilers | Bool, default On | Requires an explicit reveal per presentation. |
| Blur NSFW media | Bool, default On | Requires an explicit reveal per presentation. |
| Show post summaries | Bool, default On when local model available, otherwise Off | Enables eligible on-device post summaries. |
| Show comment summaries | Bool, default On when local model available, otherwise Off | Enables eligible on-device thread summaries. |
| Autoplay video | Never / Wi-Fi / Always, default Wi-Fi | Still respects Low Power Mode, Reduced Motion, and data mode. |
| Enable Live Text | Bool, default On | Shows image text selection when supported. |
| Tap comment to collapse | Bool, default On | A tap outside links and controls toggles children. |
| Slide anywhere to scrub | Bool, default On | Horizontal drag in full-screen video scrubs when it does not conflict with system navigation. |
| Show media post info | Bool, default On | Shows title/community overlay in media viewer. |
| Comment vote indicator side | Left / Right, default Left | Positions vote color or symbol in a comment row. |
| Collapse AutoModerator | Bool, default On | Starts matching AutoModerator comments collapsed. |
| Show comment flair | Bool, default On | Displays author flair. |
| Start comments collapsed | Bool, default Off | Starts comment threads collapsed according to collapse mode. |
| Collapse children only | Bool, default Off | Changes tap collapse behavior per `FUN-COMMENT-002`. |
| Show username in Account tab | Bool, default On | Uses active username as tab label when space allows. |
| Hide tab bar while scrolling | Bool, default Off | Uses native tab-bar minimization only where supported. |

## Theme

`SET-THEME-001` Built-in themes are Dark, Light, Midnight, Discord, Spotify, Strawberry, Spiderman, Gilded, Mulberry, Deep Ocean, Aurora, and Royal. All are free. Names derived from another brand should be renamed before public release if trademark review requires it, while preserving their color intent.

| Setting | Default | Behavior |
| --- | --- | --- |
| Theme | System | System follows light/dark appearance. A built-in or custom theme may force or supply both variants. |
| Pure black background | Off | Replaces the darkest background token with black in dark themes. |
| Tint follows community | Off | Allows a restrained community accent on its screen, never for semantic colors. |
| Alternate app icon | Primary | Lists icons actually bundled in the target. |

Custom themes define versioned tokens: background, grouped background, elevated surface, primary text, secondary text, divider, tint, upvote, downvote, saved, moderator, NSFW, spoiler, depth-rail palette, and overlay. Validate WCAG-oriented contrast for text/control combinations and warn before saving a poor pair. A custom theme may have light and dark token sets. Export and import use a versioned JSON document without executable content.

## Gestures

Four actions are configurable separately for posts and comments: short swipe right, long swipe right, short swipe left, and long swipe left.

Default post mapping:

| Gesture | Action |
| --- | --- |
| Short right | Upvote |
| Long right | Downvote |
| Short left | Mark Seen |
| Long left | Save |

Default comment mapping:

| Gesture | Action |
| --- | --- |
| Short right | Upvote |
| Long right | Downvote |
| Short left | Reply |
| Long left | Save |

Post choices are Upvote, Downvote, Mark Seen/Unseen, Save/Unsave, Share, and Disabled. Comment choices add Reply, Collapse, and Collapse Thread. The configuration screen previews direction, threshold, color, symbol, and haptic.

| Setting | Default | Behavior |
| --- | --- | --- |
| Swipe anywhere to go back | Off | When enabled, disables conflicting right-swipe row actions and explains the conflict. |
| Gesture haptics | On | Uses light threshold feedback and success/error feedback for completed actions. |
| Confirm destructive gesture | On | A swipe can reveal Delete but must still confirm it. |

## Filters

| Setting | Default | Behavior |
| --- | --- | --- |
| Hide seen posts | Off | Applies globally unless a feed override exists. |
| Auto-mark seen while scrolling | Off | Uses the visibility rule in `FUN-LIST-005`. |
| Show filter count | On | Shows a small explanation when items were removed. |

Filtered Communities lists normalized community names and expiry. Add choices are One Day, One Week, and Forever. An expired entry is removed automatically. Users can extend, remove, or clear entries.

Keyword Rules support multiple named rules. Each has Enabled, terms entered one per line, Match Whole Words, and fields: title, author, community, self text or link description, and comment body where applicable. Default matching is case-insensitive Unicode-aware text folding. Blank lines are ignored. Whole-word matching uses linguistic boundaries, not ASCII spaces.

Semantic Rules contain a name and natural-language hide instruction. They require the on-device model. Their status is Active, Paused because model unavailable, or Disabled. The list shows the last classification error without including post text.

Feed Overrides allow a normalized community, multireddit, or URL feed to override hide-seen and deterministic rule selection. Unknown URLs cannot become executable rewrite code.

## Data use

Configure Wi-Fi and Cellular separately:

| Mode | Images | Video | Link previews | Community icons |
| --- | --- | --- | --- | --- |
| Normal, default | Full appropriate resolution | Inline preload/autoplay per setting | Image and text | Yes |
| Low Data | Thumbnails, full on tap | No preload, play on tap | Text only | No new fetch |

Additional settings:

| Setting | Default | Behavior |
| --- | --- | --- |
| Respect system Low Data Mode | On | Forces the relevant connection to Low Data while constrained. |
| Respect Low Power Mode | On | Disables autoplay, nonessential prefetch, and automatic AI generation. |
| Image cache limit | 500 MB | Selectable 100 MB, 250 MB, 500 MB, 1 GB. |
| Media export cleanup | 24 hours | Selectable after sharing, 1 hour, 24 hours, or 7 days. |

## Sorting

| Setting | Default | Behavior |
| --- | --- | --- |
| Default post sort | Default | `Default` lets Reddit choose; other valid values follow `FUN-SORT-001`. |
| Default Top time | Day | Used when Top has no remembered time. |
| Default comment sort | Best | Applies to new post detail screens. |
| Remember sort per community | Off | Stores community-specific choice by account. |
| Remember sort per multireddit | Off | Stores multireddit-specific choice by account. |
| Remember comment sort per community | Off | Stores comment sort by account and community. |

## Links and browser

| Setting | Default | Behavior |
| --- | --- | --- |
| Open external links | In-app Safari | Choices are In-app Safari, Default Browser, or a detected supported browser. |
| Prefer Reader Mode | Off | Requests reader presentation where supported. |
| Open Reddit links in Leddit | On | Routes known Reddit URLs natively. |
| Detect copied Reddit links | Off | Uses a user-triggered paste control, never background polling. |

Link Rewrite Rules contain Name, Enabled, Match Host, optional path prefix, result host/path/query transform, and a Test field. They cannot contain JavaScript, regular-expression code execution, custom URL schemes other than HTTPS, or credentials. Provide built-in removable examples only when useful, such as changing a known image host to a direct asset host.

## Startup and tabs

| Setting | Default | Behavior |
| --- | --- | --- |
| Startup tab | Posts | Choices: Posts, Inbox, Account, Search, Settings. |
| Startup Posts destination | Home | Choices: Communities, Home, Popular, All, favorite, or multireddit. |
| Restore last screen | Off | Restores safe routes, not transient composers or credential screens. |
| Refresh visible feed on launch | If stale | Always, If stale after 15 minutes, or Manual. |

The five main tabs are fixed for release one to preserve the specified information architecture. A future version may support reordering after deep-link and restoration tests.

## Accounts

The Accounts screen shows Logged Out plus saved account rows. Actions are Switch, Sign In Again, Remove, and Add Account. It displays last validation state but never a cookie, modhash, or internal Keychain ID.

| Setting | Default | Behavior |
| --- | --- | --- |
| Confirm account switch while composing | On | Prevents accidental draft/account mismatch. |
| Refresh account identity on foreground | If older than 24 hours | Also refreshes immediately after authentication errors. |

Remove All Accounts requires typing or selecting a confirmation. It deletes all Reddit credentials and account-scoped data but leaves device-wide appearance and filters unless separately selected.

## Intelligence

| Setting | Default | Behavior |
| --- | --- | --- |
| Summary provider | OpenAI-compatible | Sends only the content being summarized to the configured endpoint. |
| Endpoint | `https://openrouter.ai/api/v1` | HTTPS OpenAI-compatible base URL. |
| Model | `openai/gpt-5.6-luna` | Model identifier sent in chat completion requests. |
| API key | Empty | Stored in the device Keychain. Summaries remain unavailable until it is saved. |
| Post summaries | On if available | Eligibility and limits are in `AI-SUMMARY-*`. |
| Comment summaries | On if available | Eligibility and limits are in `AI-COMMENT-*`. |
| Automatic visible summaries | On | Generates only for eligible visible content. Off keeps manual Summarize. |
| Key excerpts fallback | On | Shows deterministic excerpts when generation is unavailable. |
| Cache summaries | On | Uses the local 30-day content-hash cache. |
| Local help answers | On if available | Lexical help search remains available when Off. |

This screen shows the selected summary provider status and explains when content leaves the device. It also shows system-model availability for features that remain on device.

## Inbox and notifications

| Setting | Default | Behavior |
| --- | --- | --- |
| Refresh inbox on foreground | On | Fetches unread state when signed in. |
| Background App Refresh | System controlled | Links to Settings and explains it is best-effort. |
| Push notifications | Unavailable | Disabled row: “Requires the future Leddit notification service.” |

Do not ask for notification permission in release one.

## Statistics and privacy

The local Statistics screen displays the counters in `FUN-LOCAL-001`, top visited communities, and a Reset button with confirmation.

| Setting | Default | Behavior |
| --- | --- | --- |
| Collect local usage statistics | On | Counters never leave the device. Turning Off stops new increments. |
| Include account names in diagnostic export | Off | Per-export confirmation can override it. |
| Strip photo location on upload | On | Removes GPS and related location metadata. |
| Send analytics | Off and unavailable | Release one includes no third-party analytics SDK. |
| Send crash reports | Off unless a later provider is specified | Must use a separate consent and data disclosure before implementation. |

Privacy shows a plain data inventory: Reddit session in Keychain, local account metadata, drafts, seen IDs, filters, preferences, statistics, summary output, caches, and any future server enrollment. Each item links to its clear or management action.

## Storage and reset

Storage shows measured size for Reddit response cache, images/media, link previews, summary cache, help index, drafts, and other local records.

Actions:

- Clear Image and Media Cache
- Clear Reddit Cache
- Clear Link Preview Cache
- Clear Summary Cache
- Clear Seen History
- Clear Search History
- Delete All Drafts
- Reset Statistics
- Reset Settings to Defaults
- Delete All Local Content

Every action names what remains. Delete All Local Content requires strong confirmation and removes credentials, records, settings, and caches while leaving the installed app itself. Cache clearing must not sign the user out.

## Help and advanced

Help contains Getting Started, Accounts and Login, Reading, Posting, Gestures, Filters, On-device Intelligence, Privacy, Troubleshooting, and Known Reddit Limitations. It is bundled and searchable offline.

Advanced contains sanitized diagnostic export, current app/build/SDK details, Reddit transport kind, cache details, last redacted errors, feature availability, and Open Source Licenses. It does not include Hydra server URL, Hydra customer ID, RevenueCat entitlement, proxy controls, SQL tools, or arbitrary script execution.
