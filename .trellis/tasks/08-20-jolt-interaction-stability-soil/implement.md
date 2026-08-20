# Implementation Plan

## Child 1: Stabilize Jolt tracked chassis

- [ ] Add support/load telemetry and reproduce straight/arc/pivot jitter with quantitative baselines.
- [ ] Replace dual load-bearing contact with ray/shape spring-damper support and contact-load traction limits.
- [ ] Separate the safety hull from flat-ground support collision.
- [ ] Add pivot-aware lateral slip and simplify differential yaw control.
- [ ] Tune SY205/SY135 descriptors and strengthen speed/stability tests.
- [ ] Run standalone matrix and Godot MCP travel smoke, then commit/archive the child.

## Child 2: Calibrate Jolt posture and longitudinal response

- [ ] Diagnose rigid-body versus visual-root pitch on reset for SY135/SY205.
- [ ] Align reset posture to the authoritative terrain normal and verify clearance.
- [ ] Tune bounded acceleration, coast, braking, and reverse zero-crossing response.
- [ ] Add stop-time/distance and peak pitch telemetry/regressions.
- [ ] Run no-Python reset/travel/brake smoke, then commit/archive before terrain work.

## Child 3: Incremental Terrain3D deformation

- [ ] Add dirty bounds to terrain mutations and bound brush iteration.
- [ ] Preserve Terrain3D visibility while revisions are pending.
- [ ] Replace per-revision `import_images` with existing-region height edits and edited-region `update_maps`.
- [ ] Stop per-revision dressing and fallback reconstruction.
- [ ] Replace complete collider-body rebuilds with dirty-chunk swaps.
- [ ] Add counters/tests for no full import, no node replacement, and revision-safe collider updates.
- [ ] Run standalone matrix and Godot MCP excavation flicker smoke, then commit/archive the child.

## Child 4: Physics-informed bucket soil

- [ ] Correct the existing fill surface and release direction to world gravity as a safe baseline.
- [ ] Add model-specific shovel geometry and parcel-only moving bucket shell.
- [ ] Add bounded volume-carrying dynamic parcel pool and transfer state machine.
- [ ] Convert cutting-edge active-zone volume into world parcels instead of immediate bucket credit.
- [ ] Capture parcels through lip/cavity containment and capacity hysteresis.
- [ ] Release captured material under gravity and merge settled parcels into loose terrain batches.
- [ ] Add conservation, capacity, teardown, performance, and both-model interaction tests.
- [ ] Run standalone matrix and Godot MCP dig/carry/dump smoke, then commit/archive the child.

## Parent Integration Gate

- [ ] Run the complete standalone matrix and backend compatibility verification.
- [ ] Run a no-Python Godot MCP sequence on SY205 and SY135: start -> travel -> pivot -> dig -> carry -> dump -> pause -> reset -> switch model.
- [ ] Confirm no terrain flicker, no chassis jitter, bounded parcel counts, no stale bodies, and no authority regression.
- [ ] Update architecture/client specs to describe support ownership, dirty terrain patches, and the dynamic parcel ledger.

## Validation Commands

```powershell
pixi run verify
& godot/client/tests/run_standalone_matrix.ps1
git diff --check
python ./.trellis/scripts/task.py validate 08-20-jolt-interaction-stability-soil
```

Godot MCP live evidence is required after the headless matrix because visual jitter, flicker, and gravity behavior are not fully established by headless assertions.
