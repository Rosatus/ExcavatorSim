# Cross-Repository CAN And Pose Parity

## Scope And Paths

- Producer: `E:/projects/ExcavatorSim`
- Reference consumer/replay: `E:/projects/dev_arch2.0_36b5586c`
- The originally supplied `E:/projects/dev/_arch2.0/_36b5586c` path does not exist on this machine.
- Recorded sample: `godot/dist/windows/output/can_gateway/can_telemetry_20260827_082941.csv`

This note separates three questions that must not be collapsed:

1. Does replay preserve the CAN frame?
2. Does the reference parser reconstruct the intended fields?
3. Do the final Godot and QML model frames represent the same pose?

## Boundary Matrix

| Boundary | Result | Evidence |
|---|---|---|
| Godot frame quaternion -> Ruifen slots | Consistent for existing pitch contract | `conventions.py::link_rpy`, `sensor_slots`; gateway attitude tests |
| CSV -> `_replay` parser | 5770/5770 exact for ID, DLC, payload | Direct audit: `parse_mismatch=0` |
| `_replay` -> PC001 `can_frame` | 5770/5770 exact for ID, DLC, payload | Direct audit: `pack_mismatch=0` |
| Ruifen slots -> reference parser RPY | Consistent | sender `(-pitch, roll, yaw)`, parser `(s1, -s0, s2)` |
| Link pitch -> `Sensor2Ang` | Reconstructable, with calibration | `GuidancePeriodicService` + `lib_kin::Sensor2Ang` |
| Gateway RTK forward axis | Incorrect | `basis_forward_from_quat()` returns local `+X`, contract is Godot `-Z` |
| Gateway RTK source frame | Incompatible with reference GNSS calibration | Producer uses `chassis`; reference calibration needs antenna motion about slew center |
| QML 3D root vs full Godot chassis/upper chain | Not equivalent | QML normal path has one world heading and clears relative `bodyAngle` |
| Final rendered pose | Not yet observed | No joined Godot/QML runtime transform trace exists |

## Replay Audit Details

The reference main replay path:

- treats a row as extended only when `帧格式 == "扩展帧"`, then adds `CAN_EFF_FLAG`;
- preserves payload byte order and requires data length to equal DLC;
- packs `<IBBBB8s` without changing the ID or payload;
- preserves CSV row order.

For the recorded sample:

```text
frames=5770
parse_mismatch=0
pack_mismatch=0
extended=5610
channels=[3]
```

Non-payload differences remain: direction/frame-type columns are ignored, timestamps are converted to relative scheduling offsets, equal offsets may be batched, repeat duplicates the sequence, and vcan/bridge output drops channel.

## Reference Pose Contract

### 3D mode

`GuidancePeriodicService` selects RTK heading. `Sensor2Ang` produces:

```text
bodyPhiHeading = rtkHeading + yaw calibration
bodyPhiPitch/Roll from body IMU + calibration
boomPhi/armPhi/bktPhi from link pitch + calibration/four-bar geometry
```

QML applies:

```text
R_root = Rz(-bodyHeading - 90) * Ry(bodyRoll) * Rx(bodyPitch)
```

and local X-axis boom/arm/bucket rotations. The normal algorithm path writes `bodyAngle = 0`, so it does not preserve a second chassis-vs-upper yaw.

### 2D mode

The reference design intentionally uses slew angle instead of RTK heading. This is a different mechanical reference frame, not an interchangeable 3D heading source. The current parser assignment `angle = rawAngle` contradicts its documented/tested `raw * 360 / 65536` contract and must be tracked separately if 2D parity enters scope.

## RTK Frame Contract

Reference evidence:

- calibration derives the GNSS-to-slew-center offset from the antenna path during upper rotation;
- kinematics rotates the `GO` antenna-to-center vector by RTK heading;
- the UI identifies main/right and vice/left antennas.

This implies the RTK antenna frame follows the rotating upper structure. The producer currently derives main geodetic position, A900 heading, velocity and vice antenna from `sample.bodies["chassis"]`. It also assumes a one-metre fore/aft vice-antenna baseline, for which no reference contract was found.

## Recorded Sample Implication

```text
start: body yaw=0.00, slew=0.00, link yaw=0.00, RTK=90.00
end:   body yaw=-15.86, slew=197.02, link yaw=-178.84, RTK=105.86
```

At the end, `wrap(body yaw + slew) = -178.84`, matching the world yaw of boom/arm/bucket. Current RTK instead remains a function of chassis only. Replacing local `+X` with `-Z` removes the fixed 90-degree axis offset but does not restore the missing 197-degree upper rotation.

## Required Runtime Closure

Join both sides by an explicit source sequence/tick and record:

- Godot: chassis/upper/boom/arm/bucket authoritative world transforms, four joint positions, gateway source packet;
- CAN/reference parser: decoded RTK/body/link/slew fields;
- reference algorithm: `bodyPhiHeading/Roll/Pitch`, `boomPhi/armPhi/bktPhi`, O and bucket-tip positions;
- QML: final root/boom/arm/bucket world transforms.

Compare transforms after one documented coordinate conversion. Use wrapped angular error, quaternion sign equivalence, position tolerance tied to CAN quantization/calibration, and explicit frame names. Do not compare raw Godot world Euler components directly to QML local joint angles.

## Blocking Scope Decision

Decision: compare the QML guidance frame it actually represents—slew center O /
upper world heading, boom/arm/bucket world transforms and bucket tip—and retain
lower chassis yaw only as a diagnostic input. QML is the sole oracle; Godot and
the Python gateway adapt to it.

Full mesh parity with independent lower-chassis and upper yaw is not required by
this task because the existing QML 3D contract does not carry both degrees of
freedom.
