# Rolling implementation

## Current milestone
Build a sparse off-zone SDF layer, under the existing soil authority, with static
support sampling, repose deposits, native swept recutting, shared namespaced ledger,
and derived chunk mesh/collision. Use VoxelBuffer + VoxelMesherTransvoxel directly
for sparse chunks: no per-pile authority and no asynchronous empty-terrain loading.
Ground is immutable and unaccounted. Only deposits initialize pile-cell mass.

## Following milestones
1. Authority dump/cut routing and lifecycle integration.
2. ProductSession/UI persisted switch and diagnostics.
3. Focused native Godot tests: mass, re-cut, physics, toggles, real maps; regression
   tests for existing material/voxel behavior. Read-only independent review.

## Progress
Research complete. Existing single-zone authority and implicit native-cell defaults
must remain unchanged for original soil. New sparse-layer changes carry region_id.
Unrelated CAN/SY155W and map-spawn working changes are preserved. User authorized batched commits and push on 2026-10-13; human acceptance remains pending.

## Implemented checkpoint
- Added `OffzoneSoilLayer`: sparse world-aligned 16^3 SDF blocks at 0.125m,
  native Transvoxel meshes and trimesh static collision, repose planning and
  native bucket swept paths. Original ground is never part of the mass ledger.
- Existing authority owns admission/gates, 100ms off-zone batches, ledger and
  release events. Explicit `offzone` mutation keys isolate soil coordinates.
- Original cutter disables grade-based overburden cleanup in deposited-only mode.
- Runtime recognizes pile colliders as voxel support for track and wheel queries.
- Advanced `区外堆土（可挖掘、可行驶）` preference persists; training disables this
  control and keeps export behavior. Disabling preserves existing piles. Simple
  digging closes all dump gates. Generation teardown retires the layer.
- Re-cut reclaims abandoned buffers and support caches; cut never allocates air.

## Agent automated evidence (2026-10-13)
Native Godot headless logs under `artifacts/offzone-soil/`:
- `offzone_soil_layer_test`: PASS, 0.5m3 deposit, seam mesh/collision, dynamic body,
  native recut restores all mass, repeated cut cannot mine road, storage reclaimed,
  overlapping deposits and missing support retain/conserve material.
- `offzone_soil_maps_test`: PASS, both real packs, pose-admitted unloading and
  actual bucket-tool recutting, conserved ledger, simple gate, switch and teardown.
  SY135 track support 95/94 frames and 3.13/0.87m driving (urban/construction).
  Representative common operations ~2–4ms; not an exhaustive performance guarantee.
- `menu_preferences_test`: PASS including theme and map reload pile preference.
- `voxel_soil_material_field_test`, `voxel_bucket_cutter_test`,
  `voxel_excavation_authority_test`: PASS; original voxel regression preserved.
- Read-only review identified and resolved leaked empty blocks, training UI mismatch,
  actual track support ownership, and unsafe native-soil foundation at map seam.

## Explicit current limitations / human manual
- Overlay deposition stops at original voxel rectangle; it cannot spread onto
  mutable native soil until support-change settlement is implemented. Native
  in-zone dumping remains unchanged. Boundary test verifies retained ownership.
- Quasi-static repose deposition, no continuous granular collapse/settling after
  undercutting, matching the existing stable-soil model. Sparse block and sample
  limits retain unaccepted bucket stock. First large load may exceed common timings.
- Only exposed static map ground receives soil, not props/vehicles/roofs. Ground
  height caching is bounded; source obstruction is freshly queried per deposit.
- Pending human Forward+ review: restart client, select urban/SY135, Advanced enable
  pile mode, dig strip, unload on open adjacent road twice, re-excavate then drive
  over remaining mound. Inspect material/contact edges and operator feel; repeat
  on construction ground. Workbench does not display runtime piles.
- No map pack rebuild needed (all changes are client runtime). Included in the user-authorized batched source delivery; human acceptance remains pending.
