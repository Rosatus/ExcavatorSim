# Current excavation and failure evidence

Research date: 2026-09-02.

## Current ownership

- `godot/client/scripts/excavation_world.gd:76-116` composes the current terrain,
  collider, commit scheduler, soil states, tool, and parcel/effects paths.
- `godot/client/scripts/terrain_state.gd:6-38` owns the current stable/loose
  heightfield, generation, and revision.
- `godot/client/scripts/terrain_commit_scheduler.gd:246-332` implements the old
  cell-patch prepare/install/write transaction.
- `godot/client/scripts/soil_interaction_authority.gd:127-255` owns the current
  active material and bucket ledger.
- `godot/client/scripts/bucket_soil_tool.gd:18-150` loads hash-bound bucket
  geometry and produces semantic swept candidates without owning terrain.
- `godot/client/scripts/jolt_chassis_track_runtime.gd:12-18,628-711` owns one
  dynamic chassis, track forces, bounded kinematic equipment, and query-only
  bucket evidence. It is not soil inventory authority.
- `godot/client/scripts/terrain3d_adapter.gd:29-76,98-196` is presentation-only;
  its native collision is disabled in the current product contract.

## Why another heightfield iteration is rejected

- `.trellis/tasks/archive/2026-09/08-31-soil-excavation-redesign/validation.md`
  records two failed manual Forward+ passes: abnormal stutter, very little soil
  removal, and mostly tiny marks, even after focused automated tests passed.
- The rejected path combined semantic classification, raster sweep, material
  reservation, synchronous terrain/collider work, active aggregates, bucket
  cells, and loose-soil flux.
- Product spacing was `0.5 m` while per-cell cut depth and multiple gates favored
  small intermittent changes. One best region was reduced back to a circular
  heightfield brush, losing whole-bucket coverage.
- Logical terrain could advance before presentation/physics had rebuilt, making
  stale collision a recurring interaction problem.
- `arcade_stamp_v3` reduced the hot path and used a 10 Hz coalesced heightfield
  cut, but remained opt-in and still inherited heightfield limits: no vertical
  face, overhang, undercut, or true bucket cavity.

## Reusable boundaries

- Keep the default Godot/Jolt machine authority, accepted fixed-tick
  articulation snapshot, per-model rig descriptors, bucket geometry/calibration
  inputs, selected payload mass/COM interface, generation-based reset policy,
  and bounded presentation effects.
- Replace the heightfield excavation authority, old cut/deposit schedulers,
  active representatives, loose flux, parcel material ownership, old terrain
  collider inside the new work zone, and solver-selection product surface.
- Adapt the surrounding Terrain3D/site generator into an immutable hard-ground
  owner with a voxel-zone hole. Its collision derivative must omit the same
  ownership mask so the seam has one collider per point.

## Site placement evidence

- `godot/client/scripts/terrain_state.gd:42-51` creates the current
  `[-32, 32] x [-32, 32]` site and `(0, 0)` spawn.
- `godot/client/resources/physics/sy205_physics_rig.json:28-29,48-52` plus
  `godot/client/tests/jolt_chassis_track_test.gd:501-508` establish initial +Z
  travel.
- A complete side `32 x 32 m` zone cannot fit inside one half of the current
  64 m site while leaving a nonzero spawn apron. The approved plan therefore
  extends hard terrain toward +Z and relocates conflicting presentation-only
  dressing.

