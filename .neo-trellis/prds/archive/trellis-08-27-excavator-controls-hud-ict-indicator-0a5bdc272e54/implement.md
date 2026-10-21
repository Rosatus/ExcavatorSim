# Implementation plan

## 1. Canonical keyboard layout

- [x] Update equipment action key definitions to WASD/IJKL while preserving action
  names, vector order, gamepad axes, and model multipliers.
- [x] Make equipment action setup replace stale keyboard events as well as stale
  joy-axis events.
- [x] Update track bindings to R/F and Y/H.
- [x] Update operator copy, scene fallback copy, integration documentation, and any
  visual-evidence expectations that expose the old keys.
- [x] Add independent exact-key and stale-binding regressions; exercise resolved
  opposite-direction zero and simultaneous independent axes.

## 2. Responsive control HUD

- [x] Create the bottom-right semi-transparent HUD scene and presentation-only
  script with named action tiles.
- [x] Apply recursive mouse-ignore behavior and action-by-action press styling.
- [x] Instantiate it under the operator CanvasLayer without disturbing the existing
  guide/modal ordering.
- [x] Add a standalone HUD test for viewport containment, alpha, all twelve labels,
  recursive mouse filtering, press/release, simultaneous actions, and opposing
  held-key visuals. Add the green test to the standalone matrix.

## 3. Physical ICT handshake status

- [x] Expose structured PC001 accepted-client state from the Python sink.
- [x] Add heartbeat flag `0x04` without changing v1 packet length or old helper
  behavior; set it only from the TCP sink's accepted handshake state.
- [x] Add bridge state/getter/signal and stale/restart clearing.
- [x] Add a compact round lamp and label beside the ICT control; render Windows
  red/green from the handshake getter and Linux/vcan as neutral N/A. Do not gate
  physical connection truth on forwarding state.
- [x] Extend protocol, sink, bridge/UI, and real-process E2E tests across pre-
  handshake, successful handshake, forwarding-off/still-green, disconnect,
  restart, and reconnect.

## 4. Validation

Run focused checks first, then full scope:

```powershell
python -m unittest discover -s tools/can_gateway/tests
pixi run ruff check tools/can_gateway
pixi run ruff format --check tools/can_gateway
godot --headless --path godot/client --script res://tests/motion_client_test.gd
godot --headless --path godot/client --script res://tests/tracked_chassis_locomotion_test.gd
godot --headless --path godot/client --script res://tests/control_input_hud_test.gd
godot --headless --path godot/client --script res://tests/can_gateway_e2e_test.gd
powershell -NoProfile -File godot/client/tests/run_standalone_matrix.ps1
pixi run verify
```

Build/smoke the packaged Windows gateway after Python protocol changes so the
runtime executable carries heartbeat bit `0x04`. Treat the known inaccessible
Windows `.venv-linux/lib64` symlink and the pre-existing excluded
`operator_ui_test.gd` failures as environmental/baseline facts, not reasons to
skip focused green tests.

## Risk and review gates

- Verify old equipment key events cannot coexist after repeated action setup.
- Verify the HUD observes semantic actions but never emits input or consumes
  mouse events.
- Verify heartbeat remains exactly 16 bytes and old bits/golden packets remain
  stable.
- Verify green is impossible before `_handshake()` succeeds and is cleared on
  stale/restart.
- Keep the four pre-existing QML profile working-tree paths outside this task's
  eventual commit unless separately authorized.
