# M2 backend wire contract

## WebSocket lifecycle

- `GET /ws` is the only realtime endpoint. The server validates Origin, limits frames to 64 KiB, and requires a text `hello` within three seconds (`backend/src/babylon_sim/web.py:576-635`).
- Each connection receives a new server-generated `session_id`; there is no resume handshake. Disconnect cleanup removes input sequence and command ownership (`backend/src/babylon_sim/web.py:786-797`, `backend/src/babylon_sim/runtime.py:205-209`).
- After `hello_ack`, state messages are interleaved: the sender emits `view_state` when `view_revision` increases and may send terrain/status messages independently (`backend/src/babylon_sim/web.py:834-878`).

## Application frames

- Client hello: `{"type":"hello","protocol_version":"babylon-sim-v3","capabilities":[...]}` (`protocol/babylon-sim-v3.schema.json:88-100`).
- Input snapshot: `client_sequence`, `connected`, `focused`, four `axes`, and `client_sent_ms`; the server applies a zero barrier when focus is lost and requires strictly increasing sequences (`protocol/babylon-sim-v3.schema.json:102-113`, `backend/src/babylon_sim/input_router.py:113-150`).
- Lifecycle command: `{"type":"command","id":"...","command":"start|pause|reset"}`; success is `command_applied` and failure is a typed `error` with optional `request_id` (`protocol/babylon-sim-v3.schema.json:115-123,205-215`).
- View state contains four ordered joint vectors and arbitrary named `frame_transforms` as four-by-four row arrays; the client must preserve the Python-to-Godot matrix conversion in the SY205 adapter (`protocol/babylon-sim-v3.schema.json:319-382`).

## M2 reduction decisions

- Treat `session_id` and `simulation_epoch` as generation boundaries. Clear the pose buffer and pending commands at either boundary.
- Within a generation, accept only strictly newer `view_revision`; ignore duplicates/older state without mutating pivots.
- Reconnect creates a fresh socket, sends a new hello, queues zero input before non-zero input, and does not replay old commands.
- `client_sent_ms` is a transport diagnostic timestamp only; it never drives simulation time.
