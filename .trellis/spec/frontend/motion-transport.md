# Godot Motion Transport Contract

## 1. Scope / Trigger

This contract applies to Godot product code that consumes the Python `GET /ws`
motion service. It was established by the M2 connected motion vertical slice.
The client is a presentation consumer: Python remains authoritative for joint
state, lifecycle, terrain, recording, and replay.

## 2. Signatures

- `MotionClient.connect_to_service() -> void` opens a fresh `WebSocketPeer` and
  sends one `hello` after the socket reaches `STATE_OPEN`.
- `MotionClient.process_for_test(delta: float) -> void` advances the same
  reducer used by `_process`, with an injected fake transport for deterministic
  tests.
- `MotionProtocol.decode_text(raw: String) -> Dictionary` parses and validates
  one server text frame; callers may mutate state only from an `{ok: true,
  payload: ...}` result.
- `MotionProtocol.rows_to_transform(rows: Array) -> Transform3D` converts the
  backend's right-handed 4x4 row matrix into Godot's `Basis` columns and
  translation.

## 3. Contracts (request/response/env)

- The hello request is exactly:

  ```json
  {"type":"hello","protocol_version":"babylon-sim-v3",
   "capabilities":["input_snapshot","commands"]}
  ```

- M2 advertises only capabilities implemented by the client. Terrain,
  recording, playback, and latency messages may be ignored until those
  features have an owned implementation.
- The server must return `hello_ack` with the required version manifest,
  `session_id`, `simulation_epoch`, `recording_epoch`, `/api/model`, a valid
  lifecycle, and both advertised capabilities before the client enters
  `ready`.
- `input_snapshot` carries a per-socket monotonically increasing
  `client_sequence`, four clamped axes, `connected`, `focused`, and
  `client_sent_ms`. A zero snapshot is sent first and after focus loss.
- `view_state` is accepted only for the current session/`simulation_epoch` and
  a strictly greater `view_revision`; at most two samples are retained for
  visual interpolation. `buffer_generation` is a recording diagnostic, not a
  motion generation boundary.
- A `ws://` endpoint requires an `Origin: http://host:port` handshake header;
  `wss://` maps to `https://host:port`.
- Reconnect always creates a new peer/session, clears pending requests and
  visual samples, sends a new hello, and re-arms with zero input. There is no
  server-side session resume.

## 4. Validation & Error Matrix

| Condition | Required response |
|---|---|
| Invalid JSON, non-object frame, unknown required message type, wrong shape, or non-finite number | Emit a recoverable diagnostic; do not mutate state. |
| Binary WebSocket packet | Emit `binary_not_supported`; ignore the packet. |
| Missing required version/capability in `hello_ack` | Enter `fault` and emit a non-recoverable `capability_unavailable`/schema diagnostic; do not become ready. |
| `view_state` with an older/duplicate revision or retired simulation epoch | Ignore it and retain the newest accepted pose. |
| `status.stale == true` | Clear the visual buffer, restore the imported rest pose, and enter `stale`; never apply stale transforms. |
| Socket close, hello timeout, or failed send | Clear pending state and pose, enter `disconnected`, and use bounded reconnect backoff when enabled. |
| Unknown input ACK or command ACK/error correlation | Emit a diagnostic and retain confirmed lifecycle/input state. |

## 5. Good / Base / Bad Cases

- Good: call `get_packet()` first, then `was_string_packet()`, decode once,
  validate, and reduce the normalized payload.
- Good: derive the Origin from the configured `ws(s)` endpoint and keep the
  same `MotionProtocol.rows_to_transform` adapter for every visual consumer.
- Base: a backend-unavailable client remains usable in static GLB mode with a
  visible offline diagnostic.
- Bad: read `was_string_packet()` before `get_packet()`; the result describes
  the previous packet and can leave the client waiting forever for `hello_ack`.
- Bad: cast every JSON number directly to `int`; Godot's JSON parser exposes
  integer-looking values as floats, so validate finite integral values within
  the safe JSON integer range first.
- Bad: treat `buffer_generation`, render cadence, wall-clock timestamps, or
  local physics as motion authority.

## 6. Tests Required

- Handshake: assert one exact hello, capability negotiation, and ready only
  after a compatible `hello_ack`.
- Input safety: assert zero arming, monotonic sequences, focus-loss zeroing,
  ACK correlation, and no mutation from unknown ACKs.
- Lifecycle: assert start/pause/reset correlation and that command errors do
  not alter confirmed lifecycle.
- Generation: inject older revisions, changed recording buffer generations,
  a new simulation epoch, and a retired epoch; assert pose-buffer and
  generation boundaries.
- Reconnect: assert fresh transport/session seam, cleared pending commands,
  cleared pose samples, and zero re-arming.
- Visual parity: apply the zero and asymmetric fixture poses to all five
  mapped pivots and assert the calibrated rest/asymmetric transforms.
- Runtime smoke: run the Godot headless import and the backend `pixi run
  verify` gate when backend/protocol files are touched.

## 7. Wrong vs Correct

### Wrong

```gdscript
var transform := _rows_to_transform(rows)
if transform.origin.y > 0:
    socket.send_text(JSON.stringify({"joint_position": transform.origin}))
```

This duplicates matrix conversion and attempts to write presentation data back
as authoritative motion input.

### Correct

```gdscript
var transform := MotionProtocol.rows_to_transform(rows)
pivot.global_transform = transform * calibration_offset
```

Only the Python `view_state` reducer owns the incoming frame; Godot applies the
derived transform to the visual pivot and sends control axes through the typed
`input_snapshot` contract.
