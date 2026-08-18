# Scope: Hybrid Jolt Authoritative Simulation

## Authority Matrix

| State | Current owner | Target owner | Migration rule |
|---|---|---|---|
| Chassis pose and velocity | Profile-selected Godot controller/Jolt body | Godot/Jolt dynamic chassis | Jolt is the only chassis writer in authoritative mode |
| Slew/boom/arm/bucket state | Python kinematics or Phase 2 Jolt prototype | Godot fixed-step kinematic articulation | One state machine owns joint integration and FK; no physics joint motors |
| Work-equipment visual frames | MotionPresentation | MotionPresentation from accepted kinematic snapshot | Presentation consumes frames and never writes authority |
| Bucket collision proxies | Phase 2 bucket rigid body / logical soil proxies | FK-driven bucket-only sweep/contact adapter | Intermediate links do not collide with terrain |
| Input safety/lifecycle | Python InputRouter/runtime | Godot reducer for local authority; Python gateway for external ingress | Preserve sequence, zero-arm, lease, and epoch semantics |
| Terrain stable/loose layers | Godot TerrainState | Godot TerrainState | Remains semantic authority |
| Bucket inventory | Godot BucketSoilState | Godot BucketSoilState | Payload influences kinematic response through one bounded adapter |
| Chassis ground reaction | Jolt chassis plus legacy heuristic in non-authoritative modes | Jolt chassis plus capped bucket-contact wrench | No transform offset or uncontrolled kinematic pusher |
| Terrain rendering/collision | TerrainRenderer/Terrain3D/derived collider | Same, with tick-safe collider transaction | Never infer terrain volume from renderer data |
| Runtime truth export | Python view_state / Phase 2 five-body truth | Godot hybrid state publisher -> Python gateway | Dynamic body and kinematic frame semantics are explicit |
| Sensor samples | Not implemented | Godot truth/sensor producers -> Python gateway | Shared tick/time/frame identity |
| Replay/recording | Legacy Python | Legacy retained; new telemetry recording is separate | No promise of contact-deterministic replay |

## In Scope

- A profile-gated Godot simulation core for SY205/SY135.
- One dynamic chassis body with simplified multi-point crawler traction.
- Four fixed-step kinematic joints with position, velocity, acceleration, braking,
  optional jerk, joint-limit, and load-response tuning.
- FK-derived visual frames and bucket-only cutting/shell/support collision proxies.
- Continuous contact/sweep classification and a capped equivalent wrench applied
  to the dynamic chassis without a second chassis writer.
- One identity-tagged TerrainState/BucketSoilState excavation transaction.
- Versioned hybrid state/sensor egress and Python validation/recording/gateway
  services.
- Lifecycle, model-switch, stale-terrain, invalid-asset, and rollback contracts.
- Performance and live-contact acceptance on the existing Windows desktop target.

## Out Of Scope

- Dynamic rigid bodies for upper, boom, arm, or bucket in the product profile.
- Physics hinge motors, link mass/inertia tuning, full articulated momentum
  exchange, and automatic payload COM transfer through a rigid-body chain.
- Replacing TerrainState/BucketSoilState with Terrain3D edits or per-grain physics.
- Modeling every track shoe, hydraulic circuit, hose compliance, engine, pump,
  structural flexibility, or component wear.
- Production hardware drivers or a certified training/engineering model.
- Removing legacy runtime, recording, replay, or Pinocchio code before cutover.

## Compatibility Boundary

- `python_kinematic` remains behavior-compatible with the current v3 path.
- `jolt_shadow` publishes diagnostics only and cannot write product transforms.
- `jolt_authoritative` becomes the hybrid dynamic-chassis/kinematic-articulation
  profile and uses a versioned state contract.
- The archived Phase 2 five-body runtime is not silently selected as fallback.
- Profiles rebuild state on switch; hot-swapping authority beneath an established
  session is forbidden.
- Invalid authoritative descriptor/profile selection fails explicitly or returns
  only through a user-selected legacy profile.

## Fidelity Target

The target is convincing operator training/gameplay response: believable joint
inertia from motion shaping, crawler traction, support, load slowdown, contact
resistance, machine lift/tilt, and sensor coherence. Values remain tuneable and
evidence-labelled until measurements are available. Engineering-grade articulated
dynamics and hydraulic certification are separate future programs.
