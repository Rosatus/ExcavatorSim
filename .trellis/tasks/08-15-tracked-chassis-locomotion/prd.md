# Tracked chassis locomotion

## Goal

Provide believable skid-steer crawler movement using two controls for the left
track and two for the right track, while preserving Python's articulated-joint
authority and giving later soil/contact work a stable chassis world pose.

## Requirements

- Define four independently bindable actions: left forward/reverse and right
  forward/reverse. Simultaneous opposite directions must support counter-rotation.
- Integrate locomotion at a deterministic fixed step with acceleration, braking,
  coast/drag, speed limits, and skid-steer yaw derived from track velocity.
- Own locomotion in one Godot-local `ChassisMotionRoot` above the Python-driven
  presentation root; do not extend or reinterpret the four upper-structure axes.
- Sample the authoritative terrain surface for chassis height, pitch/roll support,
  slope limits, and a bounded slip approximation. Jolt raycasts may assist but must
  fail open to deterministic heightfield probes.
- Store model-specific track gauge, contact length, speed/acceleration/brake and
  steering parameters in validated SY205/SY135 descriptors.
- Define reset, reconnect, model-switch, focus-loss, and stale-input behavior. Loss
  of input must brake to rest and must not retain track commands.
- Keep camera, bucket world probes, Terrain3D, and all visual children coherent
  under the same chassis transform.

## Out Of Scope

- Per-link track belts, sprocket force simulation, deformable track meshes, or full
  rigid-body chassis dynamics.
- Sending track commands through the existing four-axis Python input vector.

## Acceptance Criteria

- [x] Straight travel, differential turns, pivot turns, braking, and direction
      reversal are deterministic and covered by fixed-step tests.
- [x] The Python presentation transform and local chassis transform never write the
      same node; articulation continues to match backend snapshots while travelling.
- [x] SY205 and SY135 use separately validated locomotion parameters.
- [x] Terrain height/slope following works with Jolt enabled and disabled, without
      changing authoritative terrain state.
- [x] Reset/reconnect/model switch/focus loss clears commands and produces a bounded,
      reproducible chassis pose.
- [x] Godot headless tests and a Godot MCP live drive validate keyboard feel, camera
      tracking, no visible model drift, and no collisions that mutate terrain.

## Notes

This is the first implementation child. Python chassis authority remains a possible
future networked-dynamics migration, not part of this milestone.
