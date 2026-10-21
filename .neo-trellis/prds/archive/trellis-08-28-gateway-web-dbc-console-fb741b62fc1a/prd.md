# Gateway Web console and DBC frame sender

## Goal

Add a browser-accessible management console to the Python CAN Gateway on both
Windows and Linux. The console must expose runtime status and transmission logs
when Godot owns the Gateway, and additionally allow transport configuration,
DBC discovery/inspection, signal editing, frame enablement, and manual/batch
DBC-compliant transmission when the Gateway is launched independently.

## Background and Confirmed Facts

- The current Gateway has no HTTP server or structured status/log API. One
  synchronous UDP loop owns telemetry encoding, recording, timed bursts,
  transport lifecycle, and ICT control (`tools/can_gateway/gateway.py:133-314`).
- Godot currently chooses the transport through launch arguments: Windows uses
  PC001 TCP and Linux uses SocketCAN `can0`
  (`godot/client/scripts/can_telemetry_bridge.gd:292-311`). There is no explicit
  Godot-managed/standalone Gateway mode today.
- The Web feature cannot safely call sinks from request-handler threads.
  Existing and new producers must submit work to one Gateway-core owner so
  transport restart, DBC sends, simulation telemetry, and timed bursts cannot
  race.
- The current PC001 sink has caller-thread and service-thread send paths plus an
  unbounded pending list (`tools/can_gateway/pc001_sink.py:66-75,122-175`). These
  must be bounded/serialized before adding a Web-driven producer.
- The two reference files are `can3.sy135c.dbc` (12 messages / 52 signals) and
  `can4.sy135c.dbc` (15 messages / 34 signals). All 27 messages are DLC 8
  extended CAN frames; the files contain Intel signals, signed and unsigned
  values, scaling/offset/limits, but no multiplexing, enumerations, or cycle-time
  attributes.
- The reference DBC contains no license/provenance declaration. Its content is
  small and technically straightforward to package, but redistribution rights
  must be treated as supplied/approved by the project owner or documented in
  repository provenance.
- DBC encoding is a new manual-transmission authority for value entry and
  scheduling. The approved bundled DBCs are also the byte-layout authority for
  all currently emitted simulation messages they cover: CGI610 RTK
  `0x0CFDA000..0x0CFDA900` and the four Ruifen IMU angle frames
  `0x18FF3A00..0x18FF3D00`.
- Existing manual RTK encoders already match the DBC for A000-A700 and A900.
  CGI610 A800 has a historical DBC-vs-runtime-parser disagreement documented in
  `tools/can_gateway/README.md:92-100`; the DBC little-endian layout wins.
- For the Web/DBC sender, the supplied DBC is authoritative for the CGI610
  `0x0CFDA800` velocity frame: `VelE`, `VelN`, `VelU`, and `Vel` are Intel
  little-endian signed i16 signals at start bits 0, 16, 32, and 48 with scale
  `0.01`. The reference runtime parser's big-endian interpretation must not be
  copied into this DBC-driven path.
- Godot-derived RTK and IMU values and Web-edited values retain separate
  value-source, permission, scheduling, and command paths but use the same
  cached DBC encoding implementation. A Godot semantic adapter remains
  responsible for coordinates, antenna offsets, velocity derivation, IMU
  mounting/sign remap, reserved fields, and the IMU all-zero invalid marker.
- The repository has no current React/Vite/Tailwind/shadcn project and no
  `cantools` dependency. Existing PyInstaller builds already bundle
  `tools/can_gateway/resources`, and `qml_profile.resource_root()` resolves the
  same resource tree in source and onefile modes.
- The existing `encode_velocity_frame()` and normal RTK family default are
  already little-endian. Only the QML/Godot projection branch overrides A800 to
  big-endian at `tools/can_gateway/gateway.py:402-409`, so the product-wide A800
  migration is a localized removal of that exception plus fixture/spec updates.
- The approved bundled protocol DBC is hash-bound and remains available to
  Godot-managed telemetry independently of the mutable Web catalog. Reloading,
  replacing, or failing to parse an adjacent/`--dbc-dir` file must not change or
  interrupt Godot telemetry encoding.

## Requirements

- Start one local Web service with every Gateway process and make its URL
  discoverable to the operator.
