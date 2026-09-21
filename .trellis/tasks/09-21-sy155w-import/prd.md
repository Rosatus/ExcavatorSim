# SY155W import

User scope: import C:/code/blender/Excavator/SY155W, excluding the supplied bucket;
retain cylinders as passive followers. User confirmed E/U for the intermediate
two-piece-boom articulation. Preserve all unrelated dirty workspace changes.
User correction: do not add a no-tool state; SY155W defaults to existing XTR13 + GB12.

Implementation milestones:
1. Inspect source GLB, scripts and independent source samples; derive a reproducible
   runtime asset without modifying any source file.
2. Register the machine, four authority joints, one local folding axis, passive
   cylinders/four-bar/hoses, and default XTR13 + GB12 mounting.
3. Verify import, independent source poses, pin closure, controls, reset, switching,
   attachments and existing SY135 behavior; render the result for visual review.

Evidence: source-inspection.json; source scripts/build_sy155w.py defines metric
pin geometry, Work_Cycle joint angles, planar four-bar branch and six cylinder pairs.
The GLB animation channels contain absolute local transforms; animated node defaults
are identity, so an animation sample must be materialized before removing clips.
This wheeled two-piece boom uses its own source-derived authority neutral, rather
than imposing the one-piece SY135 zero (which would exceed the supplied cylinder
stroke and hose samples). Independent source equations/samples will verify zero.
Operating ranges initially use the demonstrated source cycle, not claimed factory
hard stops. E/U is presentation-local, matching the existing SY80U boundary.
Wheeled appearance uses existing chassis locomotion initially; automotive steering
physics is outside this import. The blade stays at its source parked pose.

## Delivered

- Reproducible `tools/import_sy155w.py`: materialize source animation frame 91,
  rigidly change semantic pivot coordinates to -Z forward, remove 33 native bucket
  nodes, retain 6 embedded images, 630 meshes and 6 cylinder pairs. Sources untouched.
- Catalog/URDF/physics/fixture/GB12-based soil query contract/provenance added.
  Native physics query coordinates include the measured -0.53 m XTR13 socket offset;
  live soil geometry continues to follow the mounted GB12 tool.
- PassiveHydraulics consumes named pins after active joints, solves the source
  four-bar with continuous branch selection, aligns both cylinder ends and updates
  all 41 weights of each of 12 hoses. Unreachable geometry retains the passive pose.
- E folds / U unfolds, local range -10..+10 degrees relative to source -47 degrees.
  Authority boom/arm/bucket limits are +/-7, +/-9, +/-15 degrees around source
  midpoint. These are demonstrated ranges; broader manufacturer ranges are unverified.
- Catalog declares default XTR13+GB12. SY155W excludes the absent native bucket from
  selection; rejected native requests retain the mounted tool. Existing model defaults
  and attachment controls remain unchanged. SY155W overrides the legacy XTR13
  +130-degree bucket limit shift with zero to preserve its mechanical four-bar.
- Chassis remains the existing provisional skid-steer implementation; wheel steering
  and rolling animation are not adapted. Blade stays parked; its cylinder is retained.
  Folding and attachment axes remain presentation-local, like existing SY80U/XTR13;
  full authority collision/assist responses to those extra axes are not introduced.

## Evidence

- `sy155w_import_test.gd`: independent Blender source samples, all 81 combinations
  of work-joint extrema/midpoints, cylinder pin errors < 0.05 mm, quaternion/morph
  comparisons, unreachable atomic retention and zero restore: PASS.
- `sy155w_session_test.gd`: actual main scene, default XTR13+GB12, soil frame routing,
  E/U equivalent input limits/reset, SY135 return, repeated SY155W activation,
  rejection of absent native bucket: PASS.
- `sy80u_switch_smoke`, `attachment_switch_test`, `attachment_bucket_limits_test`: PASS.
- `backend/tests/backend/test_model_registry.py`: 5 PASS, including actual Pinocchio
  FK against all six SY155W fixture poses and model registry/catalog hashes.
