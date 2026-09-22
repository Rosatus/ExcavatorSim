# Design — Physical telemetry WS mode

> **Deferred (paused) 2026-09-14.** The design below is frozen and complete;
> implementation has not started. Kept for reference, not superseded. See
> `prd.md` for the pause banner and resume point.

## 2026-09-22 preparation amendment

The authoritative updated scope and protocol assessment are in `prd.md`, “Preparation update — 2026-09-22”. Windows PCAN replaces Linux hardware acceptance; direct development replaces patch/snapshot delivery. Existing companion ingress is insufficient for semantic telemetry; reuse the PCAN backend and add only the required receiving/encoding/session integration. No business code has been implemented in this preparation pass. Earlier deferred/frozen wording and conflicting delivery/platform statements below are historical.

## 1. Where the line is drawn

Chain from simulation state to a CAN frame has five stages:

```
(1) 四元数/速度   ->  (2) 姿态解算        ->  (3) 协议量化       ->  (4) 编码          ->  (5) CAN 帧
    CTN1 UDP          MachineState            sensor_slots        DBC / struct        can_id+payload
                      link_rpy / QML proj     round((s+180)/.01)  Message.encode      + channel
```

The agreed boundary is **after stage (2)**: the Gateway ships semantic physical
quantities and the companion owns stages (3), (4) and (5). Stage (1) and (2)
stay in the Gateway because the semantic values depend on `conventions.py`,
the calibration layer and the QML projection.

Consequence: the companion must reproduce stage (3) exactly. That is the single
largest correctness risk in this work and is handled by §5.

## 2. Gateway components

| Concern | Today | New mode |
|---|---|---|
| Telemetry intake (UDP CTN1, heartbeat) | `gateway.py` | unchanged |
| Cadence | `FrameScheduler` | unchanged |
| Semantics | `MachineState`, `qml_compat`, `calibration.py` | unchanged |
| Physical-quantity settlement | inline inside `emit_frames()` | **new** `physical.py` producing a `PhysicalSample` |
| CAN encode | `dbc_engine`, `encoders/*` | not loaded |
| Sinks | `sinks.py`, `pc001_sink.py`, `can0_setup.py` | not loaded |
| CAN console / DBC runtime | `can_console.py`, `OperatorDbcRuntime` | not loaded |
| Web API | `gateway_web.py` | not started |
| Transport | sink dispatch | **new** WS client |

- **Mode selection uses a dedicated parameter, not a new `--mode` value.**
  `--output {physical, can}`, default `physical`. `--mode {standalone,
  godot-managed}` keeps its meaning as the legacy pipeline's supervision
  selector and is honoured only alongside `--output can`; combining `--mode`
  with `--output physical` is a hard error, so a stale command line can never
  silently fall back to the archived pipeline.
- The companion endpoint needs its own parameter, kept independent of mode
  selection. Proposed: `--ws-endpoint ws://HOST:PORT`, or a `--ws-host` /
  `--ws-port` pair mirroring the existing `--tcp-host` / `--tcp-port`, both
  defaulting through the `GatewayConfigStore` persistence pattern already used
  for the PC001 endpoint.
- `emit_frames()` keeps its current shape for legacy modes; the new mode calls a
  sibling `settle_physical()` that reuses the same scheduling and semantics but
  returns values instead of bytes.
- Backpressure: bounded queue with latest-value coalescing per `(family, key)`,
  non-blocking enqueue from the receive loop, exponential-backoff reconnect.
  Mirrors the existing can0 latest-value discipline; a slow or absent peer must
  never produce stale replay or stall intake.

## 3. WS topology and contract (draft, to be frozen as `protocol/physical-telemetry-ws-v1.schema.json`)

### 3.0 The three links

Only two of the three links are WebSocket, and the Gateway is a WS **client** on
the only one it owns:

| Link | Transport | Carries |
|---|---|---|
| Godot ↔ Gateway | UDP `:29764` + `:29765` | `:29764` telemetry CTN1 + control CTNC; `:29765` heartbeat CTNK, session-done CTND, ICT-result CTNR. Unchanged. |
| Gateway → companion | 1 WebSocket, 2 logical channels | `data` (lossy, coalesced) + `event` (no-drop). Gateway is the client. |
| Browser ↔ companion | REST + WS | REST `/api/*` for actions, WS `/ws` for server→client snapshots. Browser is the client. |

