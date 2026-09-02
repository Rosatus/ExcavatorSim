# CAN Gateway Control And ICT Lifecycle

## Scenario: Endpoint-aware ICT supervision, physical can0, and timed CAN bursts

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

CTNR v1 = little-endian <u32 magic, u8 version, u8 command, u32 request_seq,
                        u16 result_code, u16 detail_len> + UTF-8 detail
magic = 0x43544E52, command = ICT_START, detail_len <= 160 bytes

result 0 = success
result 1 = unsupported ICT transport
result 2 = can0 missing
result 3 = helper/authorization unavailable
result 4 = privileged setup failed
result 5 = can0 post-check not ready
result 6 = AF_CAN socket open failed
result 7 = SocketCAN bind failed
result 8 = terminal SocketCAN send failed
result 9 = internal ICT failure

CanTelemetryBridge.set_tcp_endpoint(host: String, port_text: String) -> bool
CanTelemetryBridge.set_ict_connected(enabled: bool) -> void
CanTelemetryBridge.is_ict_connecting() -> bool
CanTelemetryBridge.is_ict_active() -> bool
CanTelemetryBridge.trigger_timed_can() -> bool
CanTelemetryBridge.is_ict_handshake_connected() -> bool
CanTelemetryBridge.ict_link_status_changed(handshake_connected: bool, platform_linux: bool)
TcpPc001Sink.is_handshake_connected() -> bool
build_heartbeat(tick_ms: int, recording: bool, platform_linux: bool = false,
                ict_handshake: bool = false) -> bytes
TimedCanBurst.trigger(now_s: float) -> None
TimedCanBurst.service(now_s: float, sinks: list[FrameSink]) -> bool

