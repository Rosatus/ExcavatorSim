# Extend urban excavation strip behind vehicle

User wants the sidewalk on the voxel side cleared toward the vehicle's rear,
with matching voxel soil and roadwork-barrier extension. Added length is three
times the old strip length (15.8 m), so add 47.4 m toward +X; total 63.2 m.
Editor inspection confirms saved vehicle heading +90 degrees / -X, hence rear +X.

Target bounds: X 23.8..87.0, Z 27.45..33.0, unchanged grade 1.1 and width5.55.
New centre (55.4,1.1,30.225). Preserve spawn, flat initial soil, buildings and
their plinths, road surfaces, unrelated edits (including foliage shader).

Implementation: extend source marker/ground visual cutout/collision hole,
regenerate merged sidewalk trim, remove matching sidewalk/planter/vegetation
and collisions from added corridor, extend existing roadwork barrier row.
Rebuild both packs and verify real packed soil/collision coverage, source
geometry removal and surrounding support. Inspect editor result after safe
reload; subjective appearance remains user-reviewed.

Progress: implemented, rebuilt, validated, and reloaded the open editor scene.

- WorkArea now centre55.4, length63.2; shader maxX87; east collision frame
  size498 centre(local)351, starting exactly at worldX87.
- Trim tool now subtracts the full XZ rectangle with interpolated boundary
  vertices; generated .res updated. Road material surface retained.
- Removed28 audited whole scene instances including their collisions,
  420 shrubs and2 trees (includes foliage from entire removed B7 planter).
  Existing building modules and378 plinths preserved.
- Added40 roadworkBarrier panels at existing Y/Z/orientation; endpoint
  X88.9655, exactly47.4m after original endpoint41.5655.
- Real rebuilt urban pack test PASS: continuous new corridor support,
  inside/outside seams, full interior profile, no sidewalk triangle overlap,
  foliage clearance, barrier count/end, far-end native cut and reset.
  Log artifacts/urban-map/extension-final-test{,.err}.log; no engine errors.
  Initial test incorrectly required old X25 prop-occupied cells to be bare;
  corrected new-corridor range39..86, retaining full-interior profile test
  which intentionally skips authored props. Failed evidence retained.
- Source review found no blocking defect. Scoped diff check passed.
- Godot AI editor scene reloaded and read back centre/size and65 barriers.
  Editor warnings are resource UID path fallbacks; no logged errors.
- Both runtime pack copies rebuilt. No release executable rebuild required
  for map-only changes; start client to view generated voxel surface.

Next: user visually reviews workbench clearing/barriers and runtime soil.
No visual-quality claim; implementation and objective checks complete,
uncommitted. Existing unrelated changes preserved.

## User-requested export and publication

2026-10-13: saved the user's current open Urban-City scene via editor MCP,
then ran full urban import/build. Both PCK copies have SHA256
80f90e2dceab26942a8089adaf43b7e445e5961a6445550965357cc8fd608159.
The editor reserialized the trimmed mesh; final real-pack urban_voxel_test
passes (artifacts/urban-map/export-final-test logs). User authorized grouped
commits and push. Scope is this conversation's map work plus current urban
manual edits; unrelated CAN/SY155W and pre-existing spawn work stays local.