- Bind the Web service only to `127.0.0.1`. Remote/LAN access and authentication
  are outside this feature.
- Use TCP port `29777` by default and allow an explicit `--web-port` override.
  If the loopback port cannot bind, fail Gateway startup with an actionable
  error; never choose a random fallback port. Print the exact console URL after
  a successful bind.
- Do not open a browser by default. Standalone mode may opt in with
  `--open-browser`, which opens the exact loopback URL only after a successful
  bind. Godot-managed mode must not open a browser automatically.
- Implement the UI with React, Tailwind CSS, and shadcn/ui, packaged so the
  Python Gateway can serve it without a separately installed Node runtime.
- Distinguish Godot-managed and standalone launch modes through an explicit,
  testable CLI/runtime contract rather than process-name heuristics. Godot must
  pass the managed mode explicitly.
- Godot-managed mode is read-only: show Gateway/platform/transport/CAN/ICT
  state and live transmission logs; do not expose transport mutation or manual
  frame-send controls.
- Standalone Windows defaults to the existing PC001 TCP server transport;
  standalone Linux defaults to preparing/binding physical `can0` using the
  existing fixed readiness/helper contract.
- Transport type is platform-fixed in both runtime modes: Windows always uses
  the PC001 TCP server and Linux always uses physical SocketCAN `can0`. The Web
  console must not offer Windows SocketCAN, Linux TCP, arbitrary CAN interface,
  or transport-type switching.
- Standalone mode permits supported transport configuration: TCP listener
  settings on Windows and an explicit can0 restart/reconfigure action on Linux.
- Applying a Windows standalone TCP listener change immediately disarms Web
  transmission, disconnects the current PC001 client, closes the old listener,
  and binds the requested address/port. Persist the new endpoint only after a
  successful bind and do not auto-resume sending.
- If the new TCP endpoint cannot bind, remain in an explicit not-listening/error
  state. Do not silently restore the old listener; the operator must correct or
  explicitly reapply an endpoint.
- Linux distinguishes normal prepare from explicit restart: normal startup
  retains the existing ready/no-cycle optimization, while a confirmed
  standalone Web restart always disarms periodic sending, closes/detaches the
  active SocketCAN sink, and performs `down → bitrate 250000/restart-ms 100 →
  txqueuelen 1000 → up → post-verification` even when can0 was already ready.
  The UI must warn that this temporarily interrupts the CAN bus.
- Godot-managed mode uses the same platform-fixed transport but exposes no Web
  transport controls; transport lifecycle remains owned by Godot/ICT commands.
- Discover `.dbc` files from a deterministic packaged/default location plus an
  explicitly configured search location. Include copies of the two reference
  DBC files currently under
  `E:/projects/dev_arch2.0_36b5586c/GuideSystem/assets/dbc` in the Linux and
  Windows Gateway distributions, subject to provenance/licensing verification.
- Discovery sources are: bundled `resources/dbc`, an executable-adjacent
  `dbc/` drop-in directory, and zero or more explicit `--dbc-dir` directories.
  Scan only direct `.dbc` children, normalize and sort paths deterministically,
  retain colliding filenames as distinct source entries, and identify parsed
  content by source plus SHA-256 rather than filename alone.
- An invalid or unreadable DBC produces an isolated visible file error and must
  not hide other valid DBC files. DBC discovery/reload never auto-starts sending.
- Scan DBC sources automatically at Gateway startup and expose an explicit Web
  rescan/reload action. Do not watch files continuously in the background.
- A manual reload first disarms periodic Web sending, then reparses all sources
  and revalidates persisted drafts. It never automatically resumes sending,
  which avoids loading a file while another process is still writing it.
- Show definitions from all sources, but allow at most one enabled message
  definition for a given normalized CAN ID. Enabling a conflict is rejected with
  both source identities; the operator must explicitly disable the current
  definition first. Never auto-replace it.
- If a DBC change or persisted-state restore introduces an ID conflict, keep the
  conflicting definitions disabled and surface a visible conflict notice.
- Parse DBC message/signal metadata and present messages and their signals in
  a usable table. Users can edit physical signal values with validation, enable
  or disable individual messages, and request transmission of the enabled
  messages.
