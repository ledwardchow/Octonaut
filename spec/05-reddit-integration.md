# Reddit integration

## Status and transport boundary

The initial transport reproduces the web-session behavior used by Hydra. It is not Reddit's official OAuth API. Reddit may change cookie names, endpoints, anti-bot checks, response shapes, or permitted use. Keep the implementation behind `RedditClient` so an approved OAuth transport can replace it without changing feature code.

`REDDIT-001` No Reddit API key is embedded or requested for the web-session transport. Logged-out reads use Reddit's public JSON pages. Signed-in requests use the user's Reddit web session cookie and modhash.

`REDDIT-002` The app must present a plain disclosure before first login: Leddit signs into Reddit's website, stores the resulting session securely on this device, and uses it to make Reddit requests. Include a link to Reddit's terms and privacy policy.

`REDDIT-003` Endpoint paths and request shapes in this document are integration targets, not domain API. Centralize them in one route builder and cover them with fixtures.

## Web-session authentication

### Login sequence

1. Create a new `WKWebViewConfiguration` with `WKWebsiteDataStore.nonPersistent()` for this login attempt. Do not reuse the browsing or another account's data store.
2. Navigate to Reddit's HTTPS login page. Allow Reddit-owned redirects needed for login. Open unrelated external domains using the configured browser.
3. Observe navigation completion and the web view's `WKHTTPCookieStore`. Do not inject scripts to read passwords or form fields.
4. Find the Reddit session cookie, normally `reddit_session`, for a valid Reddit domain. Accept a changed cookie name only after the identity check succeeds and the implementation has an explicit migration.
5. Send `GET https://www.reddit.com/user/me/about.json` with that cookie using the isolated Reddit request pipeline.
6. Decode the username and `modhash`. If either the session or identity is invalid, keep waiting during an active login or show a clear failure after navigation settles.
7. Write the cookie and modhash to a new Keychain item, create or update the account metadata record, destroy the web view and website data store, then select the account.

`REDDIT-AUTH-001` A login attempt has a random nonce and an explicit lifecycle. Results arriving after cancellation are ignored and any uncommitted secret is discarded.

`REDDIT-AUTH-002` The login web view may offer Reddit's own password manager and passkey behavior. Leddit never sees or stores the password.

`REDDIT-AUTH-003` If Reddit requires CAPTCHA, two-factor authentication, email confirmation, or consent, the user completes it inside the Reddit page. Do not automate those steps.

### Credential storage

Store one generic-password Keychain item per local account UUID:

```json
{
  "version": 1,
  "cookieName": "reddit_session",
  "cookieValue": "...",
  "modhash": "...",
  "redditUser": "example",
  "validatedAt": "ISO-8601"
}
```

Use `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`. Disable iCloud Keychain synchronization. Never place the serialized value in `UserDefaults`, SwiftData, logs, crash breadcrumbs, backups, pasteboard, or diagnostic exports.

### Request authentication

`REDDIT-AUTH-010` The active credential is read by account ID for each request and attached explicitly:

- `Cookie: reddit_session=<value>`
- `X-Modhash: <modhash>` for state-changing requests and where Reddit expects it
- A stable, honest `User-Agent` containing Leddit, version, platform, and a project contact URL
- Appropriate `Accept` and form content type

Do not use `HTTPCookieStorage.shared`. Prevent automatic credential forwarding across redirects to a non-Reddit host. The allowed host set is exact and includes only the Reddit hosts needed by a route.

`REDDIT-AUTH-011` A 401, 403 authentication response, login HTML in place of JSON, or failed identity check triggers one credential validation. Do not retry a mutation automatically. If invalid, mark that account Needs Login.

`REDDIT-AUTH-012` Refresh the modhash from `/user/me/about.json` after login, after a modhash rejection, and periodically while active. Updating it is an atomic Keychain replacement.

## URL construction

`REDDIT-URL-001` Build URLs with `URLComponents`. Never concatenate unescaped user input into a URL. Feed and subreddit names are normalized and validated before becoming path components.

`REDDIT-URL-002` Read routes use `.json` where supported and include `raw_json=1`. Listing requests use `limit`, `after`, `before`, `sort`, and `t` only when supported. Comment routes include `sort` and may include `comment`, `context`, or `depth`.

`REDDIT-URL-003` Normalize Reddit links by lowercasing the host, stripping tracking parameters, retaining identifiers and comment context, and converting known mobile/old/new hosts into the canonical internal route. Resolve `redd.it` with a bounded HEAD or GET request and a five-redirect limit.

## Read endpoint matrix

Exact response decoding must be fixture-tested. Common targets are:

| Capability | Request target |
| --- | --- |
| Public or home listing | `GET /[sort].json` or `GET /.json` |
| Popular and All | `GET /r/popular/[sort].json`, `GET /r/all/[sort].json` |
| Community feed | `GET /r/{name}/{sort}.json` |
| Combined feed | `GET /r/{name+name}/{sort}.json` |
| Post and comments | `GET {permalink}.json` |
| More comments | `GET /api/morechildren.json` with `api_type=json`, link fullname, child IDs, sort |
| Global post search | `GET /search/.json` |
| Community post search | `GET /r/{name}/search/.json` with `restrict_sr=on` |
| Community discovery | `GET /subreddits/search.json`, trending endpoints when available |
| Community about | `GET /r/{name}/about.json` |
| Rules | `GET /r/{name}/about/rules.json` |
| Wiki | `GET /r/{name}/wiki/{page}.json` |
| User identity | `GET /user/me/about.json` |
| User profile | `GET /user/{name}/about.json` |
| User activity | `GET /user/{name}/{section}.json` |
| My subscriptions | `GET /subreddits/mine/subscriber.json` |
| My moderated communities | `GET /subreddits/mine/moderator.json` |
| My multireddits | `GET /api/multi/mine` |
| One multireddit | `GET /api/multi/user/{owner}/m/{name}` and its listing route |
| Inbox | `GET /message/{section}.json` |
| Preferences needed by UI | Reddit preference JSON or current-user fields, when stable |

