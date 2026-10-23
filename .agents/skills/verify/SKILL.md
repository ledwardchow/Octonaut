---
name: verify
description: Drive Octonaut's iOS app in a disposable simulator, check user flows with XcodeBuildMCP, and capture evidence after UI changes.
---

# Verify Octonaut

Read [the feature map](features/README.md), then the relevant journey. The primary surface is iPhone/iPad SwiftUI. Mac has a separate shell and requires separate verification; an iPhone result does not establish Mac or iPad behavior.

## Launch

Use macOS with Xcode 27 and an available iOS 26+ runtime. There are no packages, migrations, or credentials to install. From the repository root, create a separate simulator and evidence folder:

```bash
RUN=$(mktemp -d /private/tmp/octonaut-verify.XXXXXX)
mkdir "$RUN/evidence"
xcrun simctl list runtimes
SIM=$(xcrun simctl create "Octonaut-verify-$(basename "$RUN")" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro com.apple.CoreSimulator.SimRuntime.iOS-27-0)
printf '%s\n' "$SIM" > "$RUN/evidence/simulator-id"
git rev-parse HEAD > "$RUN/evidence/revision"
git status --short > "$RUN/evidence/working-tree.txt"
```

Use an installed available runtime/device type if those identifiers are absent. Keep RUN and SIM for this run. Never reuse an existing personal simulator or sign the disposable simulator into an Apple account; SettingsStore can write custom feed records to iCloud when available. Simulator services may require execution outside the filesystem sandbox.

Call XcodeBuildMCP `session_show_defaults`, then `session_set_defaults` with projectPath equal to this checkout's Octonaut.xcodeproj, scheme `Octonaut`, configuration `Debug`, simulatorId SIM, derivedDataPath RUN/build, and bundleId `com.leddytech.octonaut`. Call `build_sim` with extraArgs `["CODE_SIGNING_ALLOWED=NO"]`. Require build success. Save its build log under RUN/evidence. Boot, install, and launch explicitly:

```bash
xcrun simctl boot "$SIM"
xcrun simctl bootstatus "$SIM" -b
xcrun simctl install "$SIM" "$RUN/build/Build/Products/Debug-iphonesimulator/Octonaut.app"
SIMCTL_CHILD_OCTONAUT_SCREENSHOT=settings xcrun simctl launch "$SIM" com.leddytech.octonaut
```

Call XcodeBuildMCP `open_sim({})` before UI actions. In the initial run, switch taps only took effect after opening the Simulator frontend.

Use `settings`, `feeds`, `detail`, `media`, or `blocked-users` as the screenshot value for the journey. This existing Debug mode uses fixture services and real SwiftUI controls. Ready means snapshot_ui shows the expected usable screen: `General` and `Appearance` for settings, `Home` for feeds, coast post and comments for detail, or gallery images for media. A PID alone is insufficient.

Do not use build_run_sim for fixture launch: in the initial verification it ignored the session environment and started the live app. Explicit SIMCTL_CHILD launch reached the correct fixture screen. If live loading or a Reddit blocking error appears, terminate this instance and relaunch explicitly before driving.

## Doctor

Run this read-only check when the UI looks wrong:

```bash
xcrun simctl get_app_container "$SIM" com.leddytech.octonaut app
xcrun simctl spawn "$SIM" launchctl list | rg 'UIKitApplication:com.leddytech.octonaut'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$RUN/build/Build/Products/Debug-iphonesimulator/Octonaut.app/Info.plist"
```

Require the container path to contain SIM, a running PID, the expected build log/revision, and snapshot_ui to show the selected fixture screen. Retry snapshot_ui once if a new simulator's remote automation session times out. Never treat an old screenshot as evidence for the current process.

## Drive

Use XcodeBuildMCP `snapshot_ui({})`. Resolve a control's visible label to its current elementRef, then call `tap({elementRef: ref, postDelay: 2})`. Refresh after navigation or scrolling. Use `type_text` for focused fields and `swipe` on a current scroll target. Inspect each tool's schema before calling it. Element refs are temporary; do not copy them between screens or runs. Tap success only confirms injection; require the expected screen or changed value before continuing. If the screen is unchanged, refresh, wait for it to settle, and retry once with the current ref.

Restart the same isolated app to check stored settings:

```bash
xcrun simctl terminate "$SIM" com.leddytech.octonaut
SIMCTL_CHILD_OCTONAUT_SCREENSHOT=settings xcrun simctl launch "$SIM" com.leddytech.octonaut
```

## Evidence

Save action/tool responses and before/after semantic snapshots as JSON under RUN/evidence, plus screenshots from `screenshot({returnFormat: "path"})`. Copy returned screenshot files into that directory. Record feature ID, entry point, fixture value, build/revision, actual assertions, failures, and skipped preconditions. For settings, reopen the screen after restart and inspect the stored preference as well:

```bash
DATA=$(xcrun simctl get_app_container "$SIM" com.leddytech.octonaut data)
plutil -p "$DATA/Library/Preferences/com.ledwardchow.Octonaut.preview.plist"
```

Capture only relevant nonsensitive values. Exercise user controls; do not set preferences or internal state to manufacture success. Fixture mode bypasses Reddit transport, authentication, feed refresh, and some persistence paths. Accounts and drafts are in memory; custom feeds are reseeded at launch. Screenshot-mode feed layout need not react to settings. These flows prove UI behavior only where the fixture supports it. They cannot prove live requests, signed iCloud delivery, media export, summaries, or real login. Tests must never contact Reddit. Avoid browser handoff, sign-in continuation, external links, report submission, and external summary providers during automated verification. Do not claim zero network activity from a mode name alone; inspect its service wiring and report any observed external requests.

## Cleanup

Run after successful and failed attempts. Check SIM against the saved simulator-id and its Octonaut-verify name before deleting it. Terminate only this bundle on this simulator; if it already exited, record that and continue. Then:

```bash
xcrun simctl shutdown "$SIM"
xcrun simctl delete "$SIM"
xcrun simctl list devices | rg -F "$SIM" # must find no device
ls -l "$RUN/evidence" # proof must still exist
```

Keep RUN/evidence. Build scratch can be removed separately after confirming the evidence contains the copied build log. Never kill by process name. The repository's script/build_and_run.sh uses pkill and shared Mac state, so it is unsuitable for isolated verification.

## Helpers

No helper scripts are shipped. The commands above and XcodeBuildMCP are the harness. Use `/maintain-verification-skill` to update the map when app behavior changes.

## Last verification

On 15 October 2026, a new iPhone 17 Pro simulator on iOS 27.0 built and ran the Debug app. General and Appearance navigation passed. Remember sort per community changed through the UI, survived restart, and matched the stored preference. The simulator was deleted and evidence remained at `/private/tmp/octonaut-verify-20261015/evidence/result.md`. Only settings were exercised; the other journeys are source-derived. The initial combined build-and-run launch attempted anonymous Reddit loading before the explicit fixture launch corrected it.
