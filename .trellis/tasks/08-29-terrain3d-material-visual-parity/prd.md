# Terrain3D procedural soil visual parity

## Goal

Make native Terrain3D reproduce the current project-owned brown worksite-soil
look without Terrain3D demo grass, green ground, rocks, particles, trees, or
world background.

## Dependency

Phase 0 `08-29-terrain3d-forwardplus-render-spike` must have a completed
non-black Forward+ exit gate and a documented supported shader/material seam.

## Requirements

- Build a project-owned Terrain3D shader override from the compatible minimum
  or generated base shader; preserve all required clipmap/height/LOD/normal code.
- Port current procedural classifications and tuned constants from
  `TerrainRenderer`: compacted, loose/disturbed, slope, damp center, track lane,
  macro breakup, distance response, roughness, and specular.
- Extract shared material constants/functions when practical so native and
  fallback implementations cannot silently drift.
- Remove product reliance on Terrain3D demo ground/grass textures and control
  zones. Do not reclassify shader color as soil material truth.
- Add explicit product controls/status for native dressing and keep grass,
  rocks, trees, foliage, and infinite background off.
- Preserve Sky3D, sibling `ConstructionSiteDressing`, soil effects, camera/UI,
  quality budgets, Test Grid, and fallback material.
- Do not alter snapshot, collider, Jolt, soil, payload, or terrain revision paths.

## Acceptance Criteria

- [x] Native Terrain3D renders the same recognizable compacted/loose/damp brown
  worksite-soil language as fallback under the same camera/daylight checkpoint.
- [x] Terrain deformation changes native shading consistently with current
  height/slope/disturbed behavior.
- [x] No native grass particles, green ground region, rock/tree/foliage layer,
  or infinite Terrain3D background appears.
- [x] Sky3D horizon, shared site cues, soil effects, camera, UI, and low/balanced/
  high budgets remain unchanged.
- [x] Automated checks prove shader identity, dressing exclusions, background
  off, and no mutation of TerrainState/ledger/payload.
- [ ] Focused human review accepts native/fallback visual parity. Exact pixels
  and identical LOD normals are not required.

## Out of Scope

- Snapshot lifecycle hardening, collider changes, product default cutover,
  editor painting, texture authoring, or a new visual art direction.
