# Authority Contract And Shadow State

## Goal

Establish the versioned contracts and runtime seams needed for Godot/Jolt authority
without changing the current product pose authority. Prove the exact Godot 4.7.1
Jolt APIs locally and publish ordered observational shadow truth to Python.

## Dependency

First child of `08-17-jolt-authoritative-simulation`; no earlier child dependency.

## Requirements

- Define explicit `python_kinematic`, `jolt_shadow`, and `jolt_authoritative`
  profiles and the allowed state writer in each profile.
- Define a versioned physics-rig descriptor contract for SY205/SY135: body/joint
  frames, shape references, collision layers, mass properties, actuator parameters,
  provenance/status, units, and coordinate basis.
- Define an immutable Godot truth snapshot with authority epoch, physics tick,
  monotonic time, model/rig/calibration identity, terrain identity, body/joint/track/
  payload/contact sections, and quality flags.
- Add one complete Y-up to canonical Z-up conversion owner for exported transforms,
  linear/angular vectors, and gravity/specific-force semantics.
- Implement negotiated, latest-value shadow transport and strict Python validation.
  Shadow data must never feed `Simulator`, `MotionPresentation`, TerrainState, or
  BucketSoilState.
- Preserve current input/lifecycle behavior and product visuals in shadow mode.
- Build local disposable probes for Godot 4.7.1 Jolt body, hinge/6DOF joint, motor/
  force, contact, sleep/wake, and teardown behavior; persist observed results.

## Acceptance Criteria

- [ ] Existing `python_kinematic` behavior and v3 tests remain unchanged.
- [ ] Both model descriptors validate or fail with explicit field-level errors; no
      cross-model value fallback occurs.
- [ ] Shadow snapshots are finite, monotonic, versioned, coordinate-tested, and
      correlated to lifecycle/model/terrain identity.
- [ ] Python rejects unknown versions, stale ticks/epochs, invalid matrices/vectors,
      wrong model/rig identity, and oversized/rate-limited messages without changing
      product state.
- [ ] Tests assert shadow mode cannot write any excavator transform or terrain/
      bucket state.
- [ ] Local Jolt probe evidence records supported APIs, constraints, solver settings,
      and failure/cleanup behavior for the installed Godot 4.7.1 build.

## Out Of Scope

- Product chassis or articulated physics authority.
- Physical track movement, terrain deformation from contacts, sensor noise, or
  changing the default runtime profile.

