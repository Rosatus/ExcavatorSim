# Physics Rig Gaps And Recommended Shape

## Observed Gaps

- `godot/client/project.godot:37-40` selects Jolt, but the product excavator has no
  `RigidBody3D`, physical joint, or collision rig.
- `godot/client/scenes/main.tscn:242-248` mounts the active machine below Node3D
  transform owners.
- `godot/client/resources/models/model_catalog.json:18-35` has kinematic track
  dimensions and tuning, not masses, friction, forces, joint motors, or collision
  layers.
- `assets/model/kinematic_excavator.urdf:3` and the generated evidence label current
  physical values as provisional/estimated.
- `godot/client/scripts/terrain_commit_scheduler.gd:124-180` may refresh a derived
  collider after logical edits; contact continuity across replacement is currently
  undefined.
- SY205's four-bar is a Godot visual solver, not a physical closed loop.

## Recommended First Physics Rig

- Five bodies: chassis/base, upper, boom, arm, bucket.
- One slew and three hinge DOFs; bounded actuator targets drive actual physics
  joints.
- Compound primitive/convex collision shapes external to the GLB.
- One chassis body with several left/right traction points; no individual shoes.
- Keep passive four-bar presentation-only until a separate solver-stability need is
  proven.
- Carry provenance and validation status for mass, inertia, COM, joint frame,
  collision shape, and tuning parameters.

## Mandatory Spikes

- Validate Godot 4.7.1 Jolt rigid-body/joint motor behavior, force/torque APIs,
  solver stability, sleeping, and contact reporting in a disposable test scene.
- Check inertia positive-definiteness/triangle inequalities, total COM, static
  support, and tipping thresholds before enabling dynamic work equipment.
- Prototype terrain collider revision replacement while a body is resting and while
  a bucket is in contact.

The official Godot documentation endpoint returned repeated HTTP 502 responses on
2026-08-17. No online API claim is treated as validated; Phase 0 must capture local
Godot 4.7.1 evidence before production implementation.

