# Sensor Telemetry And Python Gateway

## Goal

Export coherent authoritative truth and initial simulated sensors from the Godot
physics tick, while turning Python into a strict validation, recording, diagnostics,
and external integration gateway that does not reconstruct excavator motion.

## Dependency

Requires accepted terrain/excavation contact coupling from
`08-17-jolt-terrain-excavation-coupling` so body, joint, contact, terrain, and payload
truth are stable.

## Requirements

- Publish canonical Z-up truth snapshots using the Phase 0 envelope and actual Jolt
  body/joint/contact state.
- Produce initial sensor streams for joint encoders, four declared IMUs, GNSS,
  left/right track/contact state, and bucket payload/load.
- Every sample carries protocol/model/rig/calibration identity, sensor/frame ID,
  authority epoch, referenced physics tick, producer/sample sequence, monotonic
  sample time, units/frame, validity, quality, and noise/uncertainty configuration.
- Support independent bounded sensor rates without using network cadence as the
  physics clock; define gap/drop/latest-value versus lossless semantics per stream.
- Generate scene/body-dependent truth in Godot. Python may apply explicitly owned
  export formatting or optional post-processing but may not call `Simulator.step()`
  or Pinocchio FK to replace truth.
- Add Python decoders, rate/size/order guards, health/status, bounded recording, and
  export/subscriber seams.
- Add external command ingress interfaces with sequence/lease diagnostics, while
  deferring production CAN/USB drivers.

## Acceptance Criteria

- [ ] Truth and all initial sensors correlate to an existing authority epoch/tick
      and pass complete axis/unit/frame parity fixtures.
- [ ] IMU/GNSS/encoder/contact/payload values respond correctly to stationary,
      straight, turning, articulated, loaded, reset, and model-switch scenarios.
- [ ] Configured noise/bias is observable and bounded; raw truth remains separately
      identifiable.
- [ ] Python rejects stale, malformed, wrong-model/frame/calibration, oversized, or
      over-rate samples and exposes gaps/freshness without changing physics state.
- [ ] Recording/export retains sample identity and does not silently project sensor
      data into legacy RRD columns.
- [ ] External command loss/timeout safely reaches zero/disarmed state in Godot.

## Out Of Scope

- Camera, depth, LiDAR, radar, production CAN/USB/ROS drivers, cloud telemetry, or
  deterministic sensor replay.

