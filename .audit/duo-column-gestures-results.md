Duo column gesture results

Implemented:
- Both dividers resize in a fixed coordinate space, with separate saved community and reading-feed widths.
- Preview and saved reading widths use the same bounds. Previously a 590-point preview at 951 points saved as 570 points, causing a release jump.
- Cancelled gestures clear temporary resize state. Reset column widths resets both saved values.
- A native rightward pan on the feed closes the post, rejects vertical/leftward starts and starts beside the divider, and cancels underlying taps.

Verification:
- Focused sizing, swipe-direction and settings persistence tests passed, 2 tests with 0 failures: /private/tmp/octonaut-duo-gesture-tests.log.
- Missing community width defaults to 240; saved 300 restores; reset returns 240; non-finite persisted width returns 240; 900 clamps to 360.
- On the unfolded disposable Duo, reading divider drags changed 346 to 440 to the 506-point maximum. Community divider changed 240 to 334. Values remained after relaunch.
- The original simultaneous SwiftUI swipe closed the post and also activated a row. User separately confirmed post reopening after partial swipes on physical Scarlett.
- Native recognizer diagnostics showed initial translation 225, then translation zero at began/ended for the coarse injected drag. Final code retains the accepted initial touch location and measures ending displacement from it. Diagnostic prints were removed.
- Final native 150-pixel right swipe over media closed to browsing without opening the viewer. Vertical feed dragging scrolled while the post stayed open. An ordinary media tap opened the viewer.
- Device Hub accessibility snapshots became stale during final checks; screenshots were used to inspect the visible result. Injected vertical dragging also activated a vote/login prompt after scrolling, so physical touch verification remains necessary.
- Final simulator build passed: /private/tmp/octonaut-duo-native-swipe-final-build.log.

Evidence retained:
- /private/tmp/octonaut-duo-resize-tests.log
- /private/tmp/octonaut-duo-gesture-tests.log
- /private/tmp/octonaut-duo-pan-instrument-build.log
- /private/tmp/octonaut-duo-pan-runtime.log (redirected capture was buffered; decisive native diagnostics were returned by console session 60787)
- /private/tmp/octonaut-duo-native-swipe-final-build.log
- Inline Device Hub screenshots and tool outputs in this task contain the runtime visual evidence.

Parent confirmed final source installed on Scarlett. Physical confirmation of the final native swipe is pending. No commit or PR was requested.

Follow-up: wider divider targets and swipe highlight

The shared divider now uses a centered 44-point clear gesture overlay above its 1-point separator. Swipe exclusion is 26 points from the line. Native pan recognition delays touches began to prevent buttons receiving press feedback before swipe recognition.

Build and the two existing focused sizing/direction/persistence tests passed: /private/tmp/octonaut-hit-target-tests.log. This does not verify actual offset hit testing or transient highlight suppression. The disposable fixture launched and unfolded, but every coordinate drag failed with Device Hub windowNotFoundAtPosition, including after raising the window. Physical verification of a grab about20 points from the line and swipe feedback is pending. No success claim is based on the failed tool actions.

Final physical confirmation: the user reported "Both fixed" on Scarlett after installing the widened divider targets and delayed swipe touch delivery. Easier divider grabbing and absence of swipe highlight/flicker are now confirmed by the user.
