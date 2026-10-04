# Octonaut - native Reddit client for Apple platforms

![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)

Octonaut is a native SwiftUI Reddit client for iPhone, iPad, and Mac. The underlying data access architecture is inspired by [https://github.com/dmilin1/hydra/](https://github.com/dmilin1/hydra/).

Just want to try it on iPhone? [TestFlight](https://testflight.apple.com/join/kRJfvUE6)

## ✨ Features


- iPhone Duo support!
- Multireddit/Custom feeds - create a feed of subreddits from amongst your subscribed reddits, or add subreddits which you aren't subscribed to.

- Browse public Reddit feeds without an account, or sign in through Reddit's website.
- Switch between multiple Reddit accounts.
- Create custom feeds from subscribed or other communities, and sync them across your Apple devices with iCloud.
- Read threaded comments and view images, galleries, GIFs, and video.
- Report posts and comments using community rules, or continue on Reddit for other reporting reasons.
- Search posts, communities, and users.
- Use local filters, drafts, seen-post history, and usage statistics.
- Generate summaries on device with an Apple Intelligence-supported device or with an optional OpenAI-compatible LLM provider.
- Use native layouts for iPhone and iPad, including an iPad feed-detail split view.
- Use a dedicated Mac interface with a sidebar, feed and detail columns, menus, keyboard shortcuts, and a native Settings window.

## 🚀 Getting Started/Contributing

Below are instructions to build it from source. If you're interested in using this on an iPhone and want to skip the build, use the [TestFlight](https://testflight.apple.com/join/kRJfvUE6) link. (The iPad and macOS apps have much less polish.)

If you want to contribute code, please target your pull requests onto the develop branch. (Pushes to main trigger TestFlight releases!)

### Prerequisites

Before you begin, make sure you have:

- **macOS** with [Xcode 27](https://developer.apple.com/xcode/) or newer.
- **iOS 26 or newer** on a simulator or device, or **macOS 26 or newer** for the Mac app.
- **Git** for cloning the repository.
- **XcodeGen** only if you plan to edit `project.yml`. Install it with `brew install xcodegen`.

You do not need a Reddit API key, client ID, client secret, or developer application.

### 1. Clone the Repository

```bash
git clone https://github.com/ledwardchow/Octonaut.git
cd Octonaut
```

### 2. Open the Project

```bash
open Octonaut.xcodeproj
```

The Xcode project is checked in and ready to build. There are no package installation or CocoaPods steps.

### 3. Run the App

1. Select the **Octonaut** scheme for iPhone/iPad, or **OctonautMac** for Mac.
2. Choose an iOS 26 or newer simulator or connected device, or choose **My Mac**.
3. If you are using a physical device, select your development team under **Signing & Capabilities**.
4. Press **Run** or use ⌘R.

For the Mac app, you can also build and launch from Terminal:

```bash
./script/build_and_run.sh
```

### Reporting content

Choose **Report** from a post or comment menu. On Mac, posts also have a Report button above the detail view. Sign in to submit a report using one of the community’s rules. **Open post on Reddit** or **Open comment on Reddit** opens the content for other reporting reasons or if submission fails. Use its ⋯ menu and choose **Report**. The browser has its own Reddit login, separate from Octonaut. **Copy link** lets you use another browser.

Reporting uses the existing Reddit website session. It does not require developer registration. Automated reporting tests use synthetic responses and never send reports to Reddit. Live submission still needs to be checked in a private test community.

### 4. Run the Tests

Use **Product > Test** in Xcode or press ⌘U.

You can also run the test suite from Terminal:

```bash
xcodebuild test \
  -project Octonaut.xcodeproj \
  -scheme Octonaut \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

If that simulator is not installed, replace `iPhone 17 Pro` with one shown by:

```bash
xcrun simctl list devices available
```

## 🔐 Privacy

See [Octonaut Privacy Policy](./PRIVACY.md).

Octonaut does not record or send any telemetry.

By default, post and comment summaries are generated on device (or disabled if your device doesn't support Apple Intelligence). If you choose an OpenAI-compatible summary provider, its API key is also stored in Keychain and the selected post or comment text is sent to that provider.

## 📄 License

Octonaut is available under the [GNU Affero General Public License v3.0](./LICENSE.txt).

## Custom feed sync

Custom feed names and community lists sync between iPhone, iPad, and Mac using the same Apple account. Edits and deletions sync too. Existing local feeds are included automatically, and feeds remain available offline. iCloud delivers updates in the background, so changes may take a little time to appear on another device.

The apps use iCloud key-value storage with the shared entitlement `$(TeamIdentifierPrefix)com.leddytech.octonaut`. Enable iCloud Key-value storage for both app targets and use provisioning profiles that include this entitlement. No CloudKit container or database schema is required. Reddit session credentials stay in the local Keychain.

Each feed has its own sync record. If two devices change the same feed offline, the later recorded edit wins. Deletions are retained so an unchanged offline copy does not restore a deleted feed. If iCloud storage reaches its limit, changes stay local and the feed editor shows a storage message.

To verify a release, use signed builds on two devices with the same Apple account: create a feed on one, edit it on the other, and confirm deletion reaches both. Automated tests use an in-memory iCloud substitute; they do not verify delivery through Apple's servers.
