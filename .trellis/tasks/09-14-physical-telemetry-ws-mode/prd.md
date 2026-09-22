# Physical telemetry WS mode (gateway default, Linux-side CAN assembly)

> **Status: DEFERRED (paused) — 2026-09-14.**
> Planning is complete and locked; **no code has been written**. Implementation
> is postponed at the operator's request. The task stays in
> `.trellis/tasks/` unarchived — it is not abandoned and nothing here is
> superseded. Resume by starting M1: freeze the WS schema under `protocol/`,
> then build the Gateway's physical layer.

## Preparation update — 2026-09-22 (supersedes conflicting older text)

Implementation preparation has resumed; no business code has been changed in this preparation pass. The earlier Linux-only and patch-delivery requirements below are historical and superseded here.

Confirmed with the operator:
- Companion checkout: `C:\code\tools\can_replay` (the supplied `C:\code\tools\can\_replay` does not exist). Inspected baseline: `68a8920`, clean working tree.
- Acceptance target: Windows PCAN. This is an output-backend choice; reuse the existing backend. Linux hardware acceptance is not required for this task.
- Develop and verify directly. No original/modified snapshots or patch generation are currently required. Prefer no companion changes where its existing protocol suffices; assess that before implementation.
- Game UI keeps WS endpoint configuration and connection status. Remove the game-side CAN recording, TCP endpoint, ICT and timed-CAN operation entries; CAN operations belong in the replay console. Preserve the explicit legacy CAN pipeline's compatibility.
- On telemetry timeout or WS disconnect, stop CAN output originating from that telemetry source. Retain last displayed values marked disconnected/stale. Resume only with fresh data, without queued stale replay. Independent user-created injection is a separate source.

Existing-protocol assessment (source inspection, not a runtime test):
- `web_dashboard.py:create_web_app`: `/ws` accepts `ping`, `state`, and `filter`; it has no physical telemetry ingestion or identity handshake. Thus the older statement that it rejects all client data is inaccurate.
- `/api/inject` calls `build_custom_frame` with channel, CAN ID, payload bytes and frame format. PC001 likewise carries already encoded CAN frames. Neither accepts semantic IMU/slew/travel/RTK samples.
- `/api/overwrite` changes a single DBC signal, and may materialize/send a frame. Its persistent override semantics do not provide atomic telemetry families, clock/identity validation, freshness expiry or the physical-to-protocol conversion contract.
- `socket_bridge.py:bridge_to_vcan` starts its injection consumer only after PC001 connects and handshakes. It cannot be reused as an independent WS output loop unchanged.
- Conclusion: existing protocols cannot satisfy the agreed physical-only Gateway boundary without adaptation on the receiving side. Minimum companion work: physical WS route and handshake, physical-to-CAN encoder, independent bounded/freshness-aware output lifecycle using the existing PCAN bus abstraction, and physical-value/session state for the new console. Preserve existing PC001 and dashboard routes.

Next: refine M1 schema/session freshness and mode migration, then implement against this baseline. Existing M3 console scope remains unless explicitly changed. Replace M2 Linux/vcan hardware acceptance with Windows PCAN; remove M4 patch/snapshot acceptance. Endpoint spelling and session queue details are implementation choices, not additional approval gates. Real PCAN hardware acceptance must be distinguished from mock-backend and byte-parity checks.

## Goal

Make the CAN Gateway, when launched with no arguments, run as a pure
**physical-quantity producer**: it derives each sensor's physical values and
publishes them over a WebSocket to a companion tool on a Linux VM, which owns
CAN frame assembly, CAN transport and physical CAN management. The Gateway no
longer encodes CAN, no longer manages CAN, and no longer serves its own Web API
in this mode.

The existing CAN-producing modes stay available but must be requested
explicitly.

## Background

- Today `gateway.py --mode standalone|godot-managed` owns the entire chain:
  `TelemetrySample -> MachineState / QmlCanMapper -> DBC encode -> sink`
  (CSV / SocketCAN / PC001 TCP). Its React console at `127.0.0.1:29777` is a
  *CAN* console (message table, DBC editing, per-ID authority, transport
  reconfiguration) and displays per-ID freshness and actual egress frequency.
- The companion tool is `E:\projects\temp\tools\can_replay` (Linux VM). It has
  **no physical-quantity input interface today**: every input path normalises
  to an already-encoded `CanReplayFrame`; there is no UDP listener; the PC001
  protocol carries only `can_id / dlc / data[8] / channel`; its FastAPI `/ws`
  endpoint is server-to-client snapshot only and rejects client data.