prepare_can0() -> CanInterfaceSnapshot
configure_can0() -> CanInterfaceSnapshot
```

Command 6 starts raw CAN ID `0x18FFF100`, DLC 8, payload
`01 00 00 00 00 00 00 00`, nominally every 20 ms for at most 10 seconds and
500 emissions.

The CTNK heartbeat remains the 16-byte little-endian v1 packet
`<u32 magic, u8 version, u8 flags, u16 reserved, u64 tick_ms>`. Flag `0x01`
means recording, `0x02` means Linux, and additive `0x04` means that the
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
- Linux product launch paths use `--sink socketcan --interface can0`. The
  retained `--sink vcan` path is development-only compatibility and must
  prepare the vcan device before binding it.
- Linux ICT_START first inspects driver-created `can0` through detailed
  iproute2 JSON. Ready means kind CAN, netdev UP, bitrate `250000`,
  `restart-ms=100`, `txqueuelen=10`, and a usable controller state. A ready
  interface is never cycled; a missing interface is never created.
- An unready/unverifiable can0 invokes exactly
  `sudo -n /usr/local/libexec/excavatorsim/can0-setup-helper`. The installed
  root helper accepts no arguments and runs down → bitrate/restart → queue → up
  → post-check under an exclusive lock. The complete transaction is serialized
  by `/run/excavatorsim/can0.lock`: the opened `/run` parent must be a real
  root-owned directory but may be group/other-writable for target compatibility;
  its `excavatorsim` child remains root-owned mode `0700`, and the persistent
  lock remains a root-owned mode `0600` regular inode with one link. The helper
  uses fd-relative no-follow opens, validates metadata after open, rejects
  unsafe existing child/lock objects before mutation, and maps every lock
  failure to sanitized `CAN0_SETUP_FAILED` output without a traceback. A
  writable `/run` can permit local denial of service through entry preoccupation,
  but never authorizes takeover or repair. Its `ip` executable and subprocess
  environment come from fixed system allowlists, not caller `PATH`.
- Godot treats ICT_START as connecting until a matching CTNR success arrives.
  Matching failure, terminal send failure, or timeout clears requested/active
  state; timeout also queues ICT_STOP so a helper that finishes late cannot
  silently activate physical sending. Late/mismatched CTNR packets are ignored.
- Gateway caches the last sequence-correlated ICT result so a duplicate start
  can resend it without another configure/bind operation. SocketCAN is briefly
  guarded after setup so a queued timeout STOP gets a receive turn before any
  physical frame is emitted.
- SocketCAN is non-blocking and uses a bounded latest-value slot per raw CAN
  ID with fair family/ID round-robin service. `ENOBUFS`, `EAGAIN`, and
  `EWOULDBLOCK` drop only the attempted physical occurrence and keep ICT
  active; other send errors remain terminal. CSV stays immediate and complete.
  Status exposes monotonic submitted/sent/congestion-dropped/coalesced/terminal
  totals, while per-source/family/ID diagnostics are aggregated at one-second
  windows rather than logged per frame.
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
  Windows renders red/green from this projection; Linux direct CAN renders neutral
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
| Linux gateway | Heartbeat `0x02` set and `0x04` clear; UI renders neutral N/A |
| can0 exists and exactly matches the fixed contract | Skip helper/down-up; bind directly; return matching CTNR success |
| can0 exists but is down, mismatched, stopped, or unverifiable | Run only the fixed helper transaction; post-verify before bind |
| can0 is absent | Do not create it; return result 2 with USB-CAN/driver guidance |
| Helper/sudoers is absent or `sudo -n` is denied | Fail without a prompt; return result 3 with installer guidance |
| `/run` is not a real root-owned directory, or the runtime child/lock has wrong owner, unsafe mode/type/link count, or cannot be opened/flocked | Run no mutation; return sanitized `CAN0_SETUP_FAILED` without traceback |
| SocketCAN send returns `ENOBUFS`, `EAGAIN`, or `EWOULDBLOCK` | Drop the attempted occurrence, increment congestion totals, stop that service turn, and keep ICT active |
| SocketCAN send returns another `OSError` | Latch one terminal error, purge pending values, stop timed/DBC sending, close ICT, and report result 8 |
| A timed generation reaches its deadline, is retriggered, or is stopped | Purge that generation's pending physical slot; never send it after the window |
| Setup/post-check/open/bind/send fails | Return its distinct result code; do not claim active ICT |
| CTNR sequence is late or mismatched | Ignore it without mutating the current request |
| CTNR detail is oversized, malformed, or invalid UTF-8 | Ignore the packet |
| Godot waits past the ICT result deadline | Send ICT_STOP, clear pending/requested state, and expose timeout |

### 5. Good / Base / Bad Cases

- Good: edit port while connected, click once to disconnect, click again; the
  old owned PID exits, a new PID binds the port, a fresh heartbeat arrives, and
  the unchanged relay performs `who` / `PC001`.
- Base: reconnect with the same normalized endpoint; PID remains stable and ICT
  start is sent without a restart.
- Good: can0 already proves `250000 / 100 / 10 / UP / usable`; Connect ICT
  binds it without any privileged call or down/up interruption.
- Good: can0 is present but mismatched; the fixed installed helper configures
  it, post-verification succeeds, bind completes, and only then CTNR success
  makes the UI connected.
- Base: setup exceeds the Godot result deadline; Godot queues STOP and a later
  helper completion is retired before physical forwarding starts.
- Bad: treat existence or UP alone as readiness, construct can0 virtually,
  authorize a parameterized root command, prompt for sudo, or mark the UI
  connected before a matching CTNR success.
- Good: recording and ICT are both available; command 6 feeds both sinks with
  identical raw frame data while PC001 adds only the EFF transport flag.
- Good: a PC001 client handshakes, forwarding is toggled off, and the lamp stays
  green until that physical socket disconnects.
- Base: gateway is online without a PC001 client; controls remain usable and
  the Windows lamp stays red/waiting. Linux direct CAN shows neutral mode.
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
- can0 setup unit tests inject command runners and assert ready no-op, missing
  fail-closed behavior, exact mutation order, stopped/mismatched detection,
  post-verification, fixed executable/environment, non-interactive fixed helper
  invocation, root-only fd-relative lock metadata and syscall failures,
  transaction-level mutual exclusion, and preservation of the original DOWN
  state on a failed transaction.
- SocketCAN tests assert non-blocking setup, one latest slot per raw ID, bounded
  capacity, family/ID fairness, all recoverable errno aliases, terminal
  retirement, finite service budgets, aggregate status/events, CSV independence,
  and generation purge at timed deadline/retrigger/stop.
- CTNR tests assert exact little-endian fields, 160-byte/strict-UTF-8 bounds,
  sequence matching, duplicate replay, timeout cancellation, and distinct
  missing/helper/setup/not-ready/open/bind/send state transitions.
- Linux distribution validation asserts both `gateway` and
  `can0-setup-helper` are ELF executables, installer/uninstaller scripts are
  present, staged sudoers passes `visudo -cf`, and the helper accepts no args.
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

Wrong: Connect ICT -> bind/create can0 or run `sudo ip ...` with runtime parameters -> immediately show connected
Correct: inspect fixed can0 -> fixed `sudo -n` helper only if needed -> post-check -> bind -> matching CTNR success -> connected

Wrong: trust a path-only `/run` check, open a helper lock directly under its writable parent, or repair an unsafe inode in place
Correct: fd-open root-owned `/run` -> strict root-only `excavatorsim/` -> no-follow regular singleton lock -> complete transaction

Wrong: blocking `send()` or treating `ENOBUFS` as disconnect -> replay seconds of stale telemetry or drop ICT
Correct: submit latest value per ID -> fair bounded non-blocking service -> count/drop congestion -> retain ICT

Wrong: `SocketCanSink(vcan0)` -> create/enable missing vcan0
Correct: create/enable development vcan0 -> `SocketCanSink(vcan0)`
```

