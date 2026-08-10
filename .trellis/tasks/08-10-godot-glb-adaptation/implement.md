# Implementation Plan

## Phase 0 — Planning gate

1. [x] Inspect the supplied GLB header, scene graph, meshes, materials, textures, pivots, and bounds.
2. [x] Confirm that five identifiable frame targets exist and that auxiliary linkage meshes can remain visual-only.
3. [x] Choose the repository target `godot/client/assets/visual/SY205_excavator_godot.glb` and preserve the exact source bytes.
4. [x] Receive explicit approval of this final child-task plan before `task.py start` and product writes.

## Phase 1 — Asset placement and import contract

1. [x] Copy the GLB to the target path and verify byte size/SHA-256.
2. [x] Add a Godot-local manifest with source provenance, import facts, five frame aliases, auxiliary linkage policy, and calibration status.
3. [x] Add an asset directory README that distinguishes the combined GLB from the legacy five-file backend manifest.
4. [x] Instantiate the imported GLB under `PresentationRoot` while retaining the placeholder fallback path.

## Phase 2 — Static adapter validation

1. [x] Add a focused Godot headless test that loads the GLB, resolves all five pivot paths, verifies expected mesh/linkage nodes, and reports imported material/texture availability.
2. [x] Use Godot MCP to inspect the imported hierarchy and run the scene/test; capture any import warnings.
3. [x] Capture imported rest transforms and record the calibration contract without yet wiring live transport.
4. [x] Add zero/asymmetric frame-parity fixture inputs for the adapter handoff to M2.

## Exit gate

- [x] The exact asset is present and hash-verified.
- [x] Godot imports and renders it without editor errors.
- [x] The five mapping targets and linkage policy are tested and documented.
- [x] No backend/protocol files change.
- [x] Placeholder foundation remains available as a rollback path.

## Validation commands

- `Get-FileHash godot/client/assets/visual/SY205_excavator_godot.glb -Algorithm SHA256`
- Godot MCP: `editor_manage({"op":"state"})`, filesystem scan, scene hierarchy, logs, and project run.
- `Godot_v4.7.1-stable_mono_win64.exe --headless --path godot/client --editor --quit`
- `Godot_v4.7.1-stable_mono_win64.exe --headless --path godot/client --script res://tests/sy205_glb_test.gd`
- `git diff --check`

## Risky files / rollback

- Binary asset: remove only the newly copied file if hash/import validation fails; retain the external source untouched.
- `project.godot` and `scenes/main.tscn`: review imported scene references; revert only the scoped asset-instance changes if needed.
- Godot-local manifest/test: keep the mapping versioned so M2 can consume or replace calibration without protocol drift.
