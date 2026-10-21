# AGX Terrain and Terrain3D Assessment

## Sources

- [AGX Terrain user manual](https://www.algoryx.se/documentation/complete/agx/tags/latest/doc/UserManual/source/agxTerrain.html)
- [AGX Terrain Shovel API](https://www.algoryx.se/documentation/complete/agx/html/doc/html/classagxTerrain_1_1Shovel.html)
- [Terrain3DData 1.0.2 API](https://terrain3d.readthedocs.io/en/stable/api/class_terrain3ddata.html)
- [Terrain3D 1.0.2 collision guide](https://terrain3d.readthedocs.io/en/stable/docs/collision.html)
- [Terrain3D 1.0.2 technical tips](https://terrain3d.readthedocs.io/en/stable/docs/tips_technical.html)

## AGX Findings

- AGX stores solid terrain mass in a 3D grid while presenting the surface as an updated heightfield.
- A configured shovel body, cutting edge, top edge, and cutting direction creates an active zone that converts intersected solid mass into dynamic particles/fluid mass.
- Dynamic particles have 6-DOF contact dynamics, but the shovel coupling is kinematic. Particle contacts are not the sole direct feedback path; aggregate rigid bodies constructed from active-zone mass provide resistance.
- AGX distinguishes mass inside the shovel inner body from wedge mass in the active zone.
- Dynamic soil merges back into the terrain near steady state. Particle size/count and solver iterations are explicit performance/fidelity controls.
- Therefore the mature pattern is hybrid and mass-ledger-driven. “Delete terrain and let thousands of independent particles decide everything” is not an accurate summary of AGX.

## Terrain3D Findings

- The current project uses Terrain3D 1.0.2.
- `Terrain3DData.set_height/set_pixel` modify existing region maps. For many pixels, the official API recommends retrieving the region map image and editing it directly.
- After editing, `update_maps(map_type, all_regions, generate_mipmaps)` refreshes texture arrays. With `all_regions=false`, only regions marked edited are regenerated.
- Terrain3D supports runtime destructibility, but collision may require regeneration when dynamic collision is not enabled.
- Terrain3D's clipmap mesh is generated once and vertex height is read from height textures in the GPU shader. The project should update data textures rather than repeatedly replacing the terrain node or importing all source images.
- The API promises edited-region refresh, not an arbitrary pixel-subrect GPU upload. Planning should use honest region-level semantics.

## Current Code Findings

- `JoltChassisTrackRuntime` currently combines real rigid-body terrain contact with independent ray traction and saturated yaw assistance (`godot/client/scripts/jolt_chassis_track_runtime.gd:699`, `:720`, `:753-762`).
- Chassis spawn clearance is only a few centimeters above the terrain (`godot/client/scripts/tracked_chassis_controller.gd:533`), increasing contact correction sensitivity.
- `Terrain3DAdapter.queue_snapshot()` hides native terrain immediately (`godot/client/scripts/terrain3d_adapter.gd:70-90`). Every revision then calls `import_images` and rebuilds dressing (`:197-252`, `:280`).
- `TerrainCommitScheduler` always fans a full snapshot to all derivatives (`godot/client/scripts/terrain_commit_scheduler.gd:124-132`), and the custom collider builds a complete replacement body (`godot/client/scripts/terrain_collider.gd:80`).
- Cutting currently credits terrain brush volume directly to `BucketSoilState` after commit (`godot/client/scripts/bucket_soil_state.gd:181-216`).
- The fill mesh is rebuilt along bucket-local Y and then attached to the cavity transform (`godot/client/scripts/soil_effects.gd:183-206`, `:311-339`), so its surface rotates with the bucket rather than remaining aligned with world gravity.
- Existing clods are visual pooled bodies and do not own terrain/bucket volume (`godot/client/scripts/soil_effects.gd:239-290`).

## Recommendation

1. Use one ray/shape support and traction model for the single dynamic chassis; retain the hull only for safety/obstacles.
2. Introduce dirty terrain bounds, keep the last native terrain visible, patch existing Terrain3D region images, and swap only dirty collider chunks.
3. Keep `TerrainState` and `BucketSoilState`, but add a bounded volume-carrying dynamic parcel layer and a parcel-only moving bucket shell. Let physics determine which parcels cross into or out of the cavity while the ledger preserves capacity and mass.

