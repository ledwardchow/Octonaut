- [x] Capture the live signal on the matching surface via the driver skill: a CPU profile for a spinning process, a heap snapshot for a leak, a CDP trace for a visual glitch. A real artifact, not a guess.
  Inspected user screen recording and captured summary/scroll geometry logs in the simulator.
- [x] Reduce the artifact to the smoking gun: the function on the hot path, the retainer chain from the leaked object to a GC root, the loop firing without input.
  SummaryCardView task resets loaded output on reappearance, shrinking then restoring the card.
- [x] Prove the mechanism before believing it.
  Original task reproduced 258 -> 93.67 -> 258 height changes and a 164.33-point scroll offset correction. Temporary control retaining completed output removed reappearance height changes. Full repeated trap remains unconfirmed.
- [x] Map the finding back to source: file, symbol, the line that allocates or schedules.
  OctonautApp/Features/Intelligence/SummaryCardView.swift lines 89-98.
- [x] throughput checkpoint: n/a, read-only forensics

Evidence: /private/tmp/octonaut-scroll-diagnosis/evidence/result.md
No production code edits. Feed case remains unverified.