- For a newly discovered signal without a compatible persisted value, choose
  physical `0` when it lies within the DBC-valid range; otherwise choose the
  valid bound nearest zero. Mark these values as generated defaults in the UI.
- A message can be enabled only when every required signal has a finite,
  in-range value that the DBC codec can encode. Restored values are revalidated
  against the current DBC before enablement.
- Support continuous periodic transmission of enabled messages. The default
  configured rate is 50 Hz per message and the operator can independently
  change each message's rate in the Web UI. The UI must expose explicit
  start/stop state; enabling a message alone must not silently begin physical
  transmission.
- Each per-message rate is an integer from 1 through 100 Hz inclusive. Reject
  fractional, zero, negative, out-of-range, NaN/infinite, and non-numeric
  values in both the API and UI. Scheduling is best-effort monotonic timing, not
  a hard-real-time guarantee.
- Changing one message's frequency resets only that message's next due time and
  must not disturb, bunch, or restart other enabled-message schedules.
- Estimate aggregate classical-CAN bus load from enabled message identifiers,
  DLCs, and configured frequencies. Display the estimate continuously and show
  a prominent warning at high load, but do not block start, reject a valid
  frequency, auto-disable messages, or auto-throttle based on the estimate.
- Render estimated load below 70% as normal, 70–89% as a yellow high-load
  warning, and 90% or greater as a red severe warning. Estimates above 100%
  remain startable but must state that the configured schedule cannot be
  reliably carried by a 250 kbit/s bus.
- Periodic scheduling must use Gateway monotonic time, skip missed slots rather
  than emit catch-up bursts, and remain independent from Godot physics cadence
  and the existing fixed timed-CAN burst.
- On Windows, a valid PC001 handshake is required before periodic Web sending
  can start. If the active PC001 client disconnects, immediately disarm Web
  sending and discard transient pending frames; do not queue stale frames for a
  future client. Reconnection requires a new operator start action.
- On Linux, verified/bound can0 readiness is required before periodic Web
  sending can start. A terminal SocketCAN/can0 failure disarms sending and
  requires transport recovery plus a new operator start action.
- Encode frames according to DBC start bit, length, byte order, signedness,
  scale, offset, limits, multiplexing, DLC, and CAN-ID rules. DBC/manual sending
  must not alter simulation signal derivation or cadence. For Godot telemetry,
  migrate the complete DBC-covered RTK family and four IMU angle frames to the
  shared cached codec; only A800 is expected to change bytes, to the explicitly
  approved little-endian layout.
- Preserve the IMU semantic adapter from reported `(roll, pitch, yaw)` to DBC
  sensor slots `(Pitch_Angle=-pitch, Roll_Angle=roll, Yaw_Angle=yaw)`, preserve
  reserved-field bytes, and continue preventing the receiver's all-zero invalid
  marker. DBC signal names must not bypass this mounting/protocol contract.
- Keep the slew `0x18FFF000`, travel `0x256`, and fixed timed
  `0x18FFF100` frames on their existing dedicated encoders because the approved
  DBCs do not define them. Do not begin emitting DBC-defined IMU accel/gyro or
  other messages for which Godot supplies no physical values.
- Keep one core owner for all transport mutation and CAN transmission. Web
  handlers consume immutable status and bounded log snapshots and enqueue
  commands; they do not write sockets or reconfigure can0 directly.
- Make transmission logs bounded and sequence-addressable so a slow or absent
  browser cannot backpressure the CAN loop or grow memory without limit.
- Persist transmission and operational logs across Gateway restarts in the
  platform-standard per-user log directory. Logs must rotate under a bounded
  total-size policy, survive abnormal process termination as far as the chosen
  append format permits, and be downloadable from the loopback Web console.
- The default retention is five rotating files of approximately 20 MB each
  (approximately 100 MB total). The Web console can download the current log or
  an archive containing all retained rotations.
- Persistent logging must not perform synchronous disk I/O in the CAN scheduler
  or allow a slow disk/export request to backpressure frame transmission.
- Aggregate high-rate transmission history per message in one-second windows,
  recording attempted/succeeded/failed counts, last CAN ID/DLC/payload, and the
  latest error. Record start/stop, configuration changes, transport transitions,
  DBC changes, and errors as complete individual events.