- Reusable building blocks on the companion side: `dbc.load_machine_messages_by_channel`,
  cantools `Message.encode(values, strict=True)`, `FrameOverwriteResolver`,
  `CanReplayFrame`, the transport-decoupled `injection_queue` in
  `socket_bridge.py`, `CanDashboard.update_frame`, `vcan_client.send_raw_async`,
  and the physical-CAN routing (`ch0->can1`, `ch2->can4`, `ch3->can3`) from the
  prior `09-04-physical-can-socket-bridge-low-latency` delivery.
- A prior unmerged delivery (`can_replay_physical_bridge_delivery_20260904`)
  added `simulator.py` (physical values -> payload). Note its `bridge-physical`
  command's "physical" means physical CAN *interfaces*, not physical
  quantities — only `simulator.py` is a shape reference.

## Communication topology

There are exactly **three** links, and only two of them are WebSocket. The
Gateway never speaks to a browser in the new mode.

| Link | Transport | What it carries |
|---|---|---|
| Godot ↔ Gateway | **UDP**, two ports | `:29764` — telemetry CTN1 + control CTNC (record / ICT / timed-CAN / shutdown commands). `:29765` — heartbeat CTNK, session-done CTND, ICT-result CTNR. No TCP, no WS, unchanged by this work. |
| Gateway → companion | **1 WebSocket**, 2 logical channels | Gateway is the **client**. `data` = physical quantities, lossy, latest-value coalesced per `(family, key)`. `event` = handshake / health / errors, never coalesced, never dropped. |
| Browser ↔ companion | **REST + WS** | Browser is the **client**. REST `/api/*` for actions (overwrite, inject, record, stop); WS `/ws` for server→client snapshots only, throttled (~0.1 s). Unchanged shape from today. |

The browser never talks to the Gateway in the new mode, and it carries over **no
legacy status display**: the old console's freshness and actual-frequency columns
are removed, and the Gateway's own transport state (CAN interface, PC001 peer,
socket errors) is **not** surfaced in the new console either. In this mode the
Gateway does not manage CAN at all, so that state no longer exists; the new
console shows physical quantities plus the companion's own status. The `event`
channel therefore carries only the handshake, health and error traffic needed to
keep the Gateway↔companion session correct — it is not a status feed for the
browser.

## Decisions (confirmed with the operator)

| Topic | Decision |
|---|---|
| Mode selection | `--output {physical, can}`, default `physical` — a dedicated parameter, *not* a new `--mode` value. `--mode` keeps `{standalone, godot-managed}` and is honoured only with `--output can`; passing `--mode` together with `--output physical` is a hard error rather than a silent ignore. |
| Legacy archive | In place with documentation: files and directories do not move; the legacy pipeline is annotated as archived and gets no further feature work. |
| Frontend scope | The full `design.md` §4.1 checklist, excluding the interactive start-up wizard and the Rich text fallback renderer. |
| WS role | Gateway is the WS **client**; the companion is the **server** |
| Payload boundary | **Semantic physical quantities** — roll/pitch/yaw (deg), slew angle, travel pressure (**MPa**), geodetic position, heading, ENU velocity. The companion reproduces all quantisation and conversion. |
| Travel payload | Transmit the value as today, i.e. the already-binarised `0` / `9`. Its physical unit is **MPa** (the current `kg` wording in code and README is wrong and must be corrected). |
| Frontend location | A **new standalone project** at `tools/replay_console/` — *not* the archived `tools/can_gateway/web/`. The two consoles have wholly different semantics (physical quantities vs CAN frames), so they share neither directory nor build. `tools/can_gateway/web/` stays in place as part of the archive. |
| Web frontend | Keep the **existing Web console's skeleton and design**, but implement **every feature the companion's terminal TUI provides**. Hosted by the companion, re-pointed at the companion's API/WS. **No legacy status display is carried over**: no freshness column, no actual-frequency column, and no Gateway transport state. The Gateway serves no Web endpoint in the new mode. |
| Recording | The new mode records nothing (no CSV, no local file). The game panel `[CAN 输出]` control is removed. |
| Legacy modes | **Archived, not deleted** — kept in the tree, reachable only by explicit parameters, no longer developed. |
| Direction | The new mode becomes the primary mode for both the Gateway and the game. |
| Delivery | Both sides are planned; the companion side ships as a `git apply`-able patch, in the style of the `09-04` delivery. |

