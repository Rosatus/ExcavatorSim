# Implementation Plan

## Phase 1 — Bootstrap and knowledge capture

1. [x] Initialize Git, Trellis (Codex workflow), and CodeGraph in `E:/projects/ExcavatorSim`.
2. [x] Record the product goal, Python authority boundary, Godot desktop direction, migration map, and deferred model/physics decisions in this task and `docs/`.
3. [x] Add a target-project README that explains how future agents start the backend and where the Godot client will live.

## Phase 2 — Backend and contract migration

1. [x] Copy the reusable Python package into `backend/`, with target-owned packaging and paths.
2. [x] Copy protocol schemas, backend tests/fixtures, and only backend verification scripts.
3. [x] Update imports, asset paths, startup commands, and test configuration so the target runs without the source checkout.
4. [x] Preserve protocol version, terrain algorithm identity, snapshot hashes, replay semantics, and license/provenance checks.

## Phase 3 — Asset and handoff migration

1. [x] Copy the five-part GLB visual set, calibration/provenance records, notices, and GLB guide.
2. [x] Add `docs/godot-integration.md` describing the future transport, pose, terrain, and physics seams.
3. [x] Add an explicit migration inventory of copied, adapted, reference-only, and deferred source areas.

## Phase 4 — Verification and handoff

1. [x] Run target backend tests, lint/type checks applicable to the migrated package, provenance checks, and standalone-path checks.
2. [x] Run CodeGraph status/sync after migration and confirm the index contains backend symbols.
3. [x] Verify no runtime import, symlink, editable install, or path reference points back to `E:/projects/BabylonSim`.
4. [x] Leave the target task in a state that a later agent can start Godot client development from `.trellis` context.

## Later tasks, deliberately not part of this bootstrap

- Godot Forward+ scene and UI;
- Godot terrain renderer and patch/snapshot synchronizer;
- Godot Physics/Jolt lifecycle adapter and static terrain colliders;
- bucket load visual presentation and falling soil effects;
- model collision proxies and dynamic excavator physics;
- C++ backend or GDExtension optimization.

## Validation commands

```powershell
Set-Location E:\projects\ExcavatorSim\backend
pixi run verify
pixi run python -m pytest

Set-Location E:\projects\ExcavatorSim
codegraph status .
rg -n "BabylonSim|E:/projects/BabylonSim|E:\\projects\\BabylonSim" backend protocol assets docs
```

If the target chooses a different Python environment during implementation, preserve equivalent commands and record them in the target README.
