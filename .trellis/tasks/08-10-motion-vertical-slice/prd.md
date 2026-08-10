# Connected motion vertical slice

## Goal

Connect the Godot Forward+ client to the existing Python motion service and drive the supplied SY205 visual rig with authoritative pose snapshots. The slice must be usable when the service is stopped, restarted, or temporarily disconnected, and must never turn Godot presentation state into motion authority.

## Confirmed facts

- The Python WebSocket endpoint is `GET /ws`, normally served at `ws://127.0.0.1:8765/ws` by the existing CLI.
- The first text frame must be a strict `babylon-sim-v3` `hello`; the server responds with `hello_ack`, a new session ID, epochs, lifecycle, versions, and intersected capabilities.
- `view_state` contains the four joint vectors and named `frame_transforms` matrices. The existing fixture and the Godot-local SY205 manifest define the five visual frame aliases.
- `input_snapshot` requires a monotonically increasing `client_sequence`, four axes, `connected`, `focused`, and `client_sent_ms`. The server requires a zero-input arming snapshot before non-zero input.
- Lifecycle commands are `start`, `pause`, and `reset`; acknowledgements are correlated by command ID. A reconnect creates a new server session and cannot resume old pending requests.
- The Godot MCP addon is development-only. Product transport must be implemented under `godot/client/` without importing addon runtime code.

## Requirements

### M2-R1 — Protocol transport

- Implement a product `MotionClient` using Godot's `WebSocketPeer` and JSON text frames.
- Send the complete supported-capability `hello` once per socket after the connection opens.
- Decode `hello_ack`, `view_state`, `input_ack`, `command_applied`, `error`, and lifecycle/status messages with one shared validation/normalization boundary.
- Expose explicit connection states (`disconnected`, `connecting`, `awaiting_hello_ack`, `ready`, `stale`, `fault`) and last recoverable error information to the UI.

### M2-R2 — Motion presentation

- Accept pose state only for the current session and `simulation_epoch`, with monotonically increasing `view_revision` within that generation.
- Apply the five named frame matrices to the imported SY205 pivot nodes using the existing row-matrix conversion contract.
- Keep interpolation/render smoothing inside one motion generation; reset the pose buffer on reconnect, epoch change, reset, or stale rejection.

### M2-R3 — Inputs and lifecycle

- Add keyboard/mouse and generic Xbox-style gamepad actions for swing, boom, arm, and bucket axes.
- Send zeroed, focused-safe input on connect, focus loss, disconnect, and before arming non-zero input.
- Maintain client sequence numbers monotonically per socket and never reuse a pending command ID with a different command.
- Provide start, pause, and reset actions; update visible lifecycle only after matching acknowledgements or authoritative state.
- Reconnect with bounded backoff, a fresh `WebSocketPeer`, a fresh `hello`, cleared pending commands, and cleared visual pose generation.

### M2-R4 — Diagnostics and tests

- Show connection, authority/session, lifecycle, input acknowledgement, and recoverable error status in the existing `OperatorUI` layer.
- Add deterministic Godot-side tests using injected transport frames for handshake, input/command correlation, stale generation guards, reconnect cleanup, and the zero/asymmetric frame-parity cases.
- Keep backend/protocol identifiers unchanged. Run `pixi run verify` if any backend/protocol file changes; otherwise run the Godot headless and focused client checks.

## Out of scope

- Motion-only backend changes (M3), terrain/world state, bucket volume, replay UI, authoritative physics, and dynamic collision.
- Changes to the Python wire schema, protocol version, or legacy terrain/replay implementation.
- Using wall-clock time or Godot physics as simulation authority.

## Acceptance criteria

- [x] A running backend reaches `ready` after a valid hello/hello-ack exchange and displays the negotiated session, lifecycle, and capabilities.
- [x] The client receives both zero and asymmetric fixture poses and drives all five SY205 frame nodes with matrix error at most `1e-4` in the Godot adapter test.
- [x] All four joints can be moved through keyboard/gamepad axes; the first and focus-loss snapshots are zeroed and input acknowledgements are visible.
- [x] Start, pause, and reset commands show their acknowledgements; command errors do not mutate confirmed lifecycle state.
- [x] Older revisions, old epochs, and stale frames cannot overwrite the newest accepted pose; reset/reconnect clears the interpolation buffer and pending requests.
- [x] Disconnect/reconnect creates a new socket/session, re-arms with zero input, and resumes motion without stale transforms or command IDs.
- [x] The client remains usable and diagnostic when the backend is unavailable, and focused Godot tests plus headless scene/import checks pass.
