---
name: trellis-break-loop
description: "Investigate repeated failed fixes or surprising high-impact defects with discriminating evidence."
---

# Break a debugging loop
Use for repeated failed fixes or surprising high-impact defects, not every bug.
Describe observed failure, leading hypotheses and evidence distinguishing them. Inspect affected contracts/consumers. Prefer a focused reproducer over repeated broad suites; do not invent numerical probabilities/confidence thresholds.
Explain failed fixes when understood. Make the smallest justified correction and validate the failure mode; broaden only with evidence of a shared cause.
Record useful prevention in an existing spec/regression test. No mandatory whole-repo expansion, multi-section report, template synchronization, new task or Git commit.
