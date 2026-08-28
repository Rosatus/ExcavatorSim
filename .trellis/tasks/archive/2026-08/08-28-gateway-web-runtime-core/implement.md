# Implementation Plan — Gateway Web runtime core

## 1. Baseline and model extraction

- [x] Record Gateway/PC001/SocketCAN/ICT/CSV/timed-frame/Godot baselines.
- [x] Introduce explicit runtime mode and immutable status/error/command DTOs.
- [x] Extract a single core owner without changing existing producer bytes.

## 2. Command and Web lifecycle

- [x] Add typed command queue, wakeup channel, revision preconditions, and
  bounded request completion.
- [x] Add `aiohttp` loopback startup/shutdown, fixed-port behavior, static
  fallback, status endpoint, WebSocket event endpoint, and error envelope.
- [x] Implement standalone/managed and platform capability middleware.
- [x] Add CLI/Godot managed-mode arguments and standalone browser-open policy.

## 3. Transport safety

- [x] Refactor PC001 to one service-thread writer with bounded queue/drop
  accounting and deterministic disconnect clearing.
- [x] Implement core-owned Windows endpoint rebind and successful-only atomic
  persistence.
- [x] Implement core-owned Linux fixed can0 restart with confirmation,
  progress, verification, and normal-start no-cycle preservation.

## 4. Logging

- [x] Add sequence ring, per-message one-second aggregation, and producer tags.
- [x] Add non-blocking JSONL writer, five-by-20 MB rotation, startup recovery,
  current-log streaming, and retained-history archive streaming.
- [x] Expose overflow/drop counts and transport/config lifecycle events.

## 5. Verification

- [x] Test bind/mode/platform/revision/request-size/error behavior.
- [x] Stress PC001 concurrent producers and prove no interleaved writes,
  unbounded queue, stale replay, or auto-resume after disconnect.
- [x] Test Windows rebind and Linux restart success/failure/disarm transitions.
- [x] Stress log aggregation/rotation with a slow writer and absent browser.
- [x] Run existing Gateway regressions and review authority boundaries. The
  Godot argv regression is present but could not execute because no Godot binary
  is installed in the current shell environment.
