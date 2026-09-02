# QML-Compatible CAN Projection

## 1. Scope And Trigger

This contract applies when Godot launches `tools/can_gateway/gateway.py` with
`--compat-profile`. QML and its C++ protocol/kinematics implementation are the
immutable semantic authority. Godot remains the simulation authority and the
Python gateway projects Godot truth into the CAN fields that the QML call path
actually consumes. Without a compatibility profile, the legacy gateway path
must remain byte-compatible.

## 2. Public Interfaces And Signatures

- `--compat-profile PATH|builtin:qml-sy135-ground-truth` selects a strict TOML
  mapping profile. `--qml-calibration PATH` may replace only the referenced
  calibration bytes.
- `load_qml_profile(...)` validates version, target, model, frame declarations,
  finite numeric values, ranges and the calibration SHA-256 before any UDP or
  CAN transport is opened.
- `QmlCanMapper.project(MachineState)` returns the body IMU fields, work-equipment
  fields, GNSS A/B fields and RTK status for one strictly increasing physics
  tick.
- `emit_frames(...)` pre-encodes the complete due frame family before appending
  any frame to the sink.
- The Godot CTN1 telemetry packet schema and version are unchanged. The profile
  consumes the existing `upper`, boom, arm and bucket transforms.

## 3. Semantic Contracts

- All profile frame declarations are `upper`. The fixed Godot-to-QML basis and
  QML root alignment are applied before extracting QML body P/R/H.
- Gateway wire values invert the complete QML runtime call path, including
  `GuidancePeriodicService`'s body pitch/roll remap and the active calibration,
  so `lib_kin` reconstructs the projected Godot pose.
- Main antenna position obeys `GNSSA = O - Exca * GO`. Velocity is the finite
  difference of successive GNSSA positions. The vice antenna uses the explicit
  profile mount offset; it is never inferred silently.
- Boom, arm and bucket inputs come from adjacent-link local-X twist relative to
  the profile neutral alignment. Off-axis residuals, gimbal singularities and
  unreachable four-bar branches are rejected.
- Profile alignment values are QML kinematic outputs, not raw IMU calibration
  offsets. The QML 3D renderer applies local X rotations as
  `(boomPhi, armPhi + 180 degrees, bktPhi + 180 degrees)`. Therefore the SY135
  Godot neutral relations `(+35, -90, -50)` require QML neutral targets
  `(+35, +90, +130)` before joint deltas are added.
- QML profile math owns physical projection, but the approved DBC owns wire
  layout in every profile. A800 `VelE/VelN/VelU/Vel` are signed little-endian;
  there is no compatibility-profile byte-order exception.
- Raw CAN IDs above `0x7ff` are packed with `CAN_EFF_FLAG`; standard IDs such as
  travel `0x256` remain standard. Already flagged valid extended IDs are
  preserved.
- The bundled calibration is byte-bound by SHA-256. Packaged applications must
  include both profile and calibration resources and log the selected profile
  version and calibration hash.

## 4. Rejection And Fallback Matrix

| Condition | Required behavior |
|---|---|
| Profile/calibration missing, malformed, hash-mismatched or wrong model | Fail before opening transport |
| Non-finite pose, origin, calibration or mount value | Reject the sample; emit no partial family |
| Off-axis joint rotation, gimbal singularity or unreachable bucket branch | Reject the sample with an actionable diagnostic |
| Duplicate or decreasing physics tick | Reject the sample; do not reuse a tick-only cache |
| Profile mapping fails at runtime | Drop that sample; never fall back to legacy projection |
| No compatibility profile configured | Use the unchanged legacy projection and encoding path |

## 5. Examples

Good: Godot publishes an SY135 post-step `upper` transform and link transforms
at tick 101. The gateway validates the bundled profile, projects the sample once,
pre-encodes all due frames, and QML's parser plus calibration reconstruct the
same root and joint pose within the locked numeric tolerances.

Base: at the SY135 neutral pose, QML receives kinematic outputs `(35, 90, 130)`;
its renderer applies `(35, 270, 310)`, which are the same signed local rotations
as Godot `(35, -90, -50)`.

Boundary: a legal bucket pose near either end of the configured monotonic
four-bar interval is accepted only if forward substitution reproduces the
measured adjacent twist.

Bad: a sample contains `NaN` in the ENU origin after body and joint frames were
prepared. The gateway must emit zero frames for that sample, not a partial IMU
or work-equipment family.

## 6. Verification Requirements

- Pure mapping tests cover neutral pose, Godot cardinal yaw, every joint in both
  directions, calibration inverse, GNSSA round-trip, four-bar forward
  substitution, gimbal/off-axis/range rejection, non-finite input and monotonic
  ticks.
- Neutral and isolated-joint mapping tests must independently apply the QML
  renderer's `+180 degree` arm/bucket offsets and compare each resulting local
  rotation with the corresponding Godot adjacent-frame relation. A
  `Sensor2Ang` inverse/forward round-trip alone is insufficient because it can
  prove a wrong neutral alignment self-consistent.
- Encoder tests compare against strict cantools encoding from the approved DBC,
  including an explicit A800 signed little-endian assertion in profile mode.
- SocketCAN and PC001 tests cover extended IDs A900 and the four Ruifen IDs plus
  standard travel ID `0x256`.
- Godot headless tests compare authoritative post-step transforms,
  presentation transforms, joint scalars and the emitted CTN1 packet for neutral
  and one positive checkpoint per joint.
- Packaging verification builds the Windows onefile executable and starts it
  with the bundled strict profile. The Python suite and focused Godot CAN E2E
  tests must pass before completion.

## 7. Common Wrong And Correct Patterns

Wrong: encode Godot Euler angles directly, use a generic forward-vector
convention, or compare only decoded CAN numbers. Correct: trace the entire QML
parser/service/calibration/kinematics composition and implement its mathematical
inverse.

Wrong: let the compatibility mapper override A800 byte order. Correct: the
mapper projects physical values and the shared DBC codec alone encodes the
little-endian A800 wire payload.

Wrong: emit frames as each field is calculated and silently recover with legacy
values. Correct: validate and pre-encode the whole due family, then append it
atomically from the mapper's perspective; profile errors drop the sample.

Wrong: use the three component IMU calibration offsets, or the result of feeding
zero pitch to `Sensor2Ang`, as the model's neutral QML joint outputs. Correct:
derive profile neutral outputs from the QML renderer's local-pivot equations and
the Godot adjacent-frame neutral relations, then validate both neutral and
isolated motion after the renderer offsets are applied.