## Scenario: Local Web DBC console and shared encoding authority

### 1. Scope / Trigger

Use this contract when changing the Gateway Web API/UI, DBC discovery or persisted
operator values, periodic scheduling, Godot-to-CAN projection, or packaged Gateway assets.

### 2. Signatures

```text
gateway.py --mode {standalone,godot-managed} --web-port PORT [--open-browser]
           [--dbc-dir DIR ...]
GET  /api/v1/status | /api/v1/dbc | /api/v1/events?after=SEQ
PUT  /api/v1/dbc/messages/{message_key}
POST /api/v1/dbc/messages/{message_key}/preview
POST /api/v1/dbc/{start,stop,reload}
PUT  /api/v1/transport/tcp
POST /api/v1/transport/can0/restart
```

### 3. Contracts

- Web binds only `127.0.0.1`; default port is `29777`. `godot-managed` exposes status,
  statistics, events and row-level CAN authority/custom editing; transport, global arm,
  DBC reload and profile import/export remain HTTP 403.
- `standalone` exposes only the host platform transport: Windows TCP rebind or Linux
  confirmed can0 restart. Every mutation includes `expected_revision` and a bounded
  `request_id`; only the Gateway owner loop performs transport or scheduler mutation.
  The pure preview endpoint needs no revision and is owner-serialized without applying
  mutation revision checks. `GET /api/v1/dbc` returns status and DBC from one atomic
  publication boundary so the editor cannot combine different revisions.
- DBC discovery scans bundled `resources/dbc`, frozen-executable-adjacent `dbc`, and each
  explicit `--dbc-dir` non-recursively. Files are content-hash deduplicated; byte-identical
  bundled/adjacent copies collapse silently while retaining every source path. Decode each
  file strictly as UTF-8 (BOM allowed), then strict CP1252 with an encoding-fallback notice;
  malformed files remain isolated instead of dropping the healthy catalog.
- Each message has one canonical exact-DLC payload, independent `enabled`, and integer
  `frequency_hz` in `1..100` (default 50). `PUT` accepts at most one of `values` or
  `payload_hex`; either edit is converted to the canonical payload atomically. Signal edits
  preserve bits not modeled by the DBC. An unchanged mux preserves inactive-branch bits;
  changing its selector clears the complete old/new branch union before writing the active
  branch, so stale modeled values cannot reappear. `POST .../preview` accepts exactly one edit source,
  returns normalized values plus spaced uppercase payload, and never changes revision,
  persistence, scheduler state, or events. The scheduler skips missed slots rather than
  catch-up bursting.
- Godot telemetry and Web operator values are distinct sources but both pass through the
  hash-bound strict DBC codec before the shared Gateway send core. A800 velocity signals
  follow the approved DBC little-endian layout. DBC reload never changes the protocol
  catalog already bound to Godot telemetry.
- Estimated CAN load is informational: high load emits a visible warning but never blocks
  sending. Non-8-byte DBC messages preserve their real DLC at every sink boundary.
