# Construction starter foundation pit

## Goal
Construction map's voxel work zone starts as a believable half-excavated
foundation pit instead of flat grade. South half (spawn/approach side, local
-Z) is a pit; north half stays at grade as the remaining dig area.

## Requirements
- Pit floor ~3 m below the -0.02 m datum; gentle full-width access ramp on the
  south side (machinery drivable, ~19 deg), moderately sloped side walls,
  steep dig face at the midline (the "current dig").
- The 1.5 m perimeter rim stays level with the surrounding grade (edges flush).
- North half surface exactly at grade.
- Shape lives in the shared `voxel_pit_generator.gd` as a parameterized
  profile; `depth_m = 0` must remain a flat surface (training unchanged).
- `starter_pit` bool is replaced by `starter_pit_depth_m` (0 = flat).
- Soil shader tints below-grade soil as subsoil on the grade datum (pit
  interior reads as excavated ground).
- Reset regenerates the same pit.

## Acceptance
- New profile unit test: rim level, north half flat, floor -3 m, monotonic
  ramp, steep face, outside apron at grade.
- `construction_voxel_test.gd` interior scan validates the generated surface
  against the profile (rays hit voxel soil, not Terrain3D remnants).
- `voxel_soil_surface_material_test.gd` updated to new depth semantics.
- `voxel_work_zone_seam_test.gd`, `voxel_work_zone_scene_test.gd` still pass.
- Spec `optional-map-packs.md` and workbench README updated.

## Files
- godot/client/scripts/voxel_pit_generator.gd (rewrite profile)
- godot/client/scripts/voxel_work_zone.gd (export, probe expectation, material)
- godot/client/assets/terrain/shaders/voxel_soil_bounded.gdshader (grade datum)
- godot/client/scripts/main_map.gd (enable 3.0 m starter pit)
- godot/client/tests/{construction_voxel_test,voxel_soil_surface_material_test}.gd
- godot/client/tests/voxel_starter_pit_profile_test.gd (new)
- godot/worldbuilding/construction/README.md, .trellis/spec/frontend/optional-map-packs.md

## Implementation checkpoint (2026-09-26)

Done and verified headless:
- `voxel_pit_generator.gd` rewritten: piecewise-linear profile, constants
  PERIMETER_LEVEL_M 1.5 / PIT_FLOOR_Z_SPAN_M 8.0 / DIG_FACE_RUN_M 0.5 /
  SIDE_WALL_RUN_M 0.5. Ramp 1.5 m over 4 m (~21 deg constant grade, full
  width — the only non-steep slope); dig face and side walls ~72 deg cut
  faces; 8 m flat floor parks a whole machine; depth 0 = flat.
- `VoxelWorkZone.starter_pit_depth_m` (0-5 m) replaces the bool; generator
  depth assigned at build; surface probe uses `surface_height_m(0,0)` (midline
  stays at grade, so the centre probe is unchanged).
- Pit depth travels as map data: `WorkArea/ExcavationArea` meta
  `starter_pit_depth_m = 1.5`; `main_map.gd` reads the meta — training and
  future maps without it stay flat.
- `ground_runtime.gd` fix: Terrain3D control-map holes now also trigger
  `collision.update()` — the native collider previously kept stale triangles
  (masked by exact-height ties against flat voxel soil; the pit exposed them).
- `voxel_soil_bounded.gdshader`: starter-profile code removed; subsoil tint
  follows `initial_surface_y - soil_world.y` (original grade datum).
- `construction.pck` rebuilt (822,506,808 B, includes WorkArea meta, ground
  fix and the 84 track-node deletion).

Tests (all headless, pinned Godot voxel toolchain):
- voxel_starter_pit_profile_test: PASS
- voxel_soil_surface_material_test: PASS
- construction_voxel_test: PASS (profile scan, cut/dump, track support,
  reset regenerates pit, automatic operator cut, map switch)
- voxel_work_zone_seam_test / voxel_work_zone_scene_test: PASS
- voxel_excavation_authority / voxel_excavation_world / voxel_lift_exit /
  soil_deposit_surface: PASS

Pending: human visual acceptance of the pit (drive the ramp, dig face) in the
running client — spec keeps that step human-owned.

