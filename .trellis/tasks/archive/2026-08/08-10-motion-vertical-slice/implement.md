# Implementation Plan

## Phase 0 — Planning gate

1. [x] Confirm M1.5 supplied GLB mapping and parity fixture are available.
2. [x] Confirm existing `/ws` schema, lifecycle commands, input arming, and reconnect semantics from backend source/tests.
3. [x] Confirm product runtime must not depend on the Godot MCP addon or change Python protocol identifiers.

## Phase 1 — Product transport and state reducer

1. [x] Add shared constants and typed-ish normalizers for protocol version, capabilities, lifecycle, frame names, matrices, and connection states.
2. [x] Implement `MotionClient` with `WebSocketPeer` polling, hello/hello-ack, text-frame decoding, bounded reconnect, and explicit close handling.
3. [x] Implement input snapshots, zero-input arming, focus/disconnect safety, sequence numbers, and command ID/ACK/error correlation.
4. [x] Implement generation/revision guards and a two-sample visual pose buffer that resets on session/epoch/reconnect changes.

## Phase 2 — Visual/UI integration

1. [x] Add a `MotionPresentation` adapter that applies accepted frame matrices to the five SY205 pivots and preserves static fallback behavior.
2. [x] Add input actions and minimal operator status/diagnostics under the existing `OperatorUI` CanvasLayer.
3. [x] Add deterministic fake-transport tests for handshake, ACKs/errors, stale state, reconnect cleanup, and zero/asymmetric parity.

## Exit gate

- [x] Connected backend drives the real SY205 hierarchy through all four joint axes.
- [x] Start/pause/reset, input ACKs, reconnect, and safe disconnect are observable and stale-safe.
- [x] Godot headless tests pass, and no backend/protocol file or Godot MCP addon is changed.

## Validation

- `python ./.trellis/scripts/task.py validate .trellis/tasks/08-10-motion-vertical-slice`
- Godot MCP `editor_manage({"op":"state"})`, filesystem scan, hierarchy inspection, project run, and clean editor logs.
- `Godot_v4.7.1-stable_mono_win64.exe --headless --path godot/client --editor --quit`
- Focused fake-transport and scene tests under `godot/client/tests/`.
- `pixi run verify` if backend/protocol paths change; otherwise preserve the prior green result and run `git diff --check`.

## Risky files / rollback

- `godot/client/project.godot`: input maps and runtime settings; keep changes scoped and reversible.
- `godot/client/scenes/main.tscn`: only add owned runtime nodes/UI wiring; retain the hidden fallback.
- `godot/client/scripts/`: product transport and presentation code; disconnecting the client must leave static rendering usable.
- Do not stage `godot/client/addons/godot_ai/**`, editor caches, generated UID files, or unrelated user changes.
