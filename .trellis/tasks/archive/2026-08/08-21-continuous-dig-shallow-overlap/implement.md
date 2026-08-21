# Implementation Plan

## Phase A: ExcavationWorld 鈥?analytic evidence

- [x] Add `_analytic_cut_evidence(snapshot)`: tooth + width-line sampling of
      `TerrainState`, engagement, max penetration, intent (work-equipment joint\r\n      velocity or tooth movement criteria).
- [x] Cutting classification consumes analytic evidence; validated in-band
      query contact stays a supplementary trigger only.
- [x] Split batch eligibility: cutting = analytic; support = query identity.
- [x] `_cut_motion_from_batch` uses tooth positions directly.

## Phase B: Runtime 鈥?analytic engagement

- [x] `probe_cut_penetration` runs every tick independent of query validity;
      low-pass engagement; resistance saturates at MIN_CUT_SPEED_SCALE (never stalls).

## Phase C: Tests

- [x] New `analytic_dig_test.gd`: sustained press cuts every commanded tick
      with bounded penetration; swing-drag cuts; resting bucket cuts nothing;
      stale identity keeps cutting, blocks support.
- [x] Update `excavation_gameplay_test.gd` expectations that encoded
      query-mandatory cutting; register the new test in the matrix.

## Phase D: Spec and verification

- [x] Rewrite `.trellis/spec/frontend/client-boundary.md` cutting contract:
      soil cutting is analytic on TerrainState; queries arbitrate support and
      blocking only; initial overlap can never disarm cutting.
- [x] Focused tests, full standalone matrix, `git diff --check`.

## Risky Files

- `godot/client/scripts/excavation_world.gd`
- `godot/client/scripts/jolt_chassis_track_runtime.gd`
- `godot/client/tests/analytic_dig_test.gd` (new)
- `godot/client/tests/excavation_gameplay_test.gd`
- `.trellis/spec/frontend/client-boundary.md`
