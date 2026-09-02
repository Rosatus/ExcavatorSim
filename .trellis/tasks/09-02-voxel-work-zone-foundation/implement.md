# Implement - work-zone foundation

- [ ] Verify the connected Godot custom editor and inspect actual v1.7 resource
  properties through Godot AI MCP before authoring scene resources.
- [ ] Add the isolated API/collision/readiness probe and focused runner.
- [ ] Update `client-boundary.md` with the transitional hard-ground/voxel
  ownership and support contract, explicitly removing heightfield fallback from
  the voxel-zone mask.
- [ ] Add centralized config and coordinate/bounds conversion tests.
- [ ] Run the two-candidate bucket-sized benchmark once after the probe is
  stable; write selected scale and budgets into validation evidence.
- [ ] Add the runtime work-zone wrapper, generator, mesher, material, viewers,
  readiness tickets, statistics, and reset lifecycle.
- [ ] Extend/mask Terrain3D, fallback rendering, and hard collision with the same
  ownership function; add retaining boundary and entrance.
- [ ] Relocate presentation-only dressing that conflicts with the approved zone.
- [ ] Run parser/import, API probe, seam, reset, initial collision, and pristine
  traversal checks. Edited probe geometry must change the expected Jolt query
  result before its readiness ticket is accepted. Do not run the full matrix.
- [ ] Ask the user for one focused Forward+ foundation review. Keep the result
  pending until explicitly reported.
- [ ] Update frontend spec with the selected Voxel Tools configuration and
  collision-readiness contract before committing/archiving this child.

Risky rollback points are the Terrain3D hole mask and hard collider ownership.
Any sampled double/missing collider blocks child completion.
