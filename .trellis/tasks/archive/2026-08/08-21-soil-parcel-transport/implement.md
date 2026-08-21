# Implementation Plan

## Phase A: Ledger and event plumbing

- [x] `BucketSoilState`: aggregate `cut_events` in `step_fixed` result;
      add `credit_captured_volume` and `release_poured_volume` public APIs.
- [x] Confirm the production `step_fixed` call site and dump/spill handler
      regions in `excavation_world.gd`.

## Phase B: SoilParcelPool

- [x] New `scripts/soil_parcel_pool.gd`: preallocated frozen body pool,
      volume<->radius mapping, spawn_from_cut, release_volume, capture pass,
      settle pass with retry budget, clear_for_generation, telemetry.
- [x] Wire into `ExcavationWorld._physics_process` after `soil_state.step_fixed`;
      feed cavity transform + descriptor collision layers; rewrite dump/spill
      to pour parcels; hook clear on reset paths.

## Phase C: Tests and spec

- [x] New `tests/soil_parcel_test.gd`; register in
      `tests/run_standalone_matrix.ps1`.
- [x] Restore occupancy/carry/dump expectations in
      `excavation_gameplay_test.gd` and release candidate M7 against the pool.
- [x] Update `.trellis/spec/frontend/client-boundary.md` with the transport
      contract (parcels never gate cutting; settle rides deposit pipeline).
- [x] Focused suites + full standalone matrix + `git diff --check`.

## Risky Files

- `godot/client/scripts/soil_parcel_pool.gd` (new)
- `godot/client/scripts/excavation_world.gd`
- `godot/client/scripts/bucket_soil_state.gd`
- `godot/client/tests/excavation_gameplay_test.gd`
- `godot/client/tests/release_candidate_test.gd`
