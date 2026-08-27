# CAN Gateway Control And ICT Lifecycle

## Scenario: Endpoint-aware ICT supervision and timed CAN bursts

### 1. Scope / Trigger

Use this contract when changing the Godot operator controls, the locally spawned
`tools/can_gateway` process, the CTNC control packet, recording/ICT sink fan-out,
or the PC001 TCP listener lifecycle. QML and the ICT relay remain external,
unchanged consumers.

### 2. Signatures

```text
CTNC v1 = little-endian <u32 magic, u8 version, u8 command, u16 reserved, u32 seq>
command 1 = RECORD_START
command 2 = RECORD_STOP
command 3 = SHUTDOWN
command 4 = ICT_START
command 5 = ICT_STOP
command 6 = TIMED_CAN_START

CanTelemetryBridge.set_tcp_endpoint(host: String, port_text: String) -> bool
CanTelemetryBridge.set_ict_connected(enabled: bool) -> void
CanTelemetryBridge.trigger_timed_can() -> bool
CanTelemetryBridge.is_ict_handshake_connected() -> bool
CanTelemetryBridge.ict_link_status_changed(handshake_connected: bool, platform_linux: bool)
TcpPc001Sink.is_handshake_connected() -> bool
build_heartbeat(tick_ms: int, recording: bool, platform_linux: bool = false,
                ict_handshake: bool = false) -> bytes
TimedCanBurst.trigger(now_s: float) -> None
TimedCanBurst.service(now_s: float, sinks: list[FrameSink]) -> bool
```

Command 6 starts raw CAN ID `0x18FFF100`, DLC 8, payload
`01 00 00 00 00 00 00 00`, nominally every 20 ms for at most 10 seconds and
500 emissions.

The CTNK heartbeat remains the 16-byte little-endian v1 packet
`<u32 magic, u8 version, u8 flags, u16 reserved, u64 tick_ms>`. Flag `0x01`
means recording, `0x02` means Linux/vcan, and additive `0x04` means that the
TCP server currently stores a client accepted after `who` / `PC001`.

### 3. Contracts

- `CanTelemetryBridge` is the only owner of its gateway child PID, desired TCP
  endpoint, spawned endpoint, restart state, and deferred ICT request.
- The existing ICT toggle remains two-step: ON-to-OFF sends disconnect; the next
  OFF-to-ON validates the panel endpoint and reconnects.
- An equal desired/spawned endpoint reuses the child. A different endpoint sends
  shutdown, waits until the exact owned PID exits, drains stale ACK packets,
  resets heartbeat freshness, then spawns with the new endpoint.
- A replacement is not online and ICT is not active until a post-spawn heartbeat
  arrives. A stale heartbeat from the old child cannot complete startup.
- Forced termination is limited to the exact PID returned by
  `OS.create_process`; never scan or kill by process name or port.
- Windows native and Python-development launch paths share the same gateway
  argument builder and include `--sink tcp --tcp-host HOST --tcp-port PORT`.
- Command 6 only triggers the Python monotonic scheduler. Godot physics and CTN1
  telemetry cadence are not the timed frame clock.
- A repeat command 6 replaces the current burst with one new 10-second window.
  It does not queue, overlap, or increase the nominal 50 Hz rate.
- Each actual timed emission resolves `active_sinks()` at that instant and sends
  the same raw `(id, payload)` to recording and/or ICT sinks. A delayed loop
  skips missed slots instead of releasing a catch-up burst, and never runs past
  the 10-second deadline.
- CSV preserves raw ID `0x18FFF100`; SocketCAN/PC001 packing adds
  `CAN_EFF_FLAG`, yielding wire ID `0x98FFF100`. PC001 greeting, response and
  batch framing do not change.
- Physical PC001 handshake truth belongs to `TcpPc001Sink`: it becomes true
  only after the server sends `who`, accepts `PC001`, and stores that socket as
  the current client. Bad handshakes never set it; close, detected EOF/reset,
  replacement and gateway restart clear it.
- Only a `TcpPc001Sink` may set heartbeat flag `0x04`. CSV, SocketCAN/vcan and a
  missing sink leave it clear. Packet length/version and legacy heartbeat
  parser return values remain unchanged so older consumers ignore the bit.
- Godot keeps `_ict_handshake_connected` separate from forwarding intent and
  activation. Turning forwarding off does not clear a still-live physical
  socket, while spawn/restart and heartbeat expiry clear the projected state.
  Windows renders red/green from this projection; Linux/vcan renders neutral
  not-applicable rather than claiming a PC001 handshake.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Host is empty | Normalize to listener default `0.0.0.0` |
