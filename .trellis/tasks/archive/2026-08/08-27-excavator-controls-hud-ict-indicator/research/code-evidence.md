# Code evidence

## Input authority

- `godot/client/scripts/motion_client.gd:30-40` owns the eight equipment action
  definitions. `:861-869` fixes the command order as `(swing, boom, arm,
  bucket)`, and `:969-1014` installs keyboard/gamepad events.
- `godot/client/scripts/product_session.gd:139-147` reads the same four actions
  for the default local-authority path.
- `godot/client/scripts/tracked_chassis_controller.gd:5-10` owns the four track
  definitions; `:433-448` resolves each track as forward minus reverse; and
  `:661-675` replaces stale keyboard/gamepad events.
- `docs/godot-integration.md:75-84` and
  `godot/client/scripts/operator_ui_strings.gd:7-10` establish the ISO control
  meaning and current user-facing copy.
- The product camera uses `1..5` and `C`, not the requested keys
  (`godot/client/scripts/camera_rig.gd:19-26,395-404`). WASD use under
  `godot/client/demo/` does not belong to the product main scene.

## HUD boundary

- `godot/client/scenes/main.tscn:320-328` anchors the existing status panel at
  the upper left; the lower right is available. `godot/client/project.godot:25-30`
  uses `canvas_items`/`expand` stretch.
- `godot/client/scenes/main.tscn:141-153` provides the established translucent
  dark-panel visual language. `godot/client/scripts/operator_ui.gd:701-706`
  provides existing green/amber/neutral status colors.
- `godot/client/tests/operator_ui_test.gd:73-87` establishes 1280x720 and
  1920x1080 layout checks, but that script has unrelated known baseline
  failures and is excluded by `run_standalone_matrix.ps1:9-45`; the new HUD
  needs its own focused green test.

## ICT handshake truth

- `tools/can_gateway/pc001_sink.py:92-120` sends `who`, validates `PC001`, and
  assigns `_client` only after success. `:122-141,174-194` clears it on detected
  disconnect/send failure.
- `tools/can_gateway/control_protocol.py:44-95` defines the 16-byte v1 heartbeat
  and its existing `0x01` recording and `0x02` Linux flags. Unknown bits are not
  rejected, so `0x04` is backward-compatible.
- `godot/client/scripts/can_telemetry_bridge.gd:128-139,190-215,363-367` proves
  gateway-online, ICT-requested, and ICT-active are process/control intent, not
  PC001 handshake state. `:420-435` is the heartbeat decode boundary.
- `godot/client/scripts/operator_ui.gd:414-467` currently renders ICT state from
  `is_ict_requested()` and has no client-handshake indicator.
- `godot/client/tests/can_gateway_e2e_test.gd:125-157,257-282` already launches
  the real gateway, changes the endpoint, and performs the unchanged
  `who/PC001` exchange, making it the correct cross-layer regression seam.

## Test seams

- `godot/client/tests/motion_client_test.gd:303-329` and
  `tracked_chassis_locomotion_test.gd:162-190` verify action event shapes, but
  currently derive expectations from production constants; new exact-key
  assertions must use independent expected maps.
- `tools/can_gateway/tests/test_pc001_sink.py:76-107,163-182` covers good/bad
  handshake and disconnect/requeue; it can verify a structured handshake-state
  accessor.
- `tools/can_gateway/tests/test_gateway.py:302-319` owns heartbeat golden/flag
  compatibility tests.
