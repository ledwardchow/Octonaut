# Octonaut - iOS Reddit client

![License: AGPL v3](https://img.shields.io/badge/License-AGPL_v3-blue.svg)

Octonaut is a native SwiftUI iPhone/iPad client for Reddit. The underlying data access architecture is derived from [https://github.com/dmilin1/hydra/](https://github.com/dmilin1/hydra/).

## ✨ Features

- Browse public Reddit feeds without an account, or sign in through Reddit's website.
- Switch between multiple Reddit accounts.
- Read threaded comments and view images, galleries, GIFs, and video.
- Search posts, communities, and users.
- Use local filters, drafts, seen-post history, and usage statistics.
- Generate summaries on device with an Apple Intelligence-supported device or with an optional OpenAI-compatible LLM provider.
- Use native layouts for iPhone and iPad, including an iPad feed-detail split view.

## 🚀 Getting Started

### Prerequisites

Before you begin, make sure you have:

- **macOS** with [Xcode 27](https://developer.apple.com/xcode/) or newer.
- **iOS 26 or newer** on a simulator or device.
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

1. Select the **Octonaut** scheme in Xcode.
2. Choose an iOS 26 or newer simulator or connected device.
3. If you are using a physical device, select your development team under **Signing & Capabilities**.
4. Press **Run** or use ⌘R.

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

Octonaut does not record or send any telemetry.

By default, post and comment summaries are generated on device (or disabled if your device doesn't support Apple Intelligence). If you choose an OpenAI-compatible summary provider, its API key is also stored in Keychain and the selected post or comment text is sent to that provider.

## 📄 License

Like the Hydra project that this app is derived from, Octonaut is also available under the [GNU Affero General Public License v3.0](./LICENSE.txt).