- Operator configuration persists compact uppercase `payload_hex` atomically against DBC
  content/message identity; display signal values are always decoded projections rather
  than a second stored authority. Schema-1 value records migrate through the bound codec;
  changed or absent layouts cannot silently inherit stale values.
- Production Web assets are built from `tools/can_gateway/web` into
  `resources/web`; packaged artifacts include those assets plus both approved DBC files.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| Non-local browser origin opens event WebSocket | `403 origin_forbidden` |
| Transport/global arm/reload/import/export in `godot-managed` | `403 managed_mode_read_only` |
| Windows requests can0 or Linux requests TCP | `409 capability_unavailable` |
| Missing/old revision | `revision_invalid` or revision conflict; no mutation |
| Frequency is bool, non-integer, `<1`, or `>100` | reject; preserve previous config |
| Signal is unknown, non-finite, out of range, or cannot encode strictly | reject whole message update |
| Both/neither `values` and `payload_hex` are supplied to preview | reject with typed edit-source error; no mutation |
| Raw payload has non-hex syntax or byte count different from message DLC | `dbc_payload_invalid`; preserve prior payload |
| can0 restart omits `confirm=true` | `confirmation_required` |
| One DBC is malformed | keep healthy files; report notice |
| Two DBC sources have identical bytes | collapse silently; retain both source paths |
| UTF-8 decode fails but strict CP1252 succeeds | load file and report `dbc_encoding_fallback` |
| Owner loop misses periodic deadlines | emit at most one current slot; skip backlog |

### 5. Good / Base / Bad Cases

- Good: Web edits one A800 signal, enables 20 Hz, and the resulting little-endian frame
  uses the same codec/send core as Godot telemetry.
- Good: Web enters an exact-DLC raw payload, receives a side-effect-free decoded preview,
  then explicitly saves; the exact bytes become the send/persistence authority.
- Base: Gateway is Godot-managed; transport/global controls remain absent while each
  simulation-capable CAN row can be switched for the current session to off/custom.
- Bad: let the Web thread replace sinks directly, keep a second handwritten A800 codec,
  persist payload and values as competing authorities, reuse persisted data after a DBC
  hash change, or pad a short DBC frame's wire DLC to 8.

### 6. Tests Required

- API contract tests cover local-origin events, typed errors, revision conflicts, mode and
  platform capability gates, TCP rebind, confirmed can0 restart, and static SPA fallback.
- DBC tests cover deterministic discovery/deduplication, parse isolation, strict encode,
  UTF-8/CP1252 behavior, raw payload validation/decode, modeled-bit merge with reserved-bit
  preservation, mux/endian cases, schema migration, hash-bound payload persistence, reload
  isolation, per-message rates, no catch-up, and load math.
- Differential tests compare every Godot-mapped RTK/IMU frame against cantools, including
  A800 little endian and a process-level PC001 wire assertion with the real DLC.
- Frontend tests cover managed read-only state, platform-specific controls, confirmation,
  contract/error rendering, live-event sequence gaps, 1..100 Hz integer inputs, payload
  preview synchronization, invalid/incomplete payload suppression, and explicit-save-only
  persistence.
- Packaging smoke starts the frozen Windows binary, loads `/`, `/api/v1/status`, Web assets,
  and adjacent DBCs; Linux packaging validates Web/DBC inclusion and helper preservation.

### 7. Wrong vs Correct

```text
Wrong: Godot encoder -> sink, Web DBC encoder -> separate sink path
Correct: Godot values or Web values -> shared strict DBC codec -> Gateway send core -> TCP/can0

Wrong: aiohttp thread mutates the live TCP/can0 sink
Correct: HTTP validates -> bounded command queue -> single owner loop mutates runtime state

Wrong: load warning disables Start
Correct: estimate and warn; keep operator control available

Wrong: persist values and payload separately, or mutate state on every preview keystroke
Correct: preview through the codec without side effects -> explicit save -> one canonical payload

Wrong: emit an operator warning for byte-identical bundled and adjacent DBC copies
Correct: content-hash collapse silently -> expose all source paths on the one catalog entry
```

## Scenario: Per-ID CAN authority console and transport-egress projection

### 1. Scope / Trigger

