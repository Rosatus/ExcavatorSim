# 09-25 Gateway supervision hardening (frozen build)

## Symptom

Exported `godot/dist/windows/ExcavatorSim.exe` permanently showed
"Gateway 异常，请重启"; Task Manager showed lingering `gateway.exe` entries.
Restarting the app never recovered.

## Root causes (all verified empirically)

1. `gateway.exe` is a PyInstaller **onefile** bundle: `OS.create_process` gets
   the bootloader pid; the real gateway is its child. Two processes is normal.
2. A stale headless `godot.windows.editor` test process held UDP `:::29765`
   (the ACK/heartbeat port) for hours — the game could never bind it, so no
   heartbeat could ever arrive.
3. `OS.kill` on the launcher pid orphans the child, which keeps holding UDP
   29764 / TCP 5678 — every later spawn dies on the port bind.
4. The 5 s startup deadline was tight for frozen cold starts; the kill fired
   while the child was still unpacking, creating the orphan in the first place.

## Fix (can_telemetry_bridge.gd)

- `_gateway_detached` adoption: heartbeats flowing with no live tracked pid →
  adopt the port owner; FAILED self-heals back to IDLE on resumed heartbeats.
- `_ensure_ack_bound` scans `ack_port..+16`; `_ack_port_bound` is passed to the
  spawned gateway as `--ack-port`.
- `spawn_gateway` emits a pre-spawn SHUTDOWN (port-addressed, no heartbeat
  needed) so an orphan is reclaimed before the new child binds.
- STOPPING for a detached gateway waits for heartbeat quiet
  (`GATEWAY_HEARTBEAT_QUIET_MS` = 1200) instead of a pid exit.
- `_kill_gateway_tree` uses `taskkill /T /F` on Windows (whole tree).
- Startup timeout 5 s → 20 s (frozen unpack + Python boot).
- Headless runs skip the ack auto-bind (tests bind explicitly) — this is what
  let a stale test squat on the production port in the first place.

## Evidence

- `gateway_detached_adoption_test.gd`: fake-heartbeat adoption, quiet-window
  respawn, FAILED self-heal, ack-port fallback argv propagation — PASS.
- Live artifact: zombie process squatting 29765 + orphaned gateway on 29764 →
  launched rebuilt exe → orphan reclaimed via SHUTDOWN, fresh pair spawned
  with `--ack-port 29766`, exactly one launcher+child pair, ONLINE.
- `gateway_restart_ui_test`, `ict_status_indicator_test`,
  `can_gateway_ict_result_test`, `can_gateway_e2e_test`,
  `can_qml_pose_checkpoint_test` all PASS. `map_switch_test` fails on clean
  baseline (unrelated driving-map excavation check).
