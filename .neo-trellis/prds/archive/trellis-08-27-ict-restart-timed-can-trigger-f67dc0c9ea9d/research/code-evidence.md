# Code evidence

## Gateway lifecycle and ICT UI

- `godot/client/project.godot:20-23`: `CanTelemetryBridge` is an autoload, so its
  automatic spawn precedes main-scene `OperatorUI` configuration loading.
- `godot/client/scripts/can_telemetry_bridge.gd:141-167`: endpoint values are
  stored for the next spawn; `respawn_gateway()` currently calls
  `spawn_gateway()` without stopping the old process.
- `godot/client/scripts/can_telemetry_bridge.gd:229-238`: process creation owns
  the child PID but has no exit/restart state machine.
- `godot/client/scripts/operator_ui.gd:369-382` and
  `godot/client/scenes/main.tscn:467-472`: the ICT control is a toggle; OFF-to-ON
  applies endpoint values then calls `set_ict_connected(true)`.
- `tools/can_gateway/gateway.py:77-87`: TCP endpoint binding occurs only when the
  gateway process constructs `TcpPc001Sink`.

## Control and timed output

- `tools/can_gateway/control_protocol.py:3-5,24-28,38-50`: control v1 is fixed
  12-byte little-endian `<IBBHI>` and currently accepts commands 1 through 5.
- `godot/client/scripts/can_telemetry_bridge.gd:12-20,291-307`: Godot mirrors the
  Python command constants and packet layout.
- `tools/can_gateway/gateway.py:89-91,113-131`: the receive loop currently uses a
  50 ms timeout and emits normal frames only after telemetry packets arrive.
- `tools/can_gateway/gateway.py:98-111,172-186`: `active_sinks()` is the canonical
  fan-out point for recording and ICT outputs.
- `tools/can_gateway/sinks.py:17-22,30-40`: extended raw IDs receive
  `CAN_EFF_FLAG` while packing Linux `can_frame` bytes.
- `tools/can_gateway/csv_writer.py:33-60`: CSV expects exactly eight payload bytes
  and records raw IDs above `0x7ff` as extended frames.

## Tests and packaging

- `tools/can_gateway/tests/test_gateway.py:211-303`: Python tests already cover
  scheduler and control-codec behavior.
- `tools/can_gateway/tests/test_sinks.py:19-55` and
  `test_pc001_sink.py:76-120`: existing tests provide raw/EFF and real loopback
  PC001 patterns.
- `godot/client/tests/can_gateway_e2e_test.gd:54-105,128-186`: the focused Godot
  test already exercises a real Python gateway lifecycle and recording control.
- `godot/client/scripts/can_telemetry_bridge.gd:175-214`: the bundled Windows
  executable receives TCP sink arguments, while the current Python fallback
  does not; argument construction must be kept behaviorally aligned.