Use this contract when changing `can_console.py`, Godot telemetry gating, custom scheduling,
the `/api/v1/can-console` API, PC001/SocketCAN success callbacks, or the React row console.
The goal is one sending authority per CAN identity without changing any encoder or wire bytes.

### 2. Signatures

```text
CAN identity = (is_extended, arbitration_id)
API key = eff:18FF3A00 | sff:00000256
authority = off | custom | simulation

GET  /api/v1/can-console
PUT  /api/v1/can-console/messages/{key}
POST /api/v1/can-console/messages/{key}/preview
PUT  /api/v1/can-console/messages/{key}/authority
POST /api/v1/can-console/{start,stop,export,import}

WebSocket event kind = can_console_runtime
portable format = excavatorsim-can-console, schema_version=1
internal store = can-console.json, schema_version=3
```

`GET /api/v1/can-console` returns one status/config publication plus
`server_monotonic_s`. Each row contains descriptor, custom payload/values/frequency,
selected authority, expected frequency, capabilities, and runtime egress projection.

### 3. Contracts

- `CanConsoleRuntime` is owner-loop-only. `emit_frames()` may submit a continuous Godot
  RTK/IMU/slew/travel frame only when that canonical ID selects `simulation`; the shared
  custom scheduler may submit it only when it selects `custom`. Timed `0x18FFF100` bypasses
  this gate and retains its explicit 50 Hz / 10 second command contract.
- DBC rows reuse `DbcCodec`; native slew/travel rows reuse `encode_slew_frame` /
  `decode_slew` and `encode_travel_frame` / `decode_travel`. No UI or console module may
  copy their byte-order, scale, DLC or EFF packing rules. Native byte-valued status and
  pilot-pressure fields are integer-only; preview/save rejects fractional values instead
  of silently truncating them.
- Standalone restores off/custom, payload and integer `1..100` Hz but always starts
  globally disarmed. Godot-managed starts simulation-capable IDs at simulation and other
  IDs off; its row overrides and custom drafts are session-only. A TCP listener that is
  ready but has no completed PC001 handshake, or a transient PC001 disconnect, does not
  reset managed row authority: the sink drops offline occurrences without replay, and
  retained custom rows resume on a later handshake. Managed overrides are reset only by
  an explicit session reset, process restart, or a real terminal transport retirement.
- Managed API allows only row preview/save/authority. TCP/can0 mutation, DBC reload,
  standalone start/stop, portable import/export remain server-side 403.
- Successful transport egress means SocketCAN nonblocking `send()` returned or one PC001
  `sendall(batch)` returned. Queue submission, CSV append, congestion/coalescing and
  inferred handshake readiness never update freshness. This is not physical bus ACK.
- The tracker keeps last payload/decoded values and at most 10 successful monotonic
  timestamps per canonical ID. Actual Hz is null before two samples, otherwise
  `(n-1)/(last-first)`. Authority change clears rate samples but retains last payload.
- Dirty row runtime state and changed Gateway runtime counters are emitted in one typed
  `can_console_runtime` batch at most every 50 ms over the existing sequence/gap-aware
  WebSocket. React applies its typed status projection to the runtime summary and uses one
  shared 50 ms ticker to advance freshness; components do not create per-row timers, add
  high-frequency HTTP polling, or parse raw event fields.
- Portable import is full-profile replacement. It requires exact top-level/message field
  allowlists, format/schema/catalog/descriptor fingerprints, all catalog keys, exact DLC,
  off/custom authority and integer frequency. Candidate validation and atomic persistence
  complete before live state changes; machine transport, theme, arm and metrics are absent.
- Standalone DBC reload rebuilds the unified console from the reloaded operator catalog
  before publishing the new snapshot. Old descriptor keys and scheduler entries must not
  survive reload, and the rebuilt custom scheduler remains disarmed.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| SFF and EFF share numeric arbitration ID | Different canonical keys; never merge |
