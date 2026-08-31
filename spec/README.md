# Octonaut implementation specification

This folder is the implementation contract for Octonaut, a fully native SwiftUI Reddit client for iPhone, iPad, and Mac. It describes the product, screens, data, Reddit integration, local intelligence, settings, and quality requirements in enough detail to rebuild the app without referring to the Hydra TypeScript source.

## Document map

1. [Product and scope](01-product-and-scope.md)
2. [Information architecture and UI](02-information-architecture-and-ui.md)
3. [Functional requirements](03-functional-requirements.md)
4. [Architecture and persistence](04-architecture-and-persistence.md)
5. [Reddit integration](05-reddit-integration.md)
6. [Local intelligence and future server](06-local-intelligence-and-future-server.md)
7. [Settings reference](07-settings-reference.md)
8. [Security, quality, and delivery](08-security-quality-and-delivery.md)

## Authority and interpretation

- This specification is authoritative for Octonaut. Hydra is a reference product, not a runtime dependency.
- Requirements using **must** are required for the stated release. **Should** means the implementation may vary if the same user outcome is preserved. **May** means optional.
- Requirement IDs are stable. Tests, issues, and pull requests should cite them.
- When two requirements conflict, security and data-loss prevention take priority, followed by accessibility, functional behavior, and visual matching.
- The app should preserve Hydra's information density and power-user interactions while using standard iOS controls, navigation, typography, accessibility, and presentation behavior.

## Baseline decisions

- Product name: **Octonaut**.
- Platforms: iPhone, iPad, and Mac.
- UI: SwiftUI, with small UIKit/WebKit adapters only where Apple does not expose a SwiftUI equivalent, such as `WKWebView`, Live Text interaction, and advanced media playback.
- Minimum OS: iOS and iPadOS 26.0, and macOS 26.0. Development uses Xcode 27, with newer API use guarded by availability checks.
- Language mode: Swift 6 strict concurrency.
- Monetization: none in the initial implementation. There is no RevenueCat dependency, subscription, entitlement, or paywall.
- Reddit access: a replaceable `RedditClient` supports Hydra-compatible web-session access first. An approved OAuth implementation can be added without changing feature code.
- Server: not required for browsing or local intelligence. Push notifications and reliable off-device inbox polling are deferred to a future companion service.
- Intelligence: Apple's on-device `SystemLanguageModel` is the primary engine for summaries, semantic filters, and help answers. Private Cloud Compute and hosted model APIs are outside release one.
- Privacy: Reddit credentials and sessions stay on device except when the user later opts into a clearly described notification service.

## Definition of complete

Octonaut is complete when a new implementation can satisfy all release-one requirements and acceptance criteria in these documents using only the contracts here, fixture JSON, and public platform documentation. No screen may depend directly on Hydra code, Hydra server routes, RevenueCat identifiers, or JavaScript application state.