## Requirements

### Gateway

- R1. Add `--output {physical, can}` with default `physical`, selecting the new
  pipeline through a parameter of its own rather than through a new value of
  `--mode`. The new mode is therefore what runs when nothing is passed.
  `standalone` and `godot-managed` stay reachable only via
  `--output can --mode ...`, and `--mode` combined with `--output physical` is a
  hard error, not a silent ignore.
- R2. In the new mode the Gateway must not load or use DBC codecs, encoders,
  frame sinks, PC001, can0 setup, the CAN console, or the Web REST API.
- R3. Topology: **one** WebSocket connection to the companion, carrying **two
  logical channels**:
  - a `data` channel for physical quantities — lossy by design, latest-value
    coalesced per `(family, key)`, and
  - an `event` / `status` channel for handshake, health and errors — never
    coalesced, never dropped. It is **not** a browser-facing status feed: the
    new console does not carry over the legacy console's status display.

  Bounded reconnect/backoff; a slow or absent peer must never stall the UDP
  receive loop nor produce stale replay.
- R4. Publish a `hello` handshake carrying protocol version, model id, profile
  id and calibration SHA-256 so the companion can reject an inconsistent pair.
- R5. Keep the existing telemetry intake, `FrameScheduler` cadence,
  `MachineState`, the calibration layer and QML projection unchanged, since the
  semantic values depend on them.
- R6. The physical-quantity payload must carry the Gateway's wall clock where a
  CAN frame would today (GPS week/time), so the companion does not substitute
  its own clock.
- R7. Legacy modes must keep byte-identical behaviour, including PC001, CSV and
  SocketCAN paths.

### Companion (Linux VM)

- R8. Add a physical-quantity input endpoint (WebSocket, same uvicorn process)
  alongside the existing snapshot `/ws`.
- R9. Add an encoder that converts semantic physical quantities into
  `CanReplayFrame`s, reproducing the Gateway's semantics exactly: IMU axis
  remap `slots = (-pitch, roll, yaw)`, quantisation `round((slot + 180) / 0.01)`,
  clamp `[1, 65535]`, slew angle handling, travel binarisation, RTK origin /
  constants / secondary antenna / bound clamping, and the GPS wall clock.
- R10. Deliver encoded frames through the existing decoupled injection path so
  the dashboard, recorder and `/ws` snapshot update without schema changes.
- R11. Serve the frontend bundle built from the new `tools/replay_console/`
  project. It must keep the existing console's
  skeleton and design, must drop the freshness and actual-frequency columns,
  must carry over **no** legacy status display (including the Gateway's
  transport state), and
  must provide **every capability the companion's terminal TUI provides**. Known
  gaps in the current web dashboard that therefore become new work: the full DBC
  / protocol-CSV detail (22-column table plus per-signal scale, offset, range,
  unit, choices, multiplexer, comment, cycle time, senders), the progress bar,
  overwrite period presets with current-period recall, parent-row overwrite
  highlighting, and search-hit highlighting.
- R12. Ship as `original-project/` + `modified-project/` + `changes.patch` +
  `DELIVERY.md`, verified with `git apply --check` and byte-for-byte snapshot
  comparison.

### Contract

- R13. Freeze the WS contract as a versioned schema under `protocol/`
  (following the existing `*-vN.schema.json` convention) and register it in
  `protocol/version-manifest.json`.

### Migration

- R14. Update the game so it launches the new mode, and remove the panel
  `[CAN 输出]` control and its `RECORD_START` / `RECORD_STOP` plumbing.
- R15. Update scripts and tests that assume the default mode is
  `standalone`/`tcp` (`smoke_frozen_gateway.py`, `tests/test_gateway_process.py`,
  `godot/client/tests/run_standalone_matrix.ps1`).
- R16. **Archive** the legacy CAN pipeline rather than deleting it: keep
  `standalone` / `godot-managed`, `gateway_web.py`, the CAN console and the DBC
  runtime in the tree, reachable only by explicit parameters, documented as
  archived, and no longer developed. The legacy console frontend
  `tools/can_gateway/web/` is archived with it and is **not** the source of the
  new console — the new console is a separate project (R11).
- R17. Correct the travel pressure unit from `kg` to `MPa` in
  `encoders/travel_pilot.py` and `README.md`. Documentation and comments only —
  no numeric or wire change.

