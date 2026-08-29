# Implementation plan — Snapshot lifecycle and fallback

1. [x] Formalize configured backend, active renderer, and presentation override state.
2. [x] Harden full/patch/stale/resync gates and bounded failure reasons.
3. [x] Enforce one-visible-surface transitions and synchronized fallback catch-up.
4. [x] Make Test Grid enter/exit preserve the configured backend and latest identity.
5. [x] Add status counters/identities/material/dressing fields.
6. [x] Restore and extend `terrain3d_adapter_test.gd` in the standalone matrix.
7. [x] Run rapid revisions, forced failures, reset/model switch, Test Grid, visual,
   terrain, and repository checks.
8. [x] Record Phase 3's stable diagnostic/equivalence interface.

Validation evidence:

- `terrain3d_adapter_test.gd`, `terrain_state_test.gd`,
  `construction_site_terrain_test.gd`, `visual_pass_test.gd`, and
  `visual_evidence_capture_test.gd` passed under Godot 4.7.1.
- Isolated Forward+/D3D12 probe passed at
  `output/terrain3d_phase2/lifecycle-final/run-summary.json`.
- Full standalone matrix reached the pre-existing/environmental
  `can_gateway_e2e_test.gd` heartbeat failure before the terrain portion; no
  Gateway files are in this task's diff.
