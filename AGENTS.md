# Octonaut agent instructions

## Non-negotiable product invariant: no Reddit APIs

Octonaut must not use Reddit APIs. Treat this as an architectural and product requirement, not merely an authentication preference.

For this repository, **Reddit API** means any programmatic request to a Reddit endpoint for structured data or mutations, whether the endpoint is documented, undocumented, public, private, or used by Reddit's own website. The prohibition applies regardless of whether a request uses OAuth, an API/client key, bearer token, anonymous access, a Reddit session cookie, a modhash, or no credential.

Forbidden examples include:

- `oauth.reddit.com` and Reddit Data API access.
- Reddit `/api/*`, GraphQL, internal service, or structured JSON endpoints.
- Reddit `.json` routes, including public listing and permalink JSON routes.
- Forwarding Reddit session cookies or modhashes from native networking code.
- Scraping Reddit pages, extracting their DOM or embedded state, injecting JavaScript to obtain data, or automating website actions.
- Adding a fallback transport that reaches any of the above endpoints.

Allowed integration is limited to user-visible website handoff:

- Open an ordinary HTTPS Reddit webpage in the system browser or a user-visible browser/WebView.
- Let the user read, authenticate, choose settings, and complete actions manually in Reddit's own interface.
- Use documented normal website URLs only as navigation destinations. For example, crossposting may open `https://www.reddit.com/submit?source_id=t3_<post-id>`; Octonaut must not submit the crosspost itself.
- Use local fixtures and synthetic test data that perform no Reddit network access.

## Required workflow for Reddit-related changes

Before implementing or approving a Reddit-related feature:

1. Determine whether it requires Octonaut to fetch, parse, modify, or submit Reddit data programmatically.
2. If it does, do not implement it with a Reddit endpoint. Use a user-visible Reddit webpage handoff when one exists.
3. If no webpage handoff can satisfy the feature, stop and explain that the feature conflicts with the no-Reddit-APIs invariant. Do not invent a private endpoint, scraper, cookie transport, or automated WebView workaround.
4. Search the proposed diff for Reddit API regressions, including `oauth.reddit.com`, `/api/`, `.json`, GraphQL, `X-Modhash`, Reddit cookies in native requests, and automated page parsing.
5. Add tests for browser destination URL construction where practical. Tests must never contact Reddit.

## Existing conflicts are not precedent

The repository currently contains legacy Reddit JSON routes, `/api/*` mutations, cookie/modhash request code, and specifications that describe those transports. They conflict with this invariant and are technical debt; their presence does not authorize new or expanded use.

When a task touches conflicting code, prefer removing or replacing the relevant API behavior with a browser handoff within the task's scope. Do not silently undertake an app-wide rewrite for a narrowly scoped task, but clearly report remaining violations. When editing a conflicting specification or README section, update it to reflect this invariant rather than preserving the old transport design.

These instructions take precedence over repository documentation that proposes Reddit API, public JSON, OAuth, cookie-backed, or modhash-backed transport.
