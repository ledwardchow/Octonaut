# Settings

Change reading preferences and keep them across app launches.

## Sub-features

- `settings-open`: open General and Appearance.
- `settings-sort`: change Remember sort per community and retain it after restart.

## How to get to it (user POV)

Choose Settings, then General or Appearance.

## Driving it with XcodeBuildMCP

Preconditions: Launch with `settings`. Snapshot the Settings screen, tap the current General ref, and require Default post sort plus Remember sort per community. Capture its starting value. Tap that switch once and require its value to change. Restart using the skill commands, reopen General, and require the changed value. Read `sorting.rememberSortPerCommunity` from the preview preferences plist. Capture screenshots before and after. Return using Settings back, open Appearance, and require Feed layout and Show post flair.

## Gotchas

- An injected tap can leave the screen unchanged. Require the resulting value before restarting.
- Fixture feeds do not prove that appearance or sorting settings affect live listings.
- Reset App and Reset Settings have wider effects; do not substitute them for this journey.
