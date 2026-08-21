# Implementation Plan

## Phase A: Correct Current Presentation

- [ ] Align the bucket fill surface to world gravity and derive its profile from the aggregate ledger.
- [ ] Remove artificial parcel/flow velocity from the authoritative transfer path; keep only bounded dust jitter.
- [ ] Add baseline tests for fill, orientation, release, and capacity.

## Phase B: Parcel And Shell Foundation

- [ ] Add model-specific shovel geometry contracts for SY205/SY135.
- [ ] Add a parcel-only collision layer and moving compound `AnimatableBody3D` shell.
- [ ] Add the bounded volume-carrying parcel pool, identity, sleep, recycle, and generation teardown.

## Phase C: Physics-Informed Transfers

- [ ] Convert cutting-edge active-zone volume into world parcels/aggregate remainder.
- [ ] Capture parcels through lip/cavity containment and capacity hysteresis.
- [ ] Release captured parcels with inherited bucket velocity and gravity.
- [ ] Settle and batch-merge grounded parcels into loose terrain through the dirty terrain scheduler.
- [ ] Keep chassis support/wrench and work-equipment motion behind existing bounded contracts.

## Phase D: Verification

- [ ] Add conservation, miss/capture, capacity, gravity, settle, reset, model-switch, and stale-generation tests.
- [ ] Add parcel-count and fixed-tick timing budget assertions for low/balanced/high profiles.
- [ ] Run standalone matrix and `pixi run verify`.
- [ ] Run Godot MCP dig/carry/dump/settle smoke for both models with Python stopped.
- [ ] Update architecture/client boundary docs, commit, push if requested, and archive this child.

## Risky Files

- `godot/client/scripts/bucket_soil_state.gd`
- `godot/client/scripts/excavation_world.gd`
- `godot/client/scripts/bucket_proxy_sweeper.gd`
- `godot/client/scripts/soil_effects.gd`
- model soil contracts under `godot/client/resources/soil/`
- new parcel manager and bucket shell scripts/scenes

