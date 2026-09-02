# Current-state evidence

## Godot operator and child lifecycle

- `godot/client/scenes/main.tscn:480-485` defines `ICTConnectToggle` as a toggle with
  stale Linux-only text.
- `godot/client/scripts/operator_ui.gd:392-408` maps the pressed state to
  `set_ict_connected()` after endpoint validation; `:479-502` derives Connect/Disconnect
  labels from ICT active/requested rather than the Gateway lifecycle.
- `godot/client/scripts/can_telemetry_bridge.gd:249-260` already exposes
  `respawn_gateway()`. `:343-396` performs graceful shutdown, bounded wait, exact-owned-PID
  termination and respawn; `:321-340` shows that the PID authority comes from
  `OS.create_process`.
- `can_telemetry_bridge.gd:292-306` launches `--mode godot-managed --sink tcp` on both
  Windows and Linux. A lifecycle enum exists at `:34-35` but is not exposed to the UI.
- Existing E2E coverage at `godot/client/tests/can_gateway_e2e_test.gd:159-190` verifies
  endpoint reuse/rebind and fresh heartbeat; `:236-252` verifies respawn and immediate
  handshake reset.

## Why the ICT toggle is misleading

- `tools/can_gateway/gateway.py:303-332` constructs the TCP sink during Gateway startup.
- `gateway.py:398-406` includes any non-null TCP sink in active sinks without consulting
  ICT active/requested.
- `gateway.py:1002-1043` therefore acknowledges ICT_START when the TCP sink already
  exists; `:1044-1063` explicitly keeps TCP listening on ICT_STOP.
- `tools/can_gateway/pc001_sink.py:195-230` owns the independent physical handshake truth.
  Consequently Gateway process readiness, listener readiness and PC001 connectivity are
  three different states.

## Godot activity projection

- Godot emits CTN1 UDP telemetry at 50 Hz from
  `godot/client/scripts/can_telemetry_bridge.gd:630-669`.
- Gateway separates control packets from telemetry and accepts telemetry only after
  `parse_packet()` succeeds at `tools/can_gateway/gateway.py:975-982,1089-1110`.
- No Gateway status currently records last Godot telemetry. The status DTO and live
  projection are at `tools/can_gateway/gateway_runtime.py:50-81,542-588`; TypeScript
  allowlists are at `tools/can_gateway/web/src/types.ts:4-32,193-251`.
- A 2.5-second receive-time timeout mirrors the existing Godot-side heartbeat tolerance
  while allowing roughly 125 missed nominal telemetry periods. Standalone has no required
  Godot peer and therefore needs nullable/not-applicable state.

## Web table jitter

- `tools/can_gateway/web/src/components/CanConsole.tsx:273-280` formats variable-width
  millisecond/second strings; `:301-308` advances them with one 50 ms ticker.
- `CanConsole.tsx:358-386` uses default auto table layout. Only the disclosure column has
  a width; the freshness cell is monospaced but not fixed-width or nowrap.
- `>999s` caps age magnitude, not intrinsic text width. `table-fixed` plus a nine-column
  width authority and nowrap/tabular numeric cells removes the layout dependency without
  reducing realtime refresh.

## Safety and compatibility boundary

- `.trellis/spec/backend/can-gateway-control.md:66-76` already forbids process/port scans
  and restricts force termination to the exact owned PID. No Gateway PID file or instance
  token exists, so an unknown listener cannot be authenticated safely.
- `ict_active` remains in control/status internals for compatibility in this task; only its
  misleading product-UI projection is removed.
- CAN framing, DBC encoding, authority and PC001 transport semantics are not involved.
