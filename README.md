# Octonaut

Octonaut is a native SwiftUI Reddit client for iOS 26 and later. It browses Reddit's public web JSON routes without an API key. Signing in happens through Reddit's website in an isolated web view, and the resulting session is stored in Keychain.

Post and comment summaries can run on device or through a user-configured OpenAI-compatible provider. The default provider settings point to OpenRouter and `openai/gpt-5.6-luna`. A provider API key is required and is stored in Keychain.

## Run it

1. Open `Octonaut.xcodeproj` in Xcode 27.
2. Select the `Octonaut` scheme and an iOS 26 or newer simulator or device.
3. Choose your development team if you are installing on a device.
4. Build and run.

The checked-in Xcode project is ready to use. If you edit `project.yml`, install XcodeGen and run `xcodegen generate` from this folder.

## Tests

Use Product > Test in Xcode. The test target covers domain normalization, persistence limits, settings, URL routing, media mapping, deterministic excerpts, and local filters.

The complete product and implementation specification is in [`spec/`](spec/README.md). Push notifications are deliberately deferred until a future companion server exists.
