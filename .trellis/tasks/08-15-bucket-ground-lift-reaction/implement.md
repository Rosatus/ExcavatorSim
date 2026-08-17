# Bucket Ground Lift Reaction Implementation Plan

- [x] Verify prerequisites: stable `ChassisMotionRoot`, model-specific rear/shell
      proxy, raw swept contact classifier, and aggregate operation identity.
- [x] Implement stable support classification separate from cutting contact.
- [x] Implement bounded heave/pitch/roll target generation around the track support
      polygon, with dead zones, clamps, and fixed-step damping.
- [x] Compose support after locomotion terrain following and before visual children;
      ensure raw contact sampling excludes the prior reaction offset.
- [x] Keep Jolt hints generation-guarded and optional; use the authoritative coarse
      heightfield for bucket support when no matching physics derivative exists.
- [x] Add lifecycle clearing and smooth release on contact loss or stopped motion.
- [x] Reuse the existing bounded contact resistance aggregate without adding another
      feedback channel; do not add a second chassis state owner.
- [x] Add tests for support/cut classification, several bucket angles, slopes,
      moving/pivoting chassis, clamps, release, reset, both models, Jolt-disabled
      fallback, and absence of cumulative drift.
- [x] Run Godot standalone matrix/headless import and Godot MCP live visual checks.

## Rollback Point

Feature disablement must reduce support offset to zero and leave locomotion,
articulation, terrain, and payload behavior unchanged.
