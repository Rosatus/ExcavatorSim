# Axis contract analysis

## Confirmed current flow

- `MotionClient._read_input_axes()` and
  `ProductSession.get_equipment_input_axes()` both construct
  `Vector4(swing, boom, arm, bucket)` directly from InputMap actions
  (`godot/client/scripts/motion_client.gd:878-886`,
  `godot/client/scripts/product_session.gd:139-147`).
- `TrackedChassisController._step_authoritative_chassis()` forwards that vector
  through digging response to `JoltChassisTrackRuntime`, which clamps it and
  passes it unchanged to `KinematicArticulationState`
  (`tracked_chassis_controller.gd:433-467`,
  `jolt_chassis_track_runtime.gd:272-287`).
- `KinematicArticulationState.propose_step()` multiplies each command directly
  by the actuator velocity and applies the descriptor joint axis in FK
  (`kinematic_articulation_state.gd:125-149,254-270`). No model command sign is
  currently represented in the rig/runtime boundary.
- Python protocol decoding preserves the same four numbers. `InputRouter`
  performs shaping only and legacy simulation uses
  `channel * limit.max_velocity`; Python has no operator-semantic adapter
  (`backend/src/babylon_sim/protocol.py:110-117,306-323`,
  `input_router.py:197-217`, `control.py:71-107`,
  `simulation.py:114-171`).
- CAN telemetry is derived from actual transforms and the gateway consumes pose,
  not input axes (`godot/client/scripts/can_telemetry_bridge.gd:529-557`,
  `tools/can_gateway/gateway.py:291-337`).

## Root cause

Three coordinate layers were collapsed into one action name:

1. physical device direction (keyboard top/bottom or Godot joy-axis sign),
2. operator outcome (raise/lower, extend/retract, curl/dump, left/right),
3. selected model joint-coordinate positive/negative.

Current keyboard and gamepad multiplier tables agree physically on swing, arm,
and bucket. Boom appears opposite because keyboard `I` is stick-up while Godot
joy Y positive is stick-down. The tables therefore encode both device-space and
model-space conversion and cannot be compared as plain model calibration.

## Selected contract

Canonical operator vector, in fixed order:

| Axis | Positive | Negative |
|---|---|---|
| swing | right rotation | left rotation |
| boom | raise | lower |
| arm | extend | retract |
| bucket | curl | dump |

Fixed physical positives are `D`, `K`, `W`, and `J`; XInput uses left-stick
right, right-stick down, left-stick up, and right-stick left respectively.

From the corrected physical-key evidence, the semantic-to-joint signs are:

| Model | swing | boom | arm | bucket |
|---|---:|---:|---:|---:|
| SY205 | -1 | -1 | -1 | +1 |
| SY135 | -1 | +1 | +1 | -1 |

These values require isolated final-motion tests; they are planning inputs, not
a substitute for executable evidence.

## Compatibility decision

The v3 schema constrains only four numbers in `[-1,1]` and does not define their
physical meaning. Reusing v3 while moving conversion to the consumer would
silently reinterpret valid packets. The clean migration is protocol v4:

```text
physical input -> canonical operator axes (wire v4)
               -> selected-model semantic-to-joint sign
               -> articulation/simulation joint command
               -> accepted pose -> unchanged CAN projection
```

No v3/v4 dual path is planned. Version mismatch fails during hello negotiation.

## Single-source profile strategy

Author one strict JSON profile plus schema under `protocol/`. Python reads the
canonical file directly. Godot requires a `res://` runtime copy, so a deterministic
sync/generation step produces that copy and tests compare exact canonical bytes
or digest. The generated copy is never hand-edited. This preserves one authored
calibration source while respecting Godot's project resource boundary.
