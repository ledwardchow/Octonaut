# Contributing to Octonaut

Thanks for helping improve Octonaut. Bug reports, fixes and features are all welcome.

## Before you start

- For anything larger than a small fix, open an issue first so we can agree on the approach.
- Follow the [README](README.md) to build the app and run the tests.

## Pull requests

- Target the `develop` branch. Pushes to `main` trigger TestFlight releases.
- Keep each pull request focused on one change.
- Add or update tests for behaviour you change. Tests must use fixtures, mocks or synthetic responses, and must never contact Reddit.
- For user-visible changes, add one short line to `TestFlight/WhatToTest.en-AU.txt`, such as `Fixed missing audio in videos.`

## Contributor License Agreement

Before your first pull request can be merged, you need to sign the [Octonaut Contributor License Agreement](CLA.md). You keep the copyright in your work. The agreement gives the project owner a licence to use and distribute it, including in the App Store build.

When you open a pull request, a bot will ask you to sign by commenting:

```
I have read the CLA Document and I hereby sign the CLA
```

You only need to sign once. If the check doesn't update, comment `recheck`.

## Reddit integration rules

Octonaut must never require a Reddit developer application. Pull requests that touch Reddit code must not:

- call `oauth.reddit.com` or use Reddit's OAuth Data API
- add Reddit client IDs, client secrets or bearer tokens
- ask users to register a Reddit developer application

Public Reddit website endpoints, `.json` routes and website session cookies are fine. Sign-in must happen in a visible Reddit webpage. Never collect a Reddit password in a native form.

Store session secrets only in Keychain, and keep cookies, modhashes and other credentials out of logs, fixtures and source control. See [AGENTS.md](AGENTS.md) for the full policy.

## Licence

Octonaut is licensed under the [GNU Affero General Public License v3.0](LICENSE.txt). Your contributions are also covered by the [CLA](CLA.md).
