# Tracked Chassis Locomotion Implementation Plan

- [x] Add validated SY205/SY135 track physical descriptors and contract tests.
- [x] Add four input actions and a focus-safe local track input sampler.
- [x] Add `ChassisMotionRoot` and prove it is the sole local chassis-pose writer.
- [x] Implement fixed-step skid-steer speed/yaw integration with acceleration,
      braking, coast, reversal, slope limits, and bounded slip.
- [x] Add deterministic heightfield support sampling plus generation-guarded,
      fail-open Jolt raycast hints.
- [x] Route camera, active model, bucket probes, and downstream world queries through
      the chassis root without changing Python articulation semantics.
- [x] Clear controller state on reset, reconnect, model switch, and focus loss.
- [x] Add standalone tests for trajectories, pivot turns, terrain following,
      lifecycle resets, both models, and Jolt-disabled fallback.
- [x] Run Godot headless import/test matrix and use Godot MCP for live keyboard-feel
      and visual-coherence validation.

## Review Gate

Do not start automatic soil interaction until the chassis pose/root and reset
contracts are stable and documented.

## Validation Evidence

- Godot AI MCP session `client@c72d`, Godot `4.7.1-stable`, loaded
  `res://scenes/main.tscn` from disk and ran against the motion-only backend.
- SY205 connected with `connection_state=ready`; a frame-timed action sequence
  held both forward actions for 60 frames. `ChassisMotionRoot` moved to
  `z=-0.5638194` with `yaw=0`, and the camera remained attached to the moving
  presentation target. A separate 90-frame run moved the chassis to
  `z=-1.2077918` while the camera followed to `(7.459656, 5.651845, 7.297429)`.
- `MotionClient.request_model_switch("sy135")` completed through a new backend
  session. Client, presentation, and chassis all reported `sy135`, the client
  returned to `ready`, and the only active runtime visual was
  `PresentationRoot/ActiveExcavator`.
- The model switch reset the chassis transform to identity. A 90-step SY135
  counter-rotation then kept translation at zero and produced `yaw=0.8150342`
  with left/right speeds `-1.425/+1.425 m/s`.
- Current-run game logs contained no task error; the only warning was the
  pre-existing Terrain3D `instance_reset_physics_interpolation()` deprecation.