| Host is not IPv4/`localhost`, or port is not `1..65535` | Return `false`; do not mutate desired endpoint, child, or ICT state |
| OFF-to-ON endpoint equals spawned endpoint | Send/reuse ICT start without replacing PID |
| OFF-to-ON endpoint differs | Stop exact owned PID, wait for release, spawn new argv, await fresh heartbeat, then activate ICT |
| Child ignores graceful shutdown | Kill only that owned PID after the bounded grace period |
| Child still exists after termination grace | Enter explicit failed state; do not forget PID or start a competing listener |
| Child exits or never heartbeats during startup | Keep ICT inactive and expose an actionable gateway error |
| Timed trigger while gateway offline | Return `false`; emit no control packet |
| Timed trigger while active | Reset to one new window; no overlapping burst |
| Gateway loop is late | Emit at most one current frame, skip missed slots, stop at 10 seconds |
| No sink is active for a scheduled instant | Emit nowhere for that instant; do not create a hidden recording |
| TCP listener is up but no valid `PC001` response exists | Heartbeat `0x04` clear; Windows indicator red |
| Valid PC001 socket remains while forwarding is off | Heartbeat `0x04` set; indicator stays green |
| PC001 EOF/reset is detected | Clear current client; next heartbeat clears `0x04` |
| Gateway restart or heartbeat expiry | Godot clears handshake projection immediately; replacement must handshake again |
| Linux/vcan gateway | Heartbeat `0x02` set and `0x04` clear; UI renders neutral N/A |

### 5. Good / Base / Bad Cases

- Good: edit port while connected, click once to disconnect, click again; the
  old owned PID exits, a new PID binds the port, a fresh heartbeat arrives, and
  the unchanged relay performs `who` / `PC001`.
- Base: reconnect with the same normalized endpoint; PID remains stable and ICT
  start is sent without a restart.
- Good: recording and ICT are both available; command 6 feeds both sinks with
  identical raw frame data while PC001 adds only the EFF transport flag.
- Good: a PC001 client handshakes, forwarding is toggled off, and the lamp stays
  green until that physical socket disconnects.
- Base: gateway is online without a PC001 client; controls remain usable and
  the Windows lamp stays red/waiting. Linux/vcan shows neutral direct mode.
- Bad: call `spawn_gateway()` over a live listener, accept an old heartbeat as
  proof of the replacement, drive the 50 Hz burst from Godot physics packets,
  emit all missed slots in one catch-up burst, or use ICT request/active state
  as proof that a client completed the handshake.

### 6. Tests Required

- Control codec: exact 12-byte v1 round-trip for commands 1 through 6 and
  rejection of unknown commands.
- Virtual monotonic scheduler: immediate slot zero, 20 ms uninterrupted cadence,
  exactly 500 nominal frames, 10-second cutoff, restart-on-retrigger, no overlap,
  and no catch-up burst.
- Sink boundaries: CSV raw ID/payload, SocketCAN and loopback PC001 EFF ID,
  payload, DLC, and channel zero.
- Godot UI: non-toggle repeatable timed button, offline rejection, invalid
  endpoint non-mutation, and actionable status.
- Real-process Godot E2E: same endpoint preserves PID; changed endpoint changes
  PID, waits for a fresh heartbeat, records the spawned endpoint, and accepts
  an unchanged PC001 handshake on the new port. Retain the test TCP socket and
  assert flag/UI transitions across handshake, forwarding-off, disconnect,
  reconnect and gateway restart. A headless test that changes `ack_port` must
  close the autoload's already-bound ACK peer, clear its bound state and rebind;
  changing the exported integer alone does not move a live UDP socket.
- Protocol/sink unit tests assert exact 16-byte v1 size, additive `0x04`, legacy
  parser results, bad-handshake rejection, disconnect/close clearing and later
  reconnection.
- Packaged executable: start recording, send command 6 without CTN1 telemetry,
  observe repeated `0x18FFF100` CSV rows, verify physical handshake flag set /
  clear, then stop and shut down.

### 7. Wrong vs Correct

```text
Wrong: endpoint text edit -> spawn a second gateway -> old process still owns UDP/TCP ports
Correct: OFF-to-ON validation -> exact owned PID shutdown/exit -> new argv -> fresh heartbeat -> ICT_START

Wrong: Godot physics frame -> emit 0x18FFF100 -> visual/UDP stalls reduce or stop the command
Correct: CTNC command 6 -> Python monotonic deadline -> active_sinks() -> CSV and/or PC001

Wrong: pass 0x98FFF100 into CSV and PC001
Correct: pass raw 0x18FFF100 to sinks; transport packing alone adds CAN_EFF_FLAG

Wrong: ICT_START or a live gateway heartbeat -> green handshake lamp
Correct: accepted PC001 socket -> CTNK flag 0x04 -> Godot physical-handshake state -> green lamp

Wrong: headless E2E changes ack_port after autoload binding and assumes the socket moved
Correct: close/reset the test ACK peer, bind the isolated port, then spawn the gateway
```
