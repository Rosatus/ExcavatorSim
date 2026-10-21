# Terrain3D procedural-soil parity result

## Objective gate

The retained real-frame run is
`output/terrain3d_phase1/20260829-180331/`. Its isolated Windows run selected
Godot 4.7.1, Forward+, D3D12, and the AMD Radeon RX 9070 XT. `run-summary.json`
reports `passed=true` and `fatal_log_matches=[]` after scanning import and probe
stdout/stderr/Godot logs.

The native and fallback paths now call the same
`worksite_soil_common.gdshaderinc` implementation for compacted, loose/slope,
damp-center, track-lane, macro-distance, roughness, and specular response. The
native shader retains Terrain3D 1.0.2's minimum clipmap, geomorph, height, hole,
and normal seam. The adapter exposes the project material and shader identity,
world background off, demo texture sampling off, and all native demo dressing
classes off.

The fixed 960x540 probe produced:

- native brown ratio `1.0` before and after the edit;
- fallback brown ratio `0.8060` before and after the edit;
- native deformation changed ratio `0.0013194`;
- fallback deformation changed ratio `0.0011285`;
- identical terrain epoch/generation/revision/SHA-256 from immediately after
  the intentional revision-1 deformation through every native/fallback capture;
- main-scene product contract still `terrain_backend="soil_shader"` with
  Forward+/D3D12.

Terrain3D 1.0.2 displayed its missing-material checker when given an empty
`Terrain3DAssets`, even with a valid shader override. The final path therefore
retains the two provenanced official texture slots strictly as enter-tree
initialization inputs. The project override does not declare or sample the
texture arrays, every control-map cell selects the single procedural role, and
production creates no demo rocks or particles.

Test Grid no longer assigns `Terrain3D.material=null`; it hides the native node
and lets the fallback renderer own the grid. This preserves the cached live
material identity and eliminates the Godot 4.7 D3D12 null-material RID errors
observed by the first Phase 1 probe attempt.

## Passing focused checks

- `construction_site_terrain_test.gd`
- `terrain3d_adapter_test.gd`
- `terrain_state_test.gd`
- `visual_pass_test.gd`
- `soil_authority_migration_test.gd`
- `soil_interaction_authority_test.gd`
- `release_candidate_test.gd`

The focused human comparison of `worksite_native_after.png` and
`worksite_fallback_after.png` was accepted by the user on 2026-08-29. Pixel
identity is not expected because Terrain3D uses clipmap LOD normals and the
fallback uses a finite ArrayMesh. The probe records `native_fallback_after` for
review but does not turn that cross-backend pixel distance into an automatic
pass threshold; the automated gate instead proves both paths independently
render brown, nonblank, height-varying terrain and respond to the same logical
deformation.
