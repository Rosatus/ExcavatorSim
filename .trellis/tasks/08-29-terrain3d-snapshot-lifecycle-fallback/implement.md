# Implementation plan — Snapshot lifecycle and fallback

1. Formalize configured backend, active renderer, and presentation override state.
2. Harden full/patch/stale/resync gates and bounded failure reasons.
3. Enforce one-visible-surface transitions and synchronized fallback catch-up.
4. Make Test Grid enter/exit preserve the configured backend and latest identity.
5. Add status counters/identities/material/dressing fields.
6. Restore and extend `terrain3d_adapter_test.gd` in the standalone matrix.
7. Run rapid revisions, forced failures, reset/model switch, Test Grid, visual,
   terrain, and repository checks.
8. Record Phase 3's stable diagnostic/equivalence interface.
