# Implementation plan

## 1. Control contract and pure timed state

- Add command 6 to Python and Godot control constants without changing the v1
  packet layout.
- Add the raw ID/payload constants and a monotonic-time timed-burst state with
  restart-on-retrigger behavior.
- Integrate its next deadline into the gateway receive loop and fan emitted
  frames through `active_sinks()`.
- Keep normal telemetry frame scheduling and QML mapping untouched.

## 2. Gateway lifecycle supervision

- Refactor gateway argv creation so packaged and Python Windows paths use the
  same TCP sink/endpoint arguments.
- Add normalized desired/spawned endpoint tracking and explicit restart states
  to `CanTelemetryBridge`.
- Replace the current spawn-only `respawn_gateway()` behavior with bounded,
  child-PID-scoped shutdown/exit/spawn sequencing.
- Drain stale heartbeat packets and require a post-spawn heartbeat before
  sending a deferred `ICT_START` or reporting ICT active.
- Preserve the accepted two-click toggle flow and reject invalid endpoints
  before lifecycle mutation.

## 3. Operator UI

- Route endpoint-aware connect through the bridge lifecycle API.
- Add a non-toggle timed CAN button and offline/error feedback.
- Keep the button repeatable so another click restarts the single gateway-side
  10-second window.

## 4. Focused tests

- Python control codec: command 6 round-trip and existing v1 byte compatibility.
- Pure scheduler with virtual monotonic time: immediate first slot, 20 ms cadence,
  500 nominal slots, completion, retrigger reset, and no overlapping rate.
- Sink fan-out: recording-only, ICT-only, and simultaneous paths.
- CSV/SocketCAN/PC001 golden checks for raw `0x18FFF100`, wire `0x98FFF100`, DLC
  8, payload bytes, and channel 0.
- Godot bridge tests: same endpoint avoids restart; changed endpoint stops the
  owned child and starts new argv; invalid endpoint is non-mutating; stale
  heartbeat cannot complete restart; OFF cancels pending ICT activation.
- Godot UI test: new button sends command 6 only when gateway is available and
  repeated clicks remain accepted.
- Focused real-process E2E: replacement listener accepts PC001 handshake on a
  new free port and triggered frames reach recording and TCP paths.

## 5. Validation and packaging

Run, in order:

1. `python -m unittest discover -s tools/can_gateway/tests`
2. Ruff check and format check for changed Python files.
3. Focused Godot standalone CAN/control tests, then the existing standalone
   matrix if focused checks pass.
4. `python tools/can_gateway/build_exe.py`
5. Isolated-port executable smoke with the bundled QML profile.
6. `git diff --check` and a final task/spec compliance review.

No QML build or QML-side runtime test is required; compatibility is established
through the unchanged PC001 contract and code/math-level transport tests.

## Risk and rollback points

- Before process-lifecycle edits, preserve the current known-good argv and
  heartbeat behavior in tests.
- Never terminate by executable name or port; only the exact bridge-owned PID is
  eligible for timeout fallback termination.
- Use dynamically allocated test ports to avoid interfering with an operator's
  existing gateway.
- Do not stage or modify unrelated working-tree files.
