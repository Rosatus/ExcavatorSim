# Scope: Jolt Authoritative Simulation

## Authority Matrix

| State | Current owner | Target owner | Migration rule |
|---|---|---|---|
| Chassis pose and velocity | Godot kinematic controller | Godot/Jolt physics core | Replace direct transform writes in Jolt mode |
| Slew/boom/arm/bucket state | Python Simulator + Pinocchio | Godot/Jolt joints + actuator layer | Python may observe, never overwrite |
| Input safety/lifecycle | Python InputRouter/runtime | Godot reducer for local authority; Python gateway for external ingress | Preserve sequence, zero-arm, lease, epoch semantics |
| Terrain stable/loose layers | Godot TerrainState | Godot TerrainState | Remains semantic authority |
| Bucket inventory | Godot BucketSoilState | Godot BucketSoilState | Payload feeds physics through one bounded adapter |
| Contact/ground reaction | Heightfield heuristics and visual offsets | Jolt body/contact state | No network feedback loop |
| Terrain rendering/collision | TerrainRenderer/Terrain3D/derived collider | Same, with tick-safe collider transaction | Never infer terrain volume from renderer data |
| Runtime truth export | Python view_state | Godot state publisher -> Python gateway | New versioned contract |
| Sensor samples | Not implemented | Godot truth/sensor producers -> Python gateway | Shared tick/time/frame identity |
| Replay/recording | Legacy Python | Legacy retained; new telemetry recording is separate | No promise of contact-deterministic replay |

## In Scope

- A profile-gated Godot simulation core and Jolt physics rig for SY205/SY135.
- Simplified multi-point crawler traction on one physical chassis body.
- Physical slew/boom/arm/bucket joints with bounded actuator response.
- Convex/compound collision proxies kept separate from visual GLBs.
- Jolt contact summaries coupled to the existing logical soil and payload model.
- Versioned state/sensor egress and Python validation/recording/gateway services.
- Lifecycle, model-switch, stale-terrain, invalid-asset, and rollback contracts.
- Performance and live-contact acceptance on the existing Windows desktop target.

## Out Of Scope

- Replacing TerrainState/BucketSoilState with Terrain3D edits or per-grain physics.
- Modeling every track shoe, hydraulic circuit, hose compliance, engine, pump,
  structural flexibility, or component wear.
- Treating provisional URDF mass/inertia/collision data as production validated.
- Production hardware drivers or a certified training/engineering model.
- Removing legacy runtime, recording, replay, or Pinocchio code in the first five
  phases.

## Compatibility Boundary

- `python_kinematic` remains behavior-compatible with the current v3 path.
- `jolt_shadow` publishes diagnostics only and cannot write product transforms.
- `jolt_authoritative` is a separate negotiated profile with a new state contract.
- Profiles rebuild state on switch; hot-swapping authority beneath an established
  session is forbidden.
- Invalid Jolt rig/profile selection fails explicitly or returns to a user-selected
  legacy profile. It never silently mixes Python articulation with Jolt chassis.

## Fidelity Target

The target is convincing operator training/gameplay response: believable inertia,
traction, support, load slowdown, contact resistance, and sensor coherence. Numeric
parameters remain tuneable and evidence-labelled until machine measurements are
available. Engineering certification is a different future program.

