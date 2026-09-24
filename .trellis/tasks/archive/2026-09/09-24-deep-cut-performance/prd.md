# Deep excavation performance

User authorization (2026-09-24): retain voxels; diagnose shallow/deep excavation carefully, identify measured bottlenecks, then optimize. Consider native C++ only if algorithmic improvements leave a measured hotspot.

Preserve SY135 cutting geometry, sparse material accounting, reset/generation safety, refill/re-cut behavior, protected bounds and truthful collision readiness. No physics slowdown, graphical downgrade or dropping cuts to improve numbers.

## Plan
1. Paired depth/state probe: shallow/middle/deep, intact versus already excavated air, editing versus idle. Attribute proposal, snapshot, worker coverage/edit, main publication/cleanup, mesh and collision costs.
2. Implement the smallest structural optimization justified by evidence. Candidate mechanisms: occupied-column summaries, worker support cleanup, actual changed-block publication. Preserve the SDF as the sole terrain authority.
3. Validate exact geometry/ledger and lifecycle parity plus paired performance under the same conditions; escalate to C++ only with evidence.

Agent automated: phase microbenchmarks and representative rendered depth replay, parity and refill/cancel tests, log errors, queue latency/backpressure and memory checks. Human manual: final excavation feel and visual continuity.

Pre-existing changes: race-mode task archival (deleted active task files and untracked archive). Leave untouched. Runtime found at C:/apps/godot_voxel; pinned v1.7 hash verified. E: default toolchain path is absent on this machine.

## Completion
User accepted the delivered round and requested batched commits and archival on 2026-09-24. See implement.md, diagnosis.md and comparison.json for final scope, commits, evidence and limits.