`REDDIT-READ-001` User sections include Overview, Submitted, Comments, Saved, Upvoted, Downvoted, and Hidden. Reddit may restrict some sections to the active user.

`REDDIT-READ-002` Detect JSON error objects and HTML error pages before model decoding. Preserve status code, Reddit error code, retry time, and a sanitized message.

## Mutation endpoint matrix

Mutations normally use `POST` with `application/x-www-form-urlencoded; charset=UTF-8`, cookie, modhash, and `api_type=json` where applicable.

| Capability | Target and important fields |
| --- | --- |
| Vote or clear vote | `/api/vote`: `id`, `dir` where 1, -1, or 0 |
| Save or unsave | `/api/save`, `/api/unsave`: `id` |
| Hide or unhide | `/api/hide`, `/api/unhide`: `id` |
| Subscribe or unsubscribe | `/api/subscribe`: `action`, `sr_name` |
| Comment or reply | `/api/comment`: `thing_id`, `text`, `api_type=json` |
| Edit text | `/api/editusertext`: `thing_id`, `text`, `api_type=json` |
| Delete | `/api/del`: `id` |
| Submit post | `/api/submit`: `sr`, `kind`, `title`, `text` or `url`, `sendreplies`, flair fields |
| Mark read or unread | `/api/read_message`, `/api/unread_message`: `id` |
| Mark inbox read | `/api/read_all_messages` |
| Compose message | `/api/compose`: `to`, `subject`, `text`, `api_type=json` |
| Block account | `/api/block_user`: relevant fullname or username fields |
| Follow account | Reddit friend or subscribe endpoint confirmed by fixtures |
| Multireddit create/update | `/api/multi/...` JSON body as required by Reddit |
| Multireddit delete | `DELETE /api/multi/user/{owner}/m/{name}` |
| Add/remove multi community | `/api/multi/.../r/{community}` |

`REDDIT-WRITE-001` Parse `json.errors` even when HTTP status is 200. Map field errors to the composer. Unknown errors show a general message and retain the draft.

`REDDIT-WRITE-002` Never automatically replay submit, comment, message, edit, delete, or multireddit mutation after a timeout. Offer Retry and explain that the first request may have succeeded. Refresh the target before retrying when duplication is possible.

`REDDIT-WRITE-003` Poll voting may route to Reddit's webpage until a stable, tested endpoint is available. The app still displays poll choices, current result visibility, and total votes from listing data.

## Image upload

Reddit uploads commonly use an API request to obtain S3 fields followed by a multipart upload to the returned HTTPS endpoint. Treat this as unstable.

`REDDIT-UPLOAD-001` Resize or transcode only when needed, remove location metadata by default, request the upload lease, validate the destination host against returned and expected values, and send exactly the declared multipart fields plus the file.

`REDDIT-UPLOAD-002` Accept the resulting media URL only after a successful upload response. Enforce a configurable size ceiling based on known Reddit limits and show the limit before upload.

## Mapping Reddit data

`REDDIT-MAP-001` Reddit listings wrap objects as `Listing` and `Thing`. Dispatch by `kind` and preserve unknown kinds as unsupported rows with their permalink when possible.

`REDDIT-MAP-002` Prefer Reddit's rich-text fields when complete, otherwise sanitize HTML, otherwise use plain text. Decode HTML entities once. Never execute embedded markup.

`REDDIT-MAP-003` Image selection prefers a preview resolution close to display pixels, accounting for scale. Decode escaped ampersands in preview URLs. Respect NSFW/spoiler flags before starting a full-resolution fetch.

`REDDIT-MAP-004` Media precedence is gallery data, Reddit video, preview video/GIF, direct image, secure media embed, then link metadata. A crosspost retains both wrapper and source identities.

`REDDIT-MAP-005` Comment decoding distinguishes real comments from `more` nodes. Preserve child IDs and parent IDs. Deleted or removed bodies become explicit placeholder states.

`REDDIT-MAP-006` Scores may be hidden. Represent hidden score as unknown, never as zero. Dates are parsed from UTC epoch seconds. Optional author values cover deleted accounts.

## Rate limiting and errors

`REDDIT-ERROR-001` Map offline, timeout, TLS, rate limit, access denied, authentication expired, quarantined, private, banned, not found, invalid input, and malformed response separately.

`REDDIT-ERROR-002` Honor `Retry-After` and any Reddit rate-limit fields. Read requests may retry twice using bounded exponential backoff with jitter. Do not retry 4xx errors except 429 at its allowed time.

`REDDIT-ERROR-003` Concurrency is bounded by host and work type. Favor visible reads and user actions over prefetch, metadata, and AI preparation. Cancel prefetch under memory pressure or Low Power Mode.

`REDDIT-ERROR-004` When Reddit returns an unexpected schema, save only a redacted structural diagnostic if the user has enabled diagnostics. Never persist the raw body of authenticated responses for general logging.

## OAuth migration

`REDDIT-OAUTH-001` Domain actions, DTO mapping, cache, and feature stores must not depend on cookies. A future `OAuthRedditTransport` can implement the same contracts with bearer tokens and OAuth hosts.

`REDDIT-OAUTH-002` Account records include a transport kind and credential lookup key. A migration may add an OAuth credential as a new session, validate it, then retire the cookie only after successful feature checks.

`REDDIT-OAUTH-003` If Reddit policy or App Review prevents release of web-session access, logged-out reading remains functional while authenticated actions are disabled until the OAuth transport is ready.