| Standalone selects simulation | `409 console_simulation_unavailable`; no mutation |
| Message is not custom when preview/save is requested | `409 console_message_not_custom` |
| Managed transport/global/import/export request | HTTP 403 before owner queue |
| Unknown authority or message | stable `console_authority_invalid` / `console_message_unknown` |
| Import has unknown/missing fields, keys or wrong DLC | reject entire candidate; no revision/write |
| Import fingerprint differs | `409 console_profile_incompatible`; no partial state |
| SocketCAN congestion/coalescing or TCP write failure | no freshness/rate update |
| Authority changes with pending SocketCAN value | purge that CAN ID before new authority sends |
| Fewer than two successful egress samples | actual frequency is null, not zero |
| WebSocket gap/unknown event | refresh atomic HTTP snapshot |
| Fractional native integer-only value | `dbc_value_invalid`; preserve previous payload |
| Standalone DBC reload changes catalog | rebuild console rows/scheduler; remain disarmed |

### 5. Good / Base / Bad Cases

- Good: a managed IMU row switches simulation → custom; its pending simulation value is
  purged, only the saved custom payload is scheduled, and a later switch back restores
  simulation without changing any sibling ID.
- Base: standalone restores several custom selections after restart but emits none until
  the operator explicitly presses Start.
- Good: one TCP batch contains several IDs; wire bytes remain identical and each metadata
  item is recorded only after the shared `sendall` returns.
- Bad: use SocketCAN last-value coalescing as authority arbitration, update freshness when a
  frame is enqueued, persist managed overrides, or let the browser reimplement CAN decoding.

### 6. Tests Required

- Console unit tests: canonical SFF/EFF identity, DBC/native payload round trips, managed
  defaults/override/reset, standalone restore-but-disarmed, scheduler gate and timed bypass.
- Persistence tests: full export/import round trip plus wrong catalog, missing/unknown key,
  invalid frequency/DLC and write-failure zero-side-effect cases.
- Runtime tests: rolling 10-sample mean, warm-up null, authority rate reset retaining last
  payload, decoded values, bounded dirty state and 50 ms event coalescing.
- Sink tests: PC001 byte-for-byte framing and callbacks only after successful batch writes;
  SocketCAN sent vs congestion/coalesced/terminal outcome separation and per-ID purge.
- API tests: standalone/managed permission matrix, revision/request ID, strict JSON, atomic
  snapshot and existing WebSocket replay/gap recovery.
- Frontend tests: theme persistence, row expansion, capability-aware three-state radio,
  modal bidirectional preview/explicit save, runtime delta reducer and freshness boundaries.

### 7. Wrong vs Correct

```text
Wrong: Godot producer + Web scheduler -> same CAN ID -> sink coalescing decides the winner
Correct: producer/scheduler -> canonical per-ID authority gate -> shared send core

Wrong: append/enqueue/handshake ready -> mark payload sent and freshness green
Correct: SocketCAN send() / TCP sendall() returns -> egress tracker -> bounded WS delta

Wrong: managed mode hides buttons in React but accepts forbidden server mutations
Correct: React reflects capability -> HTTP allowlist rejects forbidden endpoints -> owner loop mutates rows only
```

## Scenario: DBC-v2 channel projection and cross-platform TCP default

This scenario supersedes older clauses in this file that described Linux
SocketCAN as the product default, treated `0x18FFF000` as native, let timed CAN
bypass authority, or named console schemas 3/1.

### 1. Scope / Trigger

Use this contract when changing the approved DBC bundle, CAN occurrence metadata,
CSV/PC001 sinks, CLI/Godot transport selection, console authority, persistence, or
the React bulk controls. It prevents one payload from acquiring different channel,
authority, or transport semantics in different layers.

### 2. Signatures

```text
CanChannel = ch0 | ch2 | ch3
append_frame(sink, can_id, payload, *, channel, source, family, generation?, is_extended?)

PUT /api/v1/can-console/authority
body = {authority: off|custom|simulation, expected_revision: int, request_id?: string}
result = {authority: string, forced_off: string[], status: GatewayStatus}

portable format = excavatorsim-can-console, schema_version=2
internal store = can-console.json, schema_version=4
```

CLI default is `--sink tcp` on Windows and Linux. Linux direct CAN exists only as
explicit `--sink socketcan --interface can0` low-latency compatibility mode and is
temporarily unmaintained.

### 3. Contracts

- The hash-bound approved CAN3/CAN4 bundle contains 30 DBC identities. All of
  them, including `0x18FFF000`, use `DbcCodec`; only `0x18FFF100` and `0x256`
  have native descriptors.