The browser never reaches the Gateway in the new mode, and it also carries over
no legacy status display: the old console's freshness and actual-frequency
columns are gone, and the Gateway's transport state (CAN interface, PC001 peer,
socket errors) is **not** surfaced in the new console either — in this mode the
Gateway does not manage CAN at all, so that state no longer exists. The new
console shows physical quantities plus the companion's own status. The `event`
channel is therefore session-integrity traffic only, not a browser-facing status
feed.

### 3.1 One connection, two channels

**One** WebSocket connection carries **two logical channels**, distinguished by
message type:

| Channel | Direction | Content | Discipline |
|---|---|---|---|
| `data` | gateway -> companion | `imu`, `slew`, `travel`, `rtk` | lossy by design; latest-value coalesced per `(family, key)`; own bounded queue |
| `event` | gateway -> companion | `hello`, `status`, `event` | never coalesced and never dropped; own queue. Session integrity only — never relayed to the browser |

Why one connection rather than two:

- One handshake, one reconnect/backoff state machine, one place to validate the
  `model` / `profile` / `calibration_sha256` fingerprint.
- What needs isolating is the *queue*, not the *socket* — coalescing is a
  sender-side policy. A second socket adds failure modes ("which one is up?",
  "which one does the peer trust?") and buys nothing.
- Cross-plane message ordering stays unambiguous.

A second physical link would only pay off if the status plane had to survive
independently (separate process or network path) or needed a different
transport. Neither applies here.

The Gateway has **no** browser-facing WS — the frontend is hosted by the
companion. Godot keeps its UDP control (CTNC) and heartbeat (CTNK) channels;
those are not WS and do not change.

### 3.2 Messages

Gateway -> companion, JSON text frames:

```
hello   { type, protocol_version, model, profile, calibration_sha256,
          rates_hz:{imu,slew,rtk,travel}, families:[...], source_clock_unix_s }
imu     { type, t_ms, links:{ body:[r,p,y], boom:[...], arm:[...], bucket:[...] } }   # 100 Hz
slew    { type, t_ms, angle_deg }                                                     # 100 Hz
travel  { type, t_ms, left, right }                                                   # 10 Hz; binarised 0/9, unit MPa
rtk     { type, t_ms, unix_s, lat, lon, alt, heading_deg, ve, vn, vu, speed,
          vice_lat, vice_lon, vice_alt, satellite_status }                            # 10 Hz
event   { type, level, code, detail }
```

- `t_ms` is the deterministic simulation tick (`sample.tick_ms`), not wall clock,
  so replay comparison is reproducible.
- `unix_s` is carried explicitly so the companion never substitutes its own
  clock for the GPS week/time frame.
- Handshake validation: the companion rejects a session whose `model` /
  `profile` / `calibration_sha256` disagrees with its own configuration.
- A slow or absent peer affects only the `data` channel: its queue coalesces and
  drops, while the `event` channel keeps flowing.
- `event` deliberately carries **no** Gateway-side transport or connection
  telemetry for the browser. It exists so the pair can validate the handshake
  and report session health to each other. The companion renders its own status
  in the console; the Gateway's archived CAN state is not resurrected.

## 4. Companion components

| Concern | Plan |
|---|---|
| WS input endpoint | new WebSocket route next to the existing snapshot `/ws`, same uvicorn process |
| Quantisation + encode | new `PhysicalFrameEncoder`: stage (3) + stage (4) |
| Frame delivery | reuse the transport-decoupled `injection_queue` so dashboard, recorder and `/ws` snapshot update unchanged |
| Physical CAN output | reuse the `09-04` fixed routing `ch0->can1`, `ch2->can4`, `ch3->can3` and its non-blocking bounded latest-value send |
| Frontend hosting | serve the bundle built from the **new** `tools/replay_console/` project; drop **all** legacy status display (freshness, actual frequency, Gateway transport state). The legacy `tools/can_gateway/web/` is not reused or moved. |
| Configuration | new `[physical]` TOML section (listen address/port, DBC machine, routing) |

Quantisation to reproduce, per family:

- IMU: `slots = (-pitch, roll, yaw)`; `count = round((slot + 180) / 0.01)`;
  clamp `[1, 65535]` (lower bound is 1 — a triple of zeros is the parser's
  invalid marker).
- Slew: degrees into the `ROTATE` DBC signal.
- Travel: the already-binarised `0` / `9` value arrives as-is and is packed
  unchanged (unit **MPa**). The companion must **not** re-derive it from speed.
  The frame is **not** in the DBC and is a raw struct with the first four bytes
  zero. The `kg` wording in `encoders/travel_pilot.py` and `README.md` is wrong
  and gets corrected to MPa (comments only, no numeric change).
- RTK: nine frames — origin conversion, six constants, secondary antenna at
  1.0 m opposite the heading, `+-327.67` bound clamping, and the GPS wall clock.

### 4.1 Frontend scope

Keep the existing console's skeleton and design, and port the companion TUI's
capability set into it.

Already available in the companion's own web dashboard, so reused rather than
rebuilt: message table, fuzzy search, channel / uploaded-message filters,
overwrite set and clear, materialise-and-inject for never-uploaded messages,
custom-frame injection, CSV / RRD / gRPC recording, info and help dialogs,
status text and capability flags.

New work, because these are TUI-only today:

| Item | Delta |
|---|---|
| Full DBC / protocol-CSV detail | 22-column protocol table plus per-signal scale, offset, range, unit, choices, multiplexer, comment, cycle time and senders. The current web detail view returns only name, start, length, byte order, signed, min, max, unit. |
| Progress bar | TUI has one; the web shows text only. |
| Overwrite period presets | TUI offers once / 20 ms / 50 ms and recalls the active period; the web is a free number field. |
| Parent-row overwrite highlighting | TUI marks the parent row orange and the signal rows yellow; the web colours child values only. |
| Search-hit highlighting | TUI bolds the matched substrings. |

Likely out of scope: the interactive start-up wizard and the Rich text fallback
renderer.

### 4.2 Frontend project location

The console is a **new standalone project** at `tools/replay_console/`, with its
own `package.json` / `vite.config.ts` / build output, and is served by the
companion.

Rationale: the legacy console at `tools/can_gateway/web/` is a *CAN* console —
its state model, its API client and its columns are all built around frames and
channels. The new console is a *physical-quantity* console whose data arrives
from the companion. Sharing a directory would mean either mutating a project we
have just archived, or threading two incompatible semantics through one codebase.
A separate directory keeps the archive intact and keeps each build independent.

What it *keeps* from the legacy console is the **visual skeleton and design**
(layout, panels, table styling, dialog patterns) — copied in as a starting
point and then re-pointed at the companion's API. What it must not carry over is
the freshness column, the actual-frequency column, the Gateway transport-state
indicators, or any Gateway REST/WS client. Status shown in the new console is
the companion's own, not the Gateway's.

Build wiring: `tools/build_gateway_dist.ps1` currently builds
`tools/can_gateway/web/` into `tools/can_gateway/resources/web/`. The legacy
build keeps working (the archive still needs its bundle). The new project gets
its own build step and its own output, and that output is what the companion
serves.

## 5. Byte-parity strategy

The acceptance criterion is that the companion's CAN frames are byte-identical
to today's Gateway frames. Approach, modelled on the successful calibration
refactor verification:

1. Record a **golden** digest from the legacy path: run `emit_frames()` over a
   fixed telemetry battery with the wall clock frozen, dump every
   `(can_id, payload, channel)` triple. (Freezing is mandatory — the RTK
   week/time frame is wall-clock derived, which already caused a false failure
   during the calibration refactor.)
2. Feed the same battery through the new path: Gateway physical settlement ->
   WS -> companion encoder -> frames, dump the same tuples.
3. Compare. All families, all scenarios, byte-for-byte.
4. To keep this runnable from one repository, the companion encoder is imported
   from its checkout path by the parity test, and the same fixtures are reused
   by a companion-side test.

Rounding note: both sides are Python, so porting the quantisation expressions
verbatim avoids the C `round` (half-away-from-zero) versus Python `round`
(half-to-even) trap. Do **not** re-derive `(slot + 180) / 0.01` as `* 100` —
`0.01` is not exactly representable and the two forms can disagree.

## 6. Migration impact

