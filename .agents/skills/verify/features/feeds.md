# Feeds and custom feeds

Choose a feed or create a personal list of communities.

## Sub-features

- `feeds-open`: Home, Popular and All.
- `feeds-create`: create and reopen a custom feed.
- `feeds-cancel`: cancel an unfinished edit.

## How to get to it (user POV)

Posts opens the feed list. Choose Home, Popular, All, or a custom feed. Use New Custom Feed in the list or Add menu. Edit Feed is in a custom feed context menu or swipe action.

## Driving it with XcodeBuildMCP

Preconditions: Launch with `feeds`. Resolve Home in the snapshot, tap it, and require sample post titles. Return through Posts and repeat for Popular and All. From New Custom Feed enter `Verification Feed` in Feed name, type `swift` in Community name, e.g. r/swift, and choose Add. Require r/swift selected and Save enabled; save and require the new feed in Posts. Reopen Edit Feed and require the name and community. Cancel a changed name and verify the original survives. Capture each entry point separately.

## Gotchas

- Apple & Swift and Photography are seeded. Custom feeds are reseeded on launch; restart persistence is unsupported here.
- A screenshot listing cannot establish live refresh, pagination, or per-community sorting.
- iCloud sync requires signed builds on two devices, outside this isolated journey.