- Channel is one narrow value carried from descriptor/producer into every sink:
  CAN3 and `0x18FFF100`=`ch3`, CAN4=`ch2`, `0x256`=`ch0`. CSV writes the text;
  PC001 writes trailing little-endian i32 `3/2/0`. PC001 handshake, batch prefix,
  16-byte CAN frame, EFF, DLC and payload bytes do not change.
- A DBC message must provide one non-conflicting CAN3/CAN4 family indication.
  Missing/conflicting evidence fails catalog parsing; code must not guess a
  channel from arbitration-ID ranges.
- Web transport mutations are gated by active `transport_kind`, never host OS.
  TCP rebind is available for standalone TCP on both platforms; can0 restart is
  available only in standalone explicit SocketCAN mode. Default Linux startup
  must not inspect/configure can0 or invoke its helper.
- `0x18FFF100` is a channel-ch3 EFF/DLC-8 row with no physical signals. Off
  rejects CTNC command 6 and custom scheduling; custom continuously schedules
  the saved exact-DLC payload at integer 1..100 Hz; simulation admits the fixed
  payload 50 Hz / 10 second / at-most-500 burst with replacement retrigger and
  no catch-up.
- The bulk endpoint is one owner-loop transaction: one revision check, one
  schedule rebuild/purge, one persistence, one event/revision. Managed
  all-simulation sets capable rows including `0x18FFF100` to simulation and
  returns unsupported rows in `forced_off`; standalone all-simulation fails
  before mutation.
- Schema-3 internal and schema-1 explicitly imported portable records migrate
  only when descriptor compatibility is proven. New/incompatible rows use mode
  defaults and emit an aggregate migrated/reset/added/removed notice. Legacy
  operator `dbc-config.json` remains schema 2 and safely misses SHA-bound keys.

### 4. Validation & Error Matrix

| Condition | Required behavior |
|---|---|
| DBC source has missing/conflicting CAN family evidence | catalog parse failure; no sendable row |
| Unknown logical channel | reject before CSV/PC001 projection |
| Standalone single/bulk simulation | `409 console_simulation_unavailable`; zero mutation |
| Timed command while row is off/custom | ignore with stable aggregate diagnostic; emit zero timed frames |
| Bulk revision stale or persistence fails | zero partial row changes; preserve previous schedule |
| TCP endpoint called for SocketCAN, or can0 endpoint called for TCP | `409 capability_unavailable` |
| Schema/descriptor incompatible | safe mode default plus aggregate reset notice |

### 5. Good / Base / Bad Cases

- Good: one mixed PC001 batch contains a CAN3 frame with channel 3, CAN4 with 2,
  and travel with 0 while each CAN frame's original bytes remain unchanged.
- Base: Linux starts without special parameters, binds PC001 TCP, and executes no
  can0 readiness/helper code.
- Good: managed “all simulation” includes timed CAN but closes unsupported DBC
  rows and reports their keys once.
- Bad: React loops per-row mutations, a sink infers channel from ID, or command 6
  emits timed CAN while the row is custom/off.

### 6. Tests Required

- DBC/hash tests assert exact approved hashes, 30 messages, channel evidence,
  duplicate collapse, `0x18FFF000` DLC-8 little-endian and A800 little-endian.
- Sink tests assert CSV channel text and PC001 i32 `0/2/3` in single and mixed
  batches while CAN-frame bytes and EFF remain byte-exact.
- CLI/process and Godot argv tests assert both platforms default TCP and spy that
  default Linux performs zero can0/helper calls; explicit SocketCAN remains.
- Console/API tests cover timed three-state gating, bulk atomicity/forced-off,
  schema 3/1 migration, schema 4/2 round trips and persistence rollback.
- Frontend tests cover channel column, three bulk buttons, forced-off summary and
  raw-only timed editing. Run fast code checks during development; run the full
  Python/React/Godot matrix once after implementation stabilizes.

### 7. Wrong vs Correct

```text
Wrong: OS -> transport controls; CAN ID -> guessed channel; timed -> bypass gate
Correct: active sink -> capability; descriptor -> channel; authority -> every producer

Wrong: one React request per row -> partial bulk state and many revisions
Correct: one bulk API -> one owner transaction -> one snapshot event
```