- `godot/client/scripts/can_telemetry_bridge.gd` currently passes
  `--mode godot-managed --sink tcp ...` explicitly. Because `--mode` together
  with the new default (`--output physical`) is a hard error, that argv would
  start failing the moment the default is flipped. The game migration therefore
  has to land **in the same release** as the default switch: either append
  `--output can` to keep the legacy pipeline, or — per R14 — migrate the game to
  the new mode altogether. There is no third option, and the failure is loud
  rather than silent, which is the point of making it an error.
- `godot/client/scripts/operator_ui.gd` holds the `[CAN 输出]` control; removing
  it also removes the `RECORD_START` / `RECORD_STOP` plumbing in
  `control_protocol.py` and the gateway's handling.
- Scripts and tests assuming the default is `standalone`/`tcp` need updating:
  `tools/can_gateway/smoke_frozen_gateway.py`,
  `tools/can_gateway/tests/test_gateway_process.py`,
  `godot/client/tests/run_standalone_matrix.ps1`.
- `tools/build_gateway_dist.ps1` bundles the legacy web assets into
  `tools/can_gateway/resources/web/`; that path keeps working for the archived
  pipeline. The new console at `tools/replay_console/` gets its own build and
  its own output, and the companion serves that output.
- The legacy CAN pipeline is **archived, not deleted**: `standalone` /
  `godot-managed`, `gateway_web.py`, the CAN console, the DBC runtime and the
  legacy frontend `tools/can_gateway/web/` stay in the tree, reachable only
  through explicit parameters, and are no longer developed. Nothing is removed,
  so the build script keeps bundling them.
- The travel unit correction touches `encoders/travel_pilot.py` comments and the
  `README.md` convention line; no bytes change.

## 7. Milestones

| # | Milestone | Acceptance |
|---|---|---|
| M1 | Contract frozen + Gateway physical layer (mode, `PhysicalSample`, WS client, backpressure) + loopback stub server | Gateway emits physical values only; no CAN loaded; reconnect and coalescing behave |
| M2 | Companion endpoint + encoder + vcan output | **Byte-parity harness green** across all families |
| M3 | New console project `tools/replay_console/` (skeleton copied from the legacy console, re-pointed at the companion), the TUI feature port (§4.1), and companion hosting | Physical-quantity view, no freshness/frequency, capability parity with the TUI |
| M4 | Game migration + script/test updates + patch delivery | `git apply --check` clean; snapshot comparison clean; suite at baseline |

M1 and the contract are the resume point. Every design choice is settled.
Two non-blocking items remain open, neither of which touches M1: whether the
Gateway keeps serving the *legacy* console bundle in legacy modes (working
assumption: yes), and the exact spelling of the companion-endpoint parameter
(`--ws-endpoint` vs `--ws-host` / `--ws-port`).

**The task is deferred as of 2026-09-14, so M1 has not started.** Milestones
M1–M4 above are unstarted scope, recorded so the work can resume without
re-planning.

## 8. Risks

| Risk | Mitigation |
|---|---|
| Companion quantisation drifts from the Gateway | Byte-parity harness (§5) as a hard gate; single source for constants |
| Duplicated constants diverge silently over time | Publish the constant/origin set as a shared artefact under `protocol/` and generate the companion's table from it |
| Default-mode switch breaks tests/scripts | Enumerate and update the three known call sites before flipping the default |
| WS backpressure stalls the UDP receive loop | Bounded queue + latest-value coalescing + non-blocking enqueue, mirroring the can0 discipline |
| GPS frame non-determinism hides a real regression | Always freeze the wall clock in parity runs |
| Travel direction is not representable on `0x256` | Document explicitly; the value ships already binarised and never claims direction |
| Archived legacy pipeline bit-rots silently | Keep its tests in the suite, and use its output as the parity harness reference |
| Default flip breaks the game's explicit `--mode` argv | Land the game migration in the same release; the mismatch is a hard error, so it surfaces immediately rather than degrading silently |
| The two console projects drift apart on shared visual design | New console copies the skeleton once at creation; no ongoing sync is promised, and the legacy console is frozen anyway |
| Frontend port scope grows without bound | §4.1 is the checklist; the start-up wizard and Rich fallback are explicitly excluded |
