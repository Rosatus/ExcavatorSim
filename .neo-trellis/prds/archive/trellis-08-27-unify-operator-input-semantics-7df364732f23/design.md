# Technical design

## Architecture

Separate the input path into explicit coordinate layers:

```text
Keyboard / XInput
  -> fixed operator actions
  -> canonical OperatorAxes(swing, boom, arm, bucket)
  -> protocol v4 input_snapshot.axes (when transported)
  -> selected EquipmentCommandProfile
  -> JointAxes(swing_joint, boom_joint, arm_joint, bucket_joint)
  -> Jolt kinematic articulation or Python compatibility simulator
  -> accepted transforms
  -> unchanged CTN1 / CAN / QML pose projection
```

Input devices and HUD never read model calibration. Physics/simulation never
read physical keys or joy-axis coordinates.

## Canonical operator actions

Use explicit action names instead of overloaded joint-sign names:

- `operator_swing_right`, `operator_swing_left`
- `operator_boom_raise`, `operator_boom_lower`
- `operator_arm_extend`, `operator_arm_retract`
- `operator_bucket_curl`, `operator_bucket_dump`

`OperatorAxes` uses the fixed order `(swing, boom, arm, bucket)`, with the first
action in each pair positive. Keyboard and XInput install exactly one fixed
binding per action. Godot joy Y inversion is handled only as device-space
binding: right-stick down is boom raise and left-stick up is arm extend.

## Shared equipment command profile

Add a strict `equipment-command-profile-v1` schema and canonical data file under
`protocol/`. It declares:

- schema/profile version;
- canonical axis order and positive/negative semantic labels;
- exact supported model IDs;
- exactly four semantic-to-joint signs per model, each `-1` or `+1`;
- provenance/notes sufficient to point to the isolated motion evidence.

Python validates and consumes the canonical file. A deterministic repository
script generates the Godot `res://resources/protocol/` runtime copy. A parity
test rejects divergence, and provenance records the generated artifact and all
inputs. Model selection must resolve a valid profile before motion arms.

## Godot boundary

Introduce one typed mapper responsible for:

```text
read_operator_axes() -> Vector4
configure_model(model_id) -> bool
to_joint_axes(operator_axes) -> Vector4
```

`MotionClient` owns fixed InputMap registration and protocol-v4 publishing.
`ProductSession` and the local authoritative controller consume the same mapper
result rather than reading InputMap independently. Model activation selects the
profile and forces neutral re-arm before the mapper can release non-zero joint
axes. `DiggingResponseShaper` remains on joint axes so its established inward/
escape direction contract is unchanged.

Delete both per-device model multiplier tables, opposite-action key swapping,
and HUD key-event introspection. The HUD maps fixed operator actions directly to
fixed physical tiles and continues to show opposing held actions independently.

## Python boundary

Protocol v4 decoding names the incoming tuple `operator_axes`. After input
safety/dead-zone shaping, the selected model's validated command profile maps it
once to joint axes immediately before simulation/control uses joint-coordinate
velocity. Gateway-only mode may validate/ack operator axes without producing
pose; compatibility motion uses the mapped joint axes.

Do not reuse QML `joint_signs`: those invert pose-to-CAN kinematics and are a
different boundary.

## Protocol migration

- Add `godot-pinocchio-v4.schema.json` and move active constants/version
  manifests/hello negotiation/tests to v4.
- Define `AxisVector` semantics in schema descriptions and the motion transport
  spec, including exact order and positive/negative meanings.
- Do not accept v3 as v4 or negotiate an implicit fallback. A mismatch faults
  before ready/input acceptance.
- Preserve every non-input message shape unless a mechanical version reference
  must change.

## Failure and lifecycle behavior

| Condition | Behavior |
|---|---|
| Unknown model/profile | fail model activation; emit contract diagnostic |
| Missing/malformed/generated-copy mismatch | remain disarmed; accept no non-zero equipment command |
| Model switch | clear input, select/validate profile, require neutral re-arm |
| Focus loss/reconnect/reset | publish/retain zero and clear armed state |
| Protocol mismatch | fail hello negotiation before input acceptance |
| Non-finite/out-of-range operator value | reject/zero according to existing input safety contract |

## Rollback boundary

The migration is one coherent protocol/code commit series. If cross-runtime
parity cannot be proven, retain v3 and the last known working input implementation;
do not ship a partial state where only one authority interprets v4 semantics.