## Acceptance Criteria

- [ ] Launching the Gateway with no arguments starts the physical-quantity mode
      and emits nothing but sensor physical values over WS.
- [ ] `--mode standalone` and `--mode godot-managed` still reproduce today's
      behaviour, byte-for-byte, including PC001 / CSV / SocketCAN.
- [ ] Driving the new pipeline end-to-end with a frozen telemetry battery
      produces CAN frames on the companion that are **byte-identical** to the
      frames the legacy Gateway produced for the same battery (same
      `can_id`, `payload`, `channel` for all families).
- [ ] The UDP receive loop does not stall when the WS peer is slow or absent;
      the Gateway reconnects and does not replay stale values.
- [ ] The companion rejects a `hello` whose `model` / `profile` /
      `calibration_sha256` is inconsistent.
- [ ] The hosted frontend shows physical quantities with no freshness or
      actual-frequency columns, carries over no legacy status display, and talks
      only to the companion.
- [ ] The frontend is its own project at `tools/replay_console/` with its own
      build, and the legacy `tools/can_gateway/web/` is left untouched.
- [ ] The three links stay as specified: Godot↔Gateway on UDP 29764/29765,
      Gateway→companion on a single WS with `data` + `event` channels, and
      browser↔companion over REST + WS. No browser traffic reaches the Gateway.
- [ ] The companion patch applies cleanly with plain `git apply --check` and
      reproduces the modified snapshot byte-for-byte.
- [ ] Existing Gateway test suite shows no regressions against the recorded
      baseline.
- [ ] `--output physical` is the default; `--output can --mode standalone` and
      `--output can --mode godot-managed` reach the legacy pipeline; `--mode`
      combined with `--output physical` is rejected with a clear error.
- [ ] The archived legacy pipeline is still reachable by explicit parameters and
      behaves exactly as before.
- [ ] The hosted frontend offers the companion TUI's capability set, including
      the full DBC / protocol-CSV detail table.
- [ ] Travel pressure is documented as MPa, with no change to the transmitted
      value or wire bytes.

## Open Items

- Whether the Gateway keeps serving the legacy console bundle
  (`tools/can_gateway/web/`) in legacy modes. Non-blocking; the working
  assumption is that it keeps serving it, since the legacy pipeline is archived
  rather than removed.
- The exact spelling of the companion-endpoint parameter. Non-blocking;
  candidates are `--ws-endpoint ws://HOST:PORT`, or a `--ws-host` / `--ws-port`
  pair mirroring the existing `--tcp-host` / `--tcp-port`. Either way it
  defaults through the existing `GatewayConfigStore` persistence.

All other decisions are settled.

## Out of Scope

- Changing `conventions.py` semantics, the calibration layer, or the QML
  projection maths.
- Changing PC001 wire framing, the DBC files, or CAN bitrate/restart-ms.
- Lossless delivery under overload.
- Third-party consumers of the physical-quantity stream.

## Progress

- **State: DEFERRED (paused) as of 2026-09-14, at the operator's request.**
  Unarchived, not abandoned, nothing superseded. The active-task pointer was
  cleared (`task.py finish`); the task directory stays where it is.
- Current milestone: plan locked; still no code written.
- Completed: investigation of both codebases; companion-side capability audit
  (confirmed no physical-quantity input exists today); full companion TUI
  feature inventory including the delta against its existing web dashboard;
  operator corrections folded in; every decision settled — `--output
  {physical, can}`, one WS connection carrying two logical channels, in-place
  archive, the full §4.1 frontend scope, the three-link topology, and the new
  frontend project directory `tools/replay_console/`.
- Last requirement change before pausing: dropped the idea of forwarding the
  Gateway's transport state to the browser. The new console carries over no
  legacy status display at all — no freshness, no actual frequency, no Gateway
  transport state. The `event` channel is therefore only session-integrity
  traffic (handshake / health / errors), not a status feed.
- Confirmed: no code has been changed — only `.trellis/` and `.workbuddy/` are
  touched; HEAD is still `c8a6c42`.
- Pending: implementation of M1–M4 (nothing started).
- Decisions and evidence: see `design.md`.
- Blockers: none technical. Paused by operator decision, not by an unresolved
  issue.
- Next (on resume): start M1 — freeze the WS schema under `protocol/`, then
  build the Gateway's physical layer.
- Resume prerequisites: none beyond the two non-blocking open items above; they
  do not gate M1 and can be settled during it.
