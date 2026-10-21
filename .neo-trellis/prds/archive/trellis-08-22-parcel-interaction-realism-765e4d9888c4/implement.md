# Implementation Plan

## Phase A: Barrier

- [x] `SoilParcelPool`: build 4-plate `AnimatableBody3D` barrier (floor -Y,
      back +Z, sides ±X, mouth open) from cavity half-extents; retarget to
      cavity transform each `step_pool`; layer = machine bit.
- [x] World passes cavity extents at pool creation (already computed for
      capture).

## Phase B: Absorption and spray

- [x] Progressive absorption state (~0.18 s) with proportional mesh/collider
      shrink; capacity-stall keeps remainder physical.
- [x] Cut events gain tooth velocity; spawn spread biased upward.

## Phase C: Verification tails

- [x] Conservation assertion in `soil_parcel_test.gd`.
- [x] Full-pool cut backlog and delayed settle identity conservation cases.
- [x] Rewrite stale empty-bucket sections in `excavation_gameplay_test.gd`;
      align release candidate M7.
- [x] Full standalone matrix (24 scripts) + `git diff --check`.

## Verification Evidence

- Godot 4.7.1 import succeeds.
- `soil_parcel_test.gd`, `excavation_gameplay_test.gd`,
  `release_candidate_test.gd`, and `model_switch_test.gd` pass.
- `run_standalone_matrix.ps1` passes all 24 scripts.

## Risky Files

- `godot/client/scripts/soil_parcel_pool.gd`
- `godot/client/scripts/excavation_world.gd`
- `godot/client/scripts/bucket_soil_state.gd`
- `godot/client/tests/excavation_gameplay_test.gd`
- `godot/client/tests/release_candidate_test.gd`