- The live Web log view uses the same bounded aggregate/event stream rather than
  rendering one browser event for every transmitted CAN frame.
- Gateway restart, transport reconfiguration, can0 restart, DBC reload/parse
  failure, or terminal send failure must disarm periodic Web transmission.
  Periodic sending must never auto-resume after process restart or transport
  recovery without a new operator action.
- Persist validated signal draft values, message enabled states, and per-message
  frequencies in the platform-standard per-user configuration directory. Do
  not write mutable state into the packaged resource or executable directory.
- The active/armed transmission state is never persisted. On every Gateway
  start, restored drafts remain stopped until the operator explicitly starts
  periodic transmission.
- Persisted entries must be keyed by stable DBC identity plus message/signal
  identity so a changed/replaced DBC cannot silently apply stale values to an
  incompatible layout; incompatible entries are ignored with a visible notice.
- Route DBC-generated raw CAN frames through the selected standalone transport
  using the existing SocketCAN/PC001 packing boundary.
- Preserve existing Godot ICT behavior, CSV recording, timed-frame behavior,
  Windows PC001 compatibility, Linux can0 safety, all simulation signal
  derivation/cadence, and all non-DBC-covered encoder semantics.
- If the same DBC bytes are visible through both bundled resources and an
  executable-adjacent copy, collapse that exact SHA-256 duplicate into one
  catalog entry while retaining all source locations. Files that merely share
  a filename remain distinct.

## Acceptance Criteria

- [ ] A packaged Gateway starts a reachable Web console on Windows and Linux
  without requiring Node.js on the target machine.
- [ ] The Web console listens on loopback only and is unreachable through the
  machine's LAN interfaces.
- [ ] The default URL is `http://127.0.0.1:29777`; `--web-port` changes it
  deterministically, and a bind conflict fails startup instead of silently
  moving the console.
- [ ] Default and Godot-managed startup never opens a browser; standalone
  `--open-browser` opens one tab only after the Web server is ready.
- [ ] Godot-managed mode exposes status/logs only, and mutation/send APIs are
  rejected server-side as well as hidden in the UI.
- [ ] Standalone Windows starts the PC001 TCP listener by default; standalone
  Linux checks/prepares/binds `can0` by default.
- [ ] Windows never exposes can0/SocketCAN controls and Linux never exposes TCP
  listener controls in either runtime mode.
- [ ] The packaged reference DBC files and configured external DBC directory are
  discovered deterministically with parse errors shown per file.
- [ ] Operators can add a DBC by placing it in the executable-adjacent `dbc/`
  directory or passing `--dbc-dir`, without rebuilding the Gateway; duplicate
  filenames remain distinguishable and invalid files do not block valid files.
- [ ] Startup scans automatically; manual reload disarms first, revalidates all
  restored state, and never auto-resumes. Merely modifying a file on disk does
  not mutate a live schedule until the operator reloads it.
- [ ] Two DBC definitions with the same normalized CAN ID cannot be enabled
  together; conflicts identify both sources and are never silently replaced.
- [ ] The UI accurately displays DBC messages/signals and validates edits before
  sending.
- [ ] New signal drafts use zero or the nearest-to-zero valid bound, are visibly
  identified as generated defaults, and messages with any invalid/unencodable
  required value cannot be enabled.
- [ ] Enabled messages encode byte-for-byte according to representative Intel,
  Motorola, signed, scaled, extended-ID, and multiplexed DBC fixtures.
- [ ] CGI610 `0x0CFDA800` encodes all four signed velocity fields little-endian
  according to `can4.sy135c.dbc`, including positive, negative, zero, minimum,
  maximum, scale-rounding, and out-of-range rejection cases.
- [ ] Existing Godot-derived A800 telemetry uses the same little-endian layout;
  equal signal values from Godot and Web input encode to identical payloads.
- [ ] Godot-derived A000-A700 and A900 frames pass differential golden tests
  against their previous manual encoders and therefore remain byte-identical
  across representative, rounding, boundary, and invalid-value cases.
- [ ] The four Godot IMU angle frames encode through the shared DBC codec while
  preserving their mounting/sign mapping, reserved bytes, all-zero invalid
  marker protection, existing cadence, and previous golden payloads.
