# Octonaut agent instructions

## Non-negotiable product invariant: no Reddit Data API registration

Octonaut must not use Reddit's OAuth Data API or require a Reddit developer application, client ID, or client secret. Treat avoiding Reddit developer registration as an architectural and product requirement.

This restriction is specifically about the registered-application Data API. It is not a general prohibition on programmatic Reddit integration.

Forbidden integration includes:

- Requests to `oauth.reddit.com`.
- OAuth authorization flows for a registered Reddit developer application.
- Reddit developer client IDs, client secrets, installed-app credentials, or bearer tokens.
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

The fact that an endpoint is undocumented, used by Reddit's website, or returns structured data does not make it prohibited. The deciding question is whether the implementation requires Reddit developer registration or OAuth Data API credentials.

## Authentication and credential handling

Website authentication is permitted, but it must be handled safely:

- Authentication must begin in a user-visible Reddit webpage. Do not collect the user's Reddit password in a native Octonaut form.
- Store Reddit session secrets in Keychain, never in UserDefaults, fixtures, logs, analytics, crash reports, source control, or plaintext files.
- Send session cookies and modhashes only to validated HTTPS Reddit hosts.
- Do not forward Reddit session credentials through an Octonaut-operated server or unrelated third party.
- Redact cookies, modhashes, authorization values, and sensitive response data from diagnostics.
- Keep authenticated and anonymous request paths explicit so credentials are not attached unnecessarily.

## Required workflow for Reddit-related changes

Before implementing or approving a Reddit-related feature:

1. Determine whether the proposed transport requires Reddit developer registration, OAuth application credentials, or `oauth.reddit.com`.
2. If it does, redesign it to use a no-registration Reddit website endpoint or a user-visible webpage handoff.
3. If no no-registration approach can satisfy the feature, stop and explain the conflict. Do not add or request developer credentials.
4. Validate every Reddit destination as HTTPS and restrict credential-bearing requests to intended Reddit hosts.
5. Search the proposed diff for Data API regressions, including `oauth.reddit.com`, OAuth client IDs or secrets, bearer tokens, and instructions asking users to register an application.
6. Add deterministic tests for request construction, response decoding, authentication boundaries, and browser destination URLs where practical.
7. Tests must use fixtures, mocks, or synthetic responses and must never contact Reddit.

## Existing code and specifications

Existing Reddit website JSON routes, `/api/*` requests, cookie/modhash handling, and specifications describing those transports are allowed when they satisfy this policy. Their use does not require replacement with browser-only handoff.

When touching Reddit integration code, preserve the no-registration architecture and improve credential safety where the task permits. When editing specifications or README content, describe the distinction accurately: Octonaut may integrate with Reddit programmatically, but it must not depend on Reddit developer registration or the OAuth Data API.

These instructions take precedence over repository documentation that proposes OAuth Data API access, Reddit developer application credentials, or user-supplied client IDs and secrets.