- Ruff on generator and changed backend test: PASS. verify-provenance: PASS.
- Real Godot Compatibility renders: `preview/overview.png`, `side.png`, `hydraulics.png`.
  Assistant inspected materials, whole-machine proportions, mount and cylinder alignment.
  Human visual/handling acceptance remains available for review; no production realism claim.
- Existing editor/headless warnings about terrain texture UIDs, deprecated interpolation
  and editor resource cleanup are unrelated to this asset. Runtime focused tests have
  no SY155W script errors. No commit made; unrelated user changes preserved.

Next: user can select SANY SY155W in the model selector and review E/U folding and
normal work-equipment controls. Restart the existing editor/game to avoid cached assets.

## Repair cycle (repaired Blender source)

Source-first rule (user): fix `build_sy155w.py`/`SANY_SY155W_Repaired.blend` first,
export, then regenerate project assets; never patch only the runtime GLB.

- Repaired source `C:/code/blender/Excavator/SY155W/SANY_SY155W_Repaired.blend` adds
  ~304 repair objects (cylinder lugs/trunnions, cab lower walls, deck closure,
  boom-root supports, handrail feet, exhaust/lettering seats, hydraulic lines as
  curves). Source repair report: cylinder endpoint error < 2e-6 m, four-bar error
  < 1e-6 m, zero collision samples.
- `scripts/export_repaired.py` exports with curves converted to meshes;
  `normalize_glb_time.py` keeps frame 1 at t=0 (4 input accessors shifted by 1/30 s).
- Blender 5.2 export warnings about duplicate channels on BUCKET_COUPLER,
  BUCKET_ROCKER, BUCKET_CYLINDER_* are harmless: the importer strips all
  AnimationPlayers; passive motion is re-solved at runtime.
- Contract changes in `tools/import_sy155w.py` (verified against independent source
  samples, variance < 1e-5 across frames): articulation cylinder relocated under
  the boom base (0.50,0,-0.36 -> 0.78,0,-0.43); stick cylinder rides on the boom-top
  lug (0.59,0,0.54 -> -0.60,0,0.18); bucket cylinder base (0.26,0,0.40) -> rocker tip
  (0.32,0,0); blade cylinder (-1.80,0,0.86 -> -0.4235,0,-0.02); four-bar rocker pivot
  z 0.18->0.36, bucket pin -0.22->+0.22, coupler length 0.43->0.48 m.
- Runtime GLB regenerated: 1324 nodes / 795 meshes / 6 cylinders / 12 hoses.
- `tools/audit_sy155w_geometry.py` global nearest-neighbor audit: 0 mesh candidates
  with gap > 0.03 m (was: SANY lettering 8.4 cm, exhaust 3.1 cm, grille fins etc.).

### Evidence (this cycle)

- `sy155w_import_test.gd`: PASS (source oracle, 81 poses, 6 cylinders, 12 hoses,
  unreachable atomic retention, zero restore).
- `sy155w_session_test.gd`: PASS (default XTR13+GB12, soil routing, E/U limits,
  SY135 return).
- `backend/tests/backend/test_model_registry.py`: 5 PASS. Ruff: PASS.
  verify-provenance: PASS.
- Fresh renders `reports/sy155w_preview/{overview,side,hydraulics}.png` reviewed:
  boom-lift cylinder supports seated, closed upper deck, solid cab lower walls,
  handrail posts landed, linkage/coupler tracking.

### Environment note

`tools/godot_voxel_toolchain.json` `default_root` is `E:/applications/godot_voxel`,
absent on this machine. The identical pinned binary (sha256
4aa32de0...d7749c3, version 4.7.2.stable.custom_build.ed1daf0bf) is installed at
`C:/apps/godot_voxel`; use `GODOT_VOXEL_ROOT=C:/apps/godot_voxel` or `--godot-exe`.
After regenerating the GLB, run `--import` once (or restart the editor) — headless
`--script` runs served a stale `.godot/imported` cache until reimported.

No commit made; unrelated dirty workspace preserved.
