# Sensor And Gateway Boundary

## Observed State

- URDF/Pinocchio define `gnss_link` and four IMU frames, but no component generates
  sensor samples. Current output contains frame transforms only:
  `backend/src/babylon_sim/constants.py:5-18`,
  `backend/src/babylon_sim/state.py:15-26`.
- The v3 view schema has joint vectors and named transforms but no sensor clock,
  calibration, uncertainty, sample identity, or gap semantics.
- Legacy recording omits transforms, IMU, GNSS, Jolt contacts, and bucket feedback:
  `backend/src/babylon_sim/recording.py:38-70,249`.
- `bucket_load_feedback_v1` is an observational latest-value precedent, not a
  general telemetry or sensor contract.
- No CAN/USB/ROS implementation exists; hardware remains planned.

## Recommended Boundary

- Godot produces immutable post-physics truth snapshots.
- Scene-dependent contact and future ray/render sensors originate in Godot.
- Initial IMU, GNSS, encoder, track/contact, and payload samples reference the same
  truth tick and declared sensor frames.
- Python validates versions/order/time/units, records and exports samples, and hosts
  future hardware adapters. It does not call Pinocchio to reconstruct runtime truth.
- Hardware commands may enter through Python but expire and are safety-gated again
  at the Godot authority.

## Required Identity

Every truth/sensor record needs protocol version, model/rig/calibration version,
session, authority epoch, physics tick, producer/sample sequence, monotonic time,
coordinate frame/units, validity/quality, and terrain identity where applicable.

