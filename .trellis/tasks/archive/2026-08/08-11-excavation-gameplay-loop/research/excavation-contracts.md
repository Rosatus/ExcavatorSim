# M5 research notes

- Parent M5 exit requires deterministic bucket dig/deposit, clean reset,
  optional static colliders and operation when local physics is unavailable.
- `TerrainState` provides stable/loose Float32 layers, monotonic brush commands,
  fixed-step revision and generation reset. Its surface is always stable+loose.
- The legacy Python excavation implementation provides useful semantic constants
  (`0.35 m^3` capacity, `0.08 m` cut depth, `0.20 m` tooth radius, `0.75 m`
  deposit radius, `0.12 m` contact tolerance, `0.15 m` dump clearance), but is
  not a Godot authority or a wire contract.
- The supplied SY205 manifest exposes bucket pivots but no teeth markers or
  collision resources; M5 therefore uses explicit local proxy offsets.
- Godot motion presentation remains the consumer of Python frame transforms;
  local terrain/bucket/collider state is never sent back through MotionClient.
