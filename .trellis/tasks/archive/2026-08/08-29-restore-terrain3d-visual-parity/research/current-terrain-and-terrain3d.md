# Current terrain and Terrain3D evidence

## Current runtime

- Main scene: `TerrainRoot/TerrainWorld/TerrainMesh`, sibling
  `Terrain3DAdapter`, project `TerrainCollider`, `ExcavationWorld`, and shared
  `ConstructionSiteDressing` (`godot/client/scenes/main.tscn:277-303`).
- `TerrainState` owns stable and loose height layers. `TerrainRenderer` builds
  the visible `ArrayMesh`; its project-owned shader provides the current brown
  construction-soil appearance (`terrain_renderer.gd:227-280`).
- `TerrainCollider` builds generation/revision-gated chunked concave shapes.
  Jolt track and bucket queries accept only matching derived collider hits and
  otherwise fall back to the logical heightfield.
- Product-default material lifecycle is `active_patch`; the selected
  `SoilInteractionAuthority` and `ActiveSoilPatch` transact against the product
  `TerrainState` only through `TerrainCommitScheduler`.

## Terrain3D state

- Addon/plugin/GDExtension, Windows binaries, adapter node, assets, material,
  and runtime setting all remain present. Terrain3D is not uninstalled.
- `TerrainWorld.terrain_backend="soil_shader"` prevents queuing snapshots to
  the adapter and explicitly deactivates native presentation. Commit
  `24a1d681eff91274d34be828b37d0036e9e90cbe` documents the reason as black
  Terrain3D 1.0.2 surfaces under Godot 4.7.
- The existing Terrain3D path already supports full import, incremental dirty
  region patching, stale rejection, fail-open fallback, optional collision,
  and status counters. The direct test is currently excluded from the matrix.

## Visual ownership

- Current visible ground: project procedural soil shader, not Terrain3D demo
  textures.
- Current persistent site cues: sibling `ConstructionSiteDressing`; independent
  of native/fallback terrain.
- Terrain3D-only dressing: 18 demo rocks plus the demo grass particle scene;
  these are created unconditionally when native full materialization succeeds.
- Sky3D owns sky, lighting, clouds, fog, and horizon. Terrain3D world background
  is already disabled.

## Feasibility findings

- A meaningful restoration can use Terrain3D as the visible clipmap/heightmap
  renderer while keeping current authority and collision boundaries.
- Exact material code cannot be copied verbatim from `TerrainRenderer`: a
  Terrain3D override must retain Terrain3D's clipmap geomorphing, height-map
  lookup, holes, and normal calculation, then replace only the PBR/material
  portion with the current procedural worksite-soil calculations.
- Terrain3D 1.0.2 officially documents `Terrain3DMaterial.shader_override` for
  custom shaders. Its latest stable release notes cite Godot 4.4-4.6+ support;
  the repository must prove Godot 4.7 behavior rather than assume it.
- Background-only native materialization is technically possible but adds
  native cost and complexity without using Terrain3D for visible terrain or
  physics. It is useful only as a diagnostic migration step, not as the final
  product definition of “online.”

## Primary references

- Terrain3D v1.0.2 release:
  https://github.com/TokisanGames/Terrain3D/releases/tag/v1.0.2-stable
- Terrain3DMaterial shader override API:
  https://terrain3d.readthedocs.io/en/stable/api/class_terrain3dmaterial.html
- Terrain3D shader design:
  https://github.com/TokisanGames/Terrain3D/blob/main/doc/docs/shader_design.md
