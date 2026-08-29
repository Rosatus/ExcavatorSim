# Interaction-boundary research

## Confirmed authority split

- Terrain3D is presentation-only. Product collision/query truth remains the
  project `TerrainCollider` plus `TerrainState` heightfield fallback
  (`.trellis/tasks/archive/2026-08/08-29-restore-terrain3d-visual-parity/design.md`).
- The product-default Jolt path has one dynamic chassis and bounded kinematic
  work equipment. The bucket is not a rigid body. Bucket/ground collision is a
  `BucketProxySweeper` space query whose accepted fraction clamps articulation
  and may queue a chassis support wrench
  (`godot/client/scripts/jolt_chassis_track_runtime.gd:464-525,688-826`;
  `godot/client/scripts/bucket_proxy_sweeper.gd:72-139`).
- Track and chassis ground support is independent: terrain-layer ray queries
  fall back to `TerrainState`, then apply distributed support/traction forces
  (`godot/client/scripts/jolt_chassis_track_runtime.gd:840-883,1089-1143`).
  Therefore bucket interaction can be bypassed without disabling the shared
  terrain collider or making the machine fall through the world.
- Cutting is not arbitrated by the bucket query. `ExcavationWorld` samples the
  authoritative heightfield and classifies logical penetration; Jolt also
  probes cut penetration separately for work-equipment resistance
  (`godot/client/scripts/excavation_world.gd:523-599,602-735`;
  `godot/client/scripts/jolt_chassis_track_runtime.gd:489-505`). Both must be
  gated in addition to collision-query acceptance.

## Soil workload and bypass boundary

- `automatic_soil_enabled` is insufficient. It only guards automatic pose to
  interaction-batch processing, while `active_patch` still steps every physics
  tick (`godot/client/scripts/excavation_world.gd:96-109`).
- `SoilInteractionAuthority.step_fixed()` consumes settlement, captures active
  material, releases bucket contents, cuts/activates terrain, scoops, settles
  bucket cells, steps the active patch, and consumes settlement again
  (`godot/client/scripts/soil_interaction_authority.gd:121-157`).
- The likely dominant avoidable work is active-patch representative integration
  and neighborhood processing (up to 320/800/1600 representatives by quality),
  plus synchronous persistent-field commits, full surface copies, derived
  terrain refresh, and dirty collider chunk rebuilds
  (`godot/client/scripts/active_soil_patch.gd:12-40,380-396,504-654`;
  `godot/client/scripts/active_soil_persistent_field.gd:168-188`;
  `godot/client/scripts/terrain_commit_scheduler.gd:132-191`;
  `godot/client/scripts/terrain_collider.gd:148-242`).
- `SoilEffects` continues snapshot/fill/clod work even when emission is disabled,
  so the new mode needs a top-level pause/bypass path rather than only setting
  particle budget to zero (`godot/client/scripts/soil_effects.gd:36-67,229-390`).

## Recommended ownership

- Add one explicit bucket-ground interaction policy owned by the gameplay
  session/`ExcavationWorld`, with adapters into the Jolt runtime and soil
  presentation. Do not overload Terrain3D backend, visual quality, soil owner
  (`legacy|shadow|active_patch`), or authority profile.
- When disabled, skip bucket proxy space queries, articulation clamping, support
  wrench creation/application, cut-resistance probing, soil classification,
  authority/patch stepping, terrain commits caused by bucket material, parcel
  work, and dynamic soil effects. Keep terrain rendering/collider identity and
  track/chassis support live.
- Keep lifecycle identity and lightweight status updates alive. On transitions,
  clear pending bucket support requests and stale interaction batches so no
  pre-toggle result applies after the boundary.
- Ordinary mode remains the default and retains all current behavior.

## Lifecycle constraint

- Soil owner changes are generation-locked and in-flight material is not
  migrated (`godot/client/scripts/soil_authority_mode_controller.gd:4,36-75`;
  `.trellis/tasks/archive/2026-08/08-24-gameplay-soil-interaction-rebuild/design.md:127-130`).
- Existing `set_automatic_soil_enabled()` calls `_clear_local_material()`, which
  clears legacy and active bucket contents and starts a new material generation
  (`godot/client/scripts/excavation_world.gd:226-230,1185-1212`). It must not be
  reused unchanged for a non-destructive runtime toggle.
- The initial conservative recommendation was to freeze payload and resume the
  same ledger on exit. The user explicitly rejected that preservation cost and
  accepted destructive clearing. The final contract therefore clears bucket,
  active/released material, parcels, and pending work at mode entry, creates a
  new empty material generation, and never restores the discarded payload.
  Reset/model-switch/reconnect retain their existing clean-generation semantics.
