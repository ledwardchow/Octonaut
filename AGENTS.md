# Octonaut agent instructions

## Git commit signing

If a signed commit fails, or signing is unavailable or stalls, automatically retry unsigned without asking for confirmation. Use `git -c commit.gpgsign=false commit` for that attempt. Do not change global or repository signing settings.

Stop a stalled signing attempt and check that it did not create a commit before retrying.

## TestFlight change notes

For every user-visible feature or bug fix, update `TestFlight/WhatToTest.en-AU.txt` in the same task, without waiting for a reminder.

- Write one very short line per change, ideally under 10 words.
- Describe only what changed, using plain English. Example: `Fixed missing audio in videos.`
- Do not add headings, explanations, testing instructions, or implementation details.
- Add to the current build's changes. Combine duplicate entries and update entries when the same feature changes again.
- Only list changes implemented in the task. Skip documentation, tests, and internal refactors that do not change app behaviour.
- Preserve existing notes unless asked to start a new build or rewrite them.

## Non-negotiable product invariant: no Reddit Data API registration

Octonaut must not use Reddit's OAuth Data API or require a Reddit developer application, client ID, or client secret. Treat avoiding Reddit developer registration as an architectural and product requirement.

This restriction is specifically about the registered-application Data API. It is not a general prohibition on programmatic Reddit integration.

Forbidden integration includes:

- Requests to `oauth.reddit.com`.
- OAuth authorization flows for a registered Reddit developer application.
- Reddit developer client IDs, client secrets, installed-app credentials, or OAuth Data API bearer tokens.
- SDKs or libraries that require Reddit developer application credentials.
- A bundled or remote proxy whose purpose is to hide, share, or supply Reddit developer credentials on the app's behalf.
- Asking users to create their own Reddit developer application or enter developer credentials.

## Permitted Reddit integration

Octonaut may use Reddit integrations that work without Reddit developer registration, including:

- Public Reddit website endpoints and `.json` routes.
- Structured JSON endpoints served from ordinary Reddit website hosts.
- Reddit `/api/*` endpoints that do not require a registered developer application.
- Authenticated website requests using a Reddit session cookie and modhash obtained through a user-visible Reddit login.
- Anonymous requests that require no Reddit credentials.
- Normal Reddit webpages opened in the system browser or a user-visible browser/WebView.
- Local fixtures and synthetic test data.

### Exception for broken website requests

Only when the user explicitly says the current implementation no longer works, Octonaut may replace the affected website requests with Reddit's own persisted GraphQL queries. This permission applies only to the features the user reported as broken. Do not migrate other features on that basis.

These requests may use a temporary website `token_v2` as a Bearer token, obtained from the user's existing Reddit website session. They must not require developer registration, application credentials, or `oauth.reddit.com`. Anonymous GraphQL access is not assumed.

The user reported r/all and search as broken and authorized this exception on 29 October 2026. GraphQL is permitted for those features.

On 30 October 2026, the user also approved the planned migration of supported signed-in reads for Home, Popular, individual communities, existing server multireddits, discovery, post detail, comment expansion, profiles, user lists and subscriptions. This is explicit permission for that read migration. It does not mean those features were reported as broken. Keep anonymous website reads and local combined feeds on their existing routes. Keep inbox, private messages, unread controls and counts, blocked-user enumeration, full report options and website writes on their existing routes until equivalent behavior has separate approval.

Outside these explicitly approved scopes, any further GraphQL feature needs a separate explicit report that its current implementation no longer works. Do not use the read migration as permission to migrate actions or change Reddit account preferences.

The fact that an endpoint is undocumented, used by Reddit's website, or returns structured data does not make it prohibited. It must work without Reddit developer registration or OAuth Data API credentials. GraphQL replacements must also meet an explicit permission above.

## Authentication and credential handling

Website authentication is permitted, but it must be handled safely:

- Authentication must begin in a user-visible Reddit webpage. Do not collect the user's Reddit password in a native Octonaut form.
- Store Reddit session secrets in Keychain, never in UserDefaults, fixtures, logs, analytics, crash reports, source control, or plaintext files.
- Send session cookies and modhashes only to validated HTTPS Reddit hosts.
- For the GraphQL exception, send website Bearer tokens only to `https://cf.gql-fed.reddit.com/`. Obtain them only through `https://www.reddit.com/` and `https://www.reddit.com/svc/shreddit/graphql`. Do not send session cookies to the GraphQL host. Reject redirects from these credential-bearing requests.
- Do not forward Reddit session credentials through an Octonaut-operated server or unrelated third party.
- Redact cookies, modhashes, authorization values, and sensitive response data from diagnostics.
- Keep authenticated and anonymous request paths explicit so credentials are not attached unnecessarily.

## Required workflow for Reddit-related changes

Before implementing or approving a Reddit-related feature:

1. Determine whether the proposed transport requires Reddit developer registration, OAuth application credentials, or `oauth.reddit.com`.
2. If it does, redesign it to use a no-registration Reddit website endpoint or a user-visible webpage handoff.
3. If no no-registration approach can satisfy the feature, stop and explain the conflict. Do not add or request developer credentials.
4. Validate every Reddit destination as HTTPS and restrict credential-bearing requests to intended Reddit hosts.
5. Search the proposed diff for Data API regressions, including `oauth.reddit.com`, OAuth client IDs or secrets, and instructions asking users to register an application. Permit website Bearer tokens only within the explicitly approved scopes above.
6. Add deterministic tests for request construction, response decoding, authentication boundaries, and browser destination URLs where practical.
7. Tests must use fixtures, mocks, or synthetic responses and must never contact Reddit.

## Existing code and specifications

Existing Reddit website JSON routes, `/api/*` requests, cookie/modhash handling, and specifications describing those transports are allowed when they satisfy this policy. Their use does not require replacement with browser-only handoff.

When touching Reddit integration code, preserve the no-registration architecture and improve credential safety where the task permits. When editing specifications or README content, describe the distinction accurately: Octonaut may integrate with Reddit programmatically, but it must not depend on Reddit developer registration or the OAuth Data API.

These instructions take precedence over repository documentation that proposes OAuth Data API access, Reddit developer application credentials, or user-supplied client IDs and secrets.
