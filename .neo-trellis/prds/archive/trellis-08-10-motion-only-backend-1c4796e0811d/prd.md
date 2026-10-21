# Motion-only backend profile

## Goal

Add an opt-in Python runtime profile for the Godot motion client. The profile
must keep the existing fixed-rate `Simulator`, input lease/safety and lifecycle
protocol while avoiding the terrain, recording, replay and recording-exchange
workers used by the legacy BabylonSim session.

## Requirements

- Keep `RuntimeController`'s default behavior unchanged for existing callers and
  tests; `motion-only` is selected explicitly by the CLI or constructor.
- Construct only the kinematics simulator and `InputRouter` in the new profile.
  No terrain edit thread/executor, replay thread, or recording exchange may be
  started or left running in this profile.
- Preserve `hello`/`hello_ack`, `view_state`, `input_snapshot`, lifecycle
  command, acknowledgement, error, session and simulation-epoch identifiers.
  The motion-only hello response advertises only capabilities actually present:
  `input_snapshot` and `commands`.
- Keep schema-required recording/playback metadata in motion-only `view_state`
  as stable diagnostic projections. They are not recording or replay authority
  and must not cause terrain or replay state to be created.
- Reject playback, terrain and recording HTTP/WebSocket operations with the
  stable recoverable `capability_unavailable` code and without mutating motion
  state.
- Preserve reset, stop, disconnect, duplicate command IDs, input sequencing,
  focus-loss zeroing, bounded queues and non-daemon worker lifecycle semantics.
- Add focused backend tests for profile construction/worker absence, capability
  negotiation, motion snapshots and lifecycle/reset/stop/disconnect behavior.
- Add a CLI/pixi opt-in entry point and verify the existing Godot M2 client can
  connect to both profiles without changing wire identifiers.

## Acceptance Criteria

- [x] `RuntimeController(..., profile="motion-only")` starts and stops with no
  terrain/replay/exchange worker or executor, while the fixed-rate simulator
  publishes valid frame transforms.
- [x] The legacy profile remains behaviorally identical and all existing tests
  pass.
- [x] Motion-only `hello_ack` contains the required session/version/epoch fields
  and exactly the two implemented capabilities when the M2 client asks for its
  capabilities.
- [x] Motion-only `view_state` validates against the existing schema and drives
  the five GLB frame transforms; reset changes `simulation_epoch` and stale
  snapshots are not emitted as current state.
- [x] Unsupported terrain/recording/playback endpoints and WS messages return
  `capability_unavailable` without changing lifecycle, pose or input state.
- [x] `pixi run verify` passes, including strict mypy, backend tests, provenance
  and standalone path checks.

## Constraints

- Do not rename protocol/version identifiers or remove legacy terrain/replay
  modules.
- Do not make Godot, browser cadence or wall-clock time authoritative.
- Keep implementation scoped to backend runtime/web/CLI and focused tests; the
  M2 Godot code is only compatibility-tested, not redesigned here.
