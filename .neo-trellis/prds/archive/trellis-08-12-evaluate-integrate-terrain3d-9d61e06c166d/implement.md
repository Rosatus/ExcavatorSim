# Terrain3D integration execution plan

## Ordered checklist

1. [x] Confirm addon/package policy: exclude the unreferenced tilde DLL from the
   planned package, inventory required Windows files, review `extras/3rd_party`
   licenses, and preserve the MIT notice.
2. [x] Enable Terrain3D in a scoped branch of the Godot project and add the
   `Terrain3DAdapter` node/resource without deleting the current terrain nodes.
3. [x] Implement the snapshot materializer using the Terrain3D 1.0.2 API. Validate
   region size, image format, world origin, X/Z orientation, height scale, and
   map update behavior under Godot 4.7.1.
4. [x] Add visual parity coverage for flat/baseline, edited, reset, and terrain
   winding/normals cases. The canonical `TerrainState` snapshot bytes/digest
   remains the oracle.
5. [x] Add runtime edit integration: accepted `BucketSoilState` cut/deposit edits
   enqueue generation/revision-gated Terrain3D updates; stale completions are
   discarded; plugin failure falls back to the current renderer.
6. [x] Add optional Terrain3D collision configuration and Jolt raycast/contact
   smoke. Measure Dynamic/Game collision rebuild cost and keep Disabled/fail-open
   behavior available.
7. [x] Run the standalone Godot matrix, the Terrain3D-specific headless smoke,
   `pixi run backend-smoke`, `pixi run verify`, and `git diff --check`.
8. [x] Perform a final review of addon size, binary architecture coverage,
   provenance, and source-control scope before committing.

## Validation commands

```powershell
& $GodotExe --headless --path godot/client --editor --quit
.\godot\client\tests\run_standalone_matrix.ps1 -GodotExe $GodotExe
pixi run backend-smoke
pixi run verify
git diff --check
```

## Risk and rollback points

- If the GDExtension fails to load, do not alter logical terrain; disable the
  adapter and use the custom renderer/collider.
- If D3D12 material/TextureArray output is unacceptable, retain the adapter only
  for editor/import experiments and keep the current runtime path.
- If map updates are too slow, batch changed regions or remain on the custom
  renderer for the small first-slice grid.
- If Terrain3D collision does not meet fail-open or Jolt query behavior, leave
  `TerrainCollider` as the production path and defer Terrain3D collision.
- If deterministic parity cannot be proven, do not make Terrain3D a logical
  state owner; rollback is a feature-flag change.

## Execution notes

- Godot 4.7.1 editor runtime smoke passed with the local Windows x86_64
  GDExtension: native Terrain3D loaded, baseline/cut/reset snapshots applied,
  and the custom mesh stayed hidden only while the native backend was active.
- `pixi run verify`, `pixi run backend-smoke`, `git diff --check`, and task
  context validation passed.
- The full standalone PowerShell matrix passed with all eight SceneTree scripts
  in an isolated project copy. The isolation excludes Terrain3D's Windows
  hot-reload `~libterrain...dll`, which is locked by the connected editor and
  is not a source/package artifact.
- Terrain3D Dynamic/Game collision was enabled in a smoke, and a Jolt raycast
  hit the native `Terrain3D` collider at the logical surface. Returning to
  Disabled removed the collision without changing logical terrain bytes or
  revision. The committed production default remains `collision_mode=0`.
