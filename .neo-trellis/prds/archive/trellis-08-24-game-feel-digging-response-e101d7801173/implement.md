# Implementation plan

1. [x] Define response phases, normalized inputs, output schema, and invariants.
2. [x] Implement deterministic phase classification and raw intensity.
3. [x] Add bounded, hysteretic, slew-limited per-axis speed scaling.
4. [x] Integrate at the safe equipment command/accepted-motion boundary.
5. [x] Add SY205/SY135 and material tuning data with shared semantics.
6. [x] Publish lifecycle-safe read-only presentation telemetry.
7. [x] Tune with free/cut/full/overflow/dump/escape recorded curves.
8. [x] Run neutral/re-arm, both-model, conservation-invariance, performance, and
       full regression checks.

## Risk and rollback

- One feature/config switch restores scale 1.0 without touching soil state.
- Clamp and escape behavior are safety contracts, not tuning preferences.
- Do not use response tuning to hide failed material capture or terrain defects.
