- [x] Reproduce resize and swipe behavior on Duo.
- [x] Trace sizing and gesture ownership.
- [x] Compare fixes and agree on one implementation.
- [x] Implement stable resizing, browsing resizing, and feed dismissal.
- [x] Verify simulator gestures, persistence, and column bounds; deploy to Scarlett.
- [x] Confirm the final native swipe on physical Scarlett.
- [x] Review changes and update TestFlight notes.
- Commits and PR skipped: user requested local fixes and phone deployment.

Throughput checkpoint: one implementation owner handles coupled layout and settings; parent owns device deployment; independent reviewer checks sizing and gestures.

Design: keep the persistent columns. Use one sizing calculation during and after dragging, measure movement in the fixed column container, and save separate community and reading-feed widths. A system split-view replacement was rejected because it would replace the existing column/navigation ownership for this fix.

Evidence: browsing uses a plain Divider and fixed 220/240-point width. Reading live width permits values beyond the persisted fraction limit, producing a release jump. Moving local gesture coordinates remain a runtime hypothesis until measured.

Final simulator results and limitations: `.audit/duo-column-gestures-results.md`. Parent confirmed the final source was installed on Scarlett; physical confirmation of the native swipe remains pending.

User final confirmation on Scarlett: "Both fixed" for easier divider targets and swipe flicker.
