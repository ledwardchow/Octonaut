- [x] `how` over the affected subsystem.
- [x] `architect` for parallel design exploration.
- [x] Write the throughput checkpoint as four todo items.
  - Blocking first steps. Confirm layout ownership and eligibility before implementation.
  - Independent workstreams. Read-only design alternatives run together; implementation stays with one owner.
  - Shared mutable state. Implementation uses its own worktree. Simulator evidence uses /private/tmp/octonaut-duo-verify.
  - Smallest safe decomposition. One owner for coupled navigation, settings and layout tests.
- [x] Delegate code-writing to a subagent using your configured feature model.
- [x] Verify on the matching surface. Duo simulator reading, drag, scroll, post switching, back, restart and folding passed; four focused tests passed.
- [ ] Rebase into small, ordered commits. Stack follow-ups.
  - skip: user requested local implementation, no commit or PR requested.
- [x] Design agreed by independent judge; review findings addressed or checked on the simulator.
- [ ] Run **Opening a PR**.
  - skip: local implementation requested.

Architect: Ground, Sketch, Agree, Implement, Scrap.
Arena: Frame, Fan out, Cross-judge, Pick, Graft, Verify.
Rubric: correct eligibility; feed identity; navigation preservation; constrained accessible resizing; minimal ownership and API.

Design choice. Persistent custom columns keep the feed mounted. NavigationSplitView visibility was rejected because it does not give reliable drag sizing or feed identity during column role changes. Two design explorers and an independent judge agreed. Root width and size class flow through environment so the Settings detail column does not decide eligibility.