- [ ] Reloading or breaking an external/adjacent DBC disarms only Web periodic
  sending and cannot replace, disable, or alter the hash-bound protocol DBC used
  by Godot telemetry.
- [ ] Disabled messages are never sent, and the operator receives per-request
  success/failure plus observable transmission logs.
- [ ] Logs remain available after Gateway restart, rotate within a documented
  storage bound, can be downloaded locally, and do not block the CAN scheduler.
- [ ] Default retention never intentionally exceeds five approximately 20 MB
  log files, and both current-file and complete-history downloads are available.
- [ ] At 27 messages × 50 Hz, live and persistent logging remains bounded and
  reports accurate per-message counts without emitting 1350 browser/disk log
  records per second.
- [ ] Starting Web transmission sends each enabled message continuously at its
  independently configured rate, each defaulting to 50 Hz; stopping it prevents
  all subsequent Web DBC emissions without affecting Godot telemetry or
  unrelated Gateway duties.
- [ ] Editing one message's frequency affects only that message and produces no
  catch-up burst or schedule reset for other messages.
- [ ] Frequency validation accepts only integer `1..100 Hz`, defaults every new
  message to `50 Hz`, and reports invalid inputs without mutating saved/runtime
  schedule state.
- [ ] The Web console updates estimated bus load when enablement/frequency
  changes and clearly warns at high load, while still allowing the operator to
  start the requested schedule.
- [ ] Load presentation switches at 70% and 90% and continues to display values
  over 100% without turning the estimate into an API/UI interlock.
- [ ] A delayed Gateway loop emits at most the currently due occurrence per
  message and skips missed intervals instead of releasing a catch-up burst.
- [ ] Restart/reconfigure/error paths disarm periodic Web sending and require an
  explicit operator restart before any further DBC frames are emitted.
- [ ] Valid signal drafts, enabled states, and per-message frequencies survive
  Gateway restart, while transmission always restarts in the stopped state.
- [ ] A changed DBC hash/schema cannot inherit incompatible persisted values;
  the Web console reports which saved entries were ignored.
- [ ] Standalone transport changes and Linux can0 restart/reconfigure actions
  have explicit lifecycle/error states and cannot race active transmission.
- [ ] A Windows TCP endpoint change disconnects/disarms before rebind, persists
  only after success, never auto-resumes, and exposes bind failure without a
  hidden rollback to the previous listener.
- [ ] Normal Linux startup does not cycle an already-ready can0, while a
  confirmed standalone restart always performs the fixed down/configure/up
  sequence, visibly reports progress/result, and leaves Web sending disarmed.
- [ ] Windows refuses to start periodic sending before PC001 handshake; a client
  disconnect disarms sending without retaining stale queued frames, and a later
  handshake does not auto-resume.
- [ ] Linux refuses to start periodic sending before can0 is verified and bound;
  terminal CAN failure disarms sending and recovery does not auto-resume.
- [ ] Existing Gateway/Godot/PC001/SocketCAN/CSV/CAN-construction regression
  suites remain unchanged in semantics and pass.

## Out of Scope (initial)

- Editing or saving the DBC schema itself.
- CAN receive/decode monitoring unless later explicitly added.
- Replacing simulation encoders for frames not covered by the approved DBCs;
  slew, travel, and fixed timed frames remain dedicated encoders.
- Generating new Godot IMU acceleration/gyro, RTK A00, or other DBC-defined
  frames for which the current telemetry path has no physical-value source.
- Installing USB-CAN drivers or creating physical `can0`.
- Remote or multi-user administration.

## Risks and Deferred Evidence

- Loopback binding removes remote administration from scope, but mutation APIs
  must still enforce Godot-managed read-only mode server-side and use strict
  same-origin/JSON request handling.
- The supplied DBC files contain no cycle-time attributes, so all periodic
  cadence comes from the Web configuration, initialized to the product default
  of 50 Hz.
- Real PC001 and physical can0 validation remain target-environment gates after
  deterministic codec/API tests.
- Load percentage is an estimate, not a safety interlock; actual bit stuffing,
  arbitration, other bus traffic, adapter queues, and downstream PC001 behavior
  can differ from the displayed value.
