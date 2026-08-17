# Godot 4.7.1 Jolt Capability Probe

Observed locally on 2026-08-17 with
`Godot_v4.7.1-stable_mono_win64.exe` (`4.7.1.stable.mono.official.a13da4feb`)
and the project-selected `Jolt Physics` backend.

- `RigidBody3D`, `HingeJoint3D`, `Generic6DOFJoint3D`, and
  `PhysicsDirectBodyState3D` are available.
- A falling rigid box produced `body_entered` and one reported contact against a
  static box.
- `_integrate_forces(state: PhysicsDirectBodyState3D)` received a
  `JoltPhysicsDirectBodyState3D` instance.
- `HingeJoint3D.FLAG_USE_LIMIT` with `PARAM_LIMIT_LOWER/UPPER` works.
- `Generic6DOFJoint3D.FLAG_ENABLE_LINEAR_LIMIT` with
  `PARAM_LINEAR_LOWER_LIMIT/UPPER_LIMIT` works.
- Freeing the disposable probe scene left zero child nodes after three physics
  frames.

The permanent `jolt_capability_probe.gd` repeats the API, contact, direct-state,
and cleanup checks. Joint API validation and falling-body contact are intentionally
independent so a temporary joint constraint cannot invalidate the contact probe.

This proves API availability and basic cleanup only. It does not validate the
excavator's provisional mass properties, collision proxies, servo tuning, dynamic
terrain replacement, or articulated stability.

## Godot AI MCP live shadow smoke

Observed through session `client@cf76`, Godot `4.7.1-stable (official)`:

- The editor opened `res://scenes/main.tscn` and the game helper reached `live`.
- With the temporary runtime setting `jolt_shadow`, `MotionClient` negotiated
  `simulation_truth_shadow_v1`, remained `ready`, and kept the Python-driven
  chassis transform unchanged.
- SY205 published `sy205-jolt-rig`; `/health` observed physics tick 1220 with a
  sample age of 15.6 ms.
- A runtime model switch produced an SY135 sample with
  `sy135-jolt-rig`, `sy135-reference-urdf-v1`, and physics tick 973.
- One measured SY205 snapshot was 2479 UTF-8 JSON bytes and one snapshot build
  took 402 microseconds at physics tick 645. These are development-machine
  baselines, not release budgets.

The game and backend were stopped after the smoke, and the persisted profile was
restored to `python_kinematic`.
