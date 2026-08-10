# Technical Design

## Runtime ownership

```text
Godot input actions ──> MotionClient ──WebSocket /ws──> Python RuntimeController
                               │                         (joint state authority)
                               ├── MotionProtocol decoder / state reducer
                               ├── MotionGeneration + PoseBuffer
                               └── ExcavatorVisualSkin + OperatorUI
```

`MotionClient` is a product runtime node under `godot/client/scripts/`. It owns socket lifecycle, outbound sequence/command IDs, JSON decoding, and connection diagnostics. It does not import `addons/godot_ai`. A separate presentation adapter owns the imported `SY205Excavator` instance and is the only code allowed to write visual pivot transforms.

## Transport contract

- Default endpoint: `ws://127.0.0.1:8765/ws`; expose host/port in a small Godot project setting or exported configuration so local development can change it without editing protocol code.
- On `WebSocketPeer.STATE_OPEN`, send exactly one compact JSON `hello` with protocol version `babylon-sim-v3` and the M2 capabilities `input_snapshot` and `commands`. Terrain, recording, playback, and latency capabilities remain opt-in for later milestones. Ignore/reject application messages until `hello_ack` is accepted.
- Poll the peer from `_process`; drain all available text packets without assuming message order. `view_state`, `terrain_view`, `status`, and recording messages can be interleaved after the acknowledgement.
- Normalize each JSON object once in `MotionProtocol`-style helpers. Invalid shape, wrong type, non-finite numeric values, or unknown required version becomes a recoverable diagnostic and does not mutate state.
- Send `input_snapshot` at a bounded render-independent cadence (30 Hz target). Use `Time.get_ticks_msec()` only for the protocol's client diagnostic timestamp, never for simulation progression.
- Command IDs are local monotonic strings. Pending commands are cleared on close; reconnect never replays them.

## Generation and pose reduction

The reducer tracks `session_id`, `simulation_epoch`, `view_revision`, and the latest `source_sequence`. A new session or simulation epoch starts a new generation and clears both pending requests and the two-sample pose buffer. Within a generation, a state is accepted only when `view_revision` is greater than the accepted revision; lower or duplicate revisions are ignored. Interpolation is a visual-only blend between the two latest accepted frame matrices and is disabled across generations.

The frame mapper loads `res://resources/visual/sy205_visual_manifest.json`, resolves the five imported pivot paths beneath `PresentationRoot/SY205Excavator`, converts Python row arrays with the same column/basis convention captured by `sy205_glb_test.gd`, and writes each pivot's global transform. It never writes joint angles, terrain, or bucket state back to Python.

## Input and lifecycle

Use Godot input actions for the four joint axes plus `motion_start`, `motion_pause`, and `motion_reset`. Keyboard bindings mirror the backend's existing y/h, u/j, i/k, o/l pairs; a generic gamepad uses left/right or trigger-style axis pairs mapped to the same four values. The input reducer clamps axes to `[-1, 1]`, sends an initial zero snapshot, and sends zero on focus loss/disconnect. A non-zero snapshot is allowed only after the zero snapshot has been queued for the current socket.

Command state changes are acknowledgement-driven: `command_applied` updates the confirmed lifecycle; an `error` with a matching `request_id` leaves the last confirmed lifecycle unchanged and is surfaced as recoverable or terminal per the wire field. `reset` also adopts the next `simulation_epoch` from authoritative state.

## Scene/UI boundary

Attach one `MotionClient` and one `MotionPresentation` node under the existing `Main` scene. Keep the hidden `ExcavatorRig` fallback intact. `OperatorUI` displays connection/authority/lifecycle text and a compact diagnostics label; it does not parse WebSocket dictionaries itself. The client can run offline in `disconnected` state and still render the static GLB.

## Test seam

Use a transport interface implemented by a fake in headless tests. Inject representative JSON dictionaries rather than relying on wall-clock sockets. Cover hello negotiation, accepted/rejected input ACKs, command correlation/errors, revision/epoch guards, reconnect cleanup, and the two existing zero/asymmetric frame-parity cases. A separate optional smoke test can connect to a running backend but is not the deterministic unit gate.

## Rollback

If live transport or pose parity fails, disconnect the `MotionClient` and leave the static GLB scene/fallback usable. Do not modify the protocol schema or backend runtime in this milestone; any backend optimization belongs to M3.
