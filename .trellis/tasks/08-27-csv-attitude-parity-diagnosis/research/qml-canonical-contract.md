# QML Canonical CAN And Pose Contract

## Authority

For this task, the existing GuideSystem/QML behavior in
`E:/projects/dev_arch2.0_36b5586c` is the sole compatibility target. Godot and
the Python CAN gateway adapt to it. QML parser, kinematics, calibration loading,
mode selection and render transforms are not repair targets.

## 3D Inputs Actually Consumed

`GuidancePeriodicService::step()` runs every 100 ms. In 3D mode it consumes:

| CAN input | Required fields | QML/kinematics use |
|---|---|---|
| `0x0CFDA200/300/400` | main longitude/latitude/altitude | transform GNSS A to ENU and position the guidance model |
| `0x0CFDA900` | heading, LE u16, 0.01 degree | `bodyPhiHeading` and the root `Exca` matrix |
| `0x18FF3A00` | body roll and pitch | `bodyPhiRoll/bodyPhiPitch` |
| `0x18FF3B00` | boom pitch | `boomPhi` |
| `0x18FF3C00` | arm pitch | `armPhi` |
| `0x18FF3D00` | bucket pitch | four-bar `bktPhi` |

Slew `0x18FFF000` is not a 3D pose input; it replaces heading only in 2D mode.
RTK time/status, vice antenna, velocity, travel and unused IMU components remain
important for monitoring/display or transport completeness, but not for the 3D
pose equations.

The immutable `ProtocolParser` is mixed-endian: A200-A700 and A900 are little
endian, while A800 reads ve/vn/vu/speed as four big-endian signed i16 values.
The QML profile therefore overrides A800 to big endian without changing legacy
no-profile captures.

## Source Frames

The QML body IMU belongs to the rotating upper/cab frame:

- calibration samples body roll/pitch while the body is rotated through
  90/180/270/360-degree headings;
- 3D kinematics treats body R/P and RTK heading as one absolute root attitude;
- body IMU yaw is stored but not used by `Sensor2Ang`.

Therefore the Godot sources are:

```text
QML guidance root / slew center O -> upper_structure_link
body IMU                           -> upper_structure_link world rotation
RTK heading                        -> upper_structure_link world rotation
boom/arm/bucket IMU                -> corresponding link world rotation
lower chassis                      -> diagnostic only for QML 3D parity
```

This distinction is observable on a slope: `R_upper = R_chassis * R_slew`.
Upper-frame roll/pitch change with slew because the slope components rotate
relative to the cab axes; chassis Euler R/P cannot reproduce that behavior.

## Calibration Authority

GuideSystem registers only SY135C. Factory defaults live in
`shared/machine/src/machinefactory.cpp`; `Configuration` then applies any keys
from `<applicationDir>/database/calibration.toml`, or migrates legacy JSON.

The source ground-truth fixture differs from factory defaults. Consequently an
exact parity result is meaningful only when tied to a named calibration
snapshot and hash. The compatibility profile in ExcavatorSim must contain the
needed values without importing the sibling reference tree at runtime.

The first deterministic oracle should bind
`GuideSystem/tests/ground_truth_e2e/test_data/calibration.toml`, whose SHA-256 is
`47cab86524d35866a0fa4fd7490feb0ab8ca4a0645b89ddc29f6380fed421b56`.
A field/runtime test must bind a separately captured deployment
`database/calibration.toml`.

## QML Pose Equations And Required Inverse

GuideSystem computes:

```text
bodyPhiPitch   = body_parser_pitch + roll_error_IMU_Car
bodyPhiRoll    = body_parser_roll  - pitch_error_IMU_Car
bodyPhiHeading = A900_heading      + yaw_error_IMU_Car

Exca = Rz_special(bodyPhiHeading)
       * Ry(bodyPhiRoll)
       * Rx(bodyPhiPitch)

O_QML = Exca * GO + GNSSA
```

where `GNSSA=(east,north,up)` and `GO` is the calibrated antenna-to-slew-center
vector in the QML vehicle frame. To make QML recover a chosen Godot upper pose:

```text
body_parser_pitch = target_bodyPhiPitch - roll_error_IMU_Car
body_parser_roll  = target_bodyPhiRoll  + pitch_error_IMU_Car
A900_heading      = wrap360(target_bodyPhiHeading - yaw_error_IMU_Car)
GNSSA             = O_target_ENU - Exca_target * GO
```

The Godot-to-ENU translation convention is currently:

```text
east  = world.x
north = -world.z
up    = world.y
```

The full orientation conversion into QML's `Rz_special * Ry * Rx` basis is:

```text
C = [[1,0,0], [0,0,-1], [0,1,0]]
Q = Rz(-90 degree)
B_canonical = C * B_upper_godot * transpose(C)
Exca_target = Q * B_canonical
```

`C` is already the project's canonical vector/frame conversion. `Q` is the
QML/GuideSystem heading-zero reference and is locked by the reference
`test_bucketenu` matrix. For `B_upper_godot=I`, QML angles are heading=0,
roll=0, pitch=0 and `Exca=Rz(-90 degree)`. Godot `+90 degree` Y yaw maps to QML
heading `270 degree`; Godot `-90 degree` maps to QML heading `90 degree`.

For non-gimbal poses, extract from `E=Exca_target`:

```text
bodyPhiRoll    = asin(clamp(-E[2,0], -1, 1))
alpha          = atan2(E[1,0], E[0,0])
bodyPhiPitch   = atan2(E[2,1], E[2,2])
bodyPhiHeading = wrap360(-degrees(alpha) - 90)
```

At `abs(cos(bodyPhiRoll)) <= eps`, heading and pitch are not separately unique;
the mapper must use a documented continuity rule or reject the pose. It must
not silently emit a discontinuous Euler branch.

For the SY135 physics rig, `upper` origin equals the swing origin, so
`sample.bodies["upper"].origin_m` is the target O.

## Working Equipment

The reference parser remap remains:

```text
wire slots = (-reported_pitch, reported_roll, reported_yaw)
parser RPY = (slot1, -slot0, slot2)
```

The existing fixed mount-compensation approach is evidence, not the oracle.
For each adjacent Godot frame pair, compute the current relation against its
profile-bound neutral relation and extract the X-axis twist. Convert that joint
delta into a target QML joint pose, then invert `Sensor2Ang` using the active
calibration:

```text
p_b = cB - bodyPhiPitch - boomPhi_target
p_a = p_b - cB + cA + 180 - armPhi_target
```

For bucket, numerically invert the exact reference four-bar function on the
machine's legal monotonic interval and recover:

```text
x = inverse_four_bar(bucketPhi_target)
p_k = p_a + cK - cA - x
```

Use bracketed bisection/Brent behavior with explicit unreachable-pose failure,
then forward-evaluate the same formula before encoding. The executable oracle
remains the real reference `ProtocolParser + GuidanceCore + lib_kin`, bound to
the same calibration profile.

The profile also owns the neutral/sign alignment between Godot joint deltas and
QML render angles. It must be established by a neutral checkpoint and one
positive single-axis checkpoint per joint; it cannot be inferred by cascading
global Euler elevations.

## Status Contract

GuideSystem regards `satelliteStatus == 4` as stable RTK orientation. The
gateway currently emits zero. A valid synthetic RTK stream should publish the
stable status; dedicated invalid/missing-frame fixtures must continue to prove
the warning behavior.

## Automation Boundary

The deterministic chain is:

```text
Godot same-tick upper/link transforms
  -> telemetry packet fixture
  -> Python gateway frames
  -> CSV
  -> reference replay parser/raw pack byte identity
  -> reference ProtocolParser + GuidanceCore/lib_kin
  -> O / heading / joints / bucket tip oracle
```

The reference C++ ground-truth harness already runs without vcan or QML UI and
is the closest executable QML oracle. Final live validation additionally loads
the QML model and confirms the same fixture visually/runtime, but screenshots
are not the primary numeric acceptance evidence.

Direct PC001/SocketCAN transport is part of consumability. Standard IDs remain
standard. A 29-bit ID must be packed as
`CAN_EFF_FLAG | (can_id & CAN_EFF_MASK)`; masking every ID with `0x7ff` prevents
the real parser from matching RTK, Ruifen and slew frames.
