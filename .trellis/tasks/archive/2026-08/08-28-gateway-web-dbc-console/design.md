# Design — Gateway Web console and DBC frame sender

## 1. Architecture and authority

One `GatewayCore` remains the only owner of transport mutation and CAN emission.
The `aiohttp` Web runtime has its own event-loop thread, serves immutable status
snapshots, and submits typed commands to the core. It never calls a sink,
reconfigures `can0`, or mutates scheduler state directly.

```text
Godot UDP telemetry/control ─┐
                             ├─> GatewayCore command/state loop
Web API command queue ───────┤      ├─ simulation/timed producers
DBC monotonic scheduler ─────┘      ├─ DBC periodic producer
                                    └─ platform transport
                                       Windows: PC001 TCP only
                                       Linux: SocketCAN can0 only

GatewayCore ─> immutable revisioned snapshot ─> aiohttp ─> React console
GatewayCore ─> bounded aggregate/event stream ─> async rotating log writer
```

The core loop uses a wakeup channel for Web commands and computes its wait from
the next periodic deadline. Scheduler delays skip missed periods and emit at
most one current occurrence per message; no catch-up burst is permitted.

Godot-derived values and Web-entered values remain separate producers with
separate permission, cadence, and command paths. A Godot semantic adapter first
produces DBC physical-signal dictionaries; both producers then share the cached
DBC message codec as the sole byte-layout authority for the complete RTK
A000-A900 family and four IMU angle frames. Slew, travel, timed frames, and
DBC-defined messages without a current Godot value source are not migrated.

## 2. Runtime modes and lifecycle

Add explicit `standalone` and `godot-managed` modes. Godot passes the managed
mode in its launch arguments. Both modes start the Web service on
`127.0.0.1:29777` by default; `--web-port` overrides the port. Bind failure is a
fatal startup error. Only standalone `--open-browser` opens a browser after the
server is ready.

Managed mode exposes status, logs, and downloads only. The UI hides mutations,
but the API is authoritative and rejects them with `403` even if called
directly. Standalone mode exposes only the platform's transport control:

- Windows: PC001 TCP endpoint configuration and listener state.
- Linux: fixed `can0` status plus confirmed restart/reconfigure action.

The transport state machine is `STOPPED → OPENING → READY`, with explicit
`RECONFIGURING` and `ERROR` states. Transport reconfiguration, DBC reload,
terminal send failure, or process restart disarms DBC periodic transmission.
Recovery never auto-resumes it.

PC001 is changed to a single-writer design: only its service thread writes to
the client socket. Frames are dropped with counters when no valid handshake is
active; no unbounded or stale clientless queue is retained. Disconnect disarms
DBC transmission immediately.

Linux normal startup reuses the existing ready/no-cycle preparation contract.
The explicit standalone restart closes the sink and always performs the fixed
down/configure/queue/up/post-verify transaction through the installed helper.

## 3. Web API contract

All endpoints are same-origin JSON under `/api/v1`; static content and API share
the loopback origin. Mutations carry a request ID and expected configuration
revision so stale browser state is rejected rather than silently overwriting a
newer change.

| Endpoint | Purpose | Mode |
| --- | --- | --- |
| `GET /api/v1/status` | Revisioned runtime, transport, scheduler, load, and log status | Both |
| `GET /api/v1/catalog` | DBC files, messages, signals, drafts, conflicts, parse notices | Both |
| `GET /api/v1/events` | WebSocket stream of bounded aggregate/events after a sequence | Both |
| `GET /api/v1/logs/current` | Download current persistent log | Both |
| `GET /api/v1/logs/archive` | Stream an archive of retained rotations | Both |
| `PUT /api/v1/messages/{key}` | Atomically update draft, enablement, and integer frequency | Standalone |
| `POST /api/v1/sending/start` | Validate transport/catalog and arm enabled messages | Standalone |
| `POST /api/v1/sending/stop` | Disarm DBC periodic transmission | Standalone |
| `POST /api/v1/dbc/reload` | Disarm, rescan, parse, and revalidate persisted state | Standalone |
| `PUT /api/v1/transport/tcp` | Disarm/disconnect/rebind Windows listener | Standalone Windows |
| `POST /api/v1/transport/can0/restart` | Confirmed fixed restart transaction | Standalone Linux |

Status includes mode/platform, exact Web URL, transport state and error,
PC001 handshake or can0 readiness, scheduler armed state, estimated bus load,
catalog/config revision, event sequence, and dropped-event counters. Error
responses use stable machine codes plus bounded operator-facing detail.

## 4. DBC catalog, encoding, and persistence

Use `cantools` as the parsing and strict encoding engine. The catalog scans
direct `.dbc` children of bundled `resources/dbc`, executable-adjacent `dbc/`,
and repeatable `--dbc-dir` locations. Paths are normalized and sorted. Exact
SHA-256 duplicates are represented once with all observed locations; same-name
files with different content remain distinct. Parse failure is isolated to its
file entry.

Separate the hash-bound bundled protocol catalog from the mutable operator
catalog. Godot telemetry resolves only the approved bundled can3/can4 schema;
Web discovery may deduplicate and expose that schema alongside adjacent and
explicit files, but an operator reload cannot swap Godot's encoding authority.

Each parsed message has a stable key derived from DBC content/schema identity,
normalized CAN ID, and message identity. Signal edits operate on physical
values, are checked for finite/range/encodability constraints, and are encoded
strictly before enablement. New signals default to zero or the valid bound
nearest zero and are marked generated. Only one definition for a normalized CAN
ID can be enabled.

Validated drafts, enabled state, and frequency are stored atomically in the
platform-standard per-user config directory via `platformdirs`. Persistence is
schema-versioned and keyed by DBC/message/signal layout identity. Incompatible
entries are ignored with notices. Armed state is never persisted.

The scheduler stores independent next-due times, defaulting each message to
50 Hz with integer `1..100 Hz` validation. Editing one rate resets only that
message. Bus load is an informational worst-case classical-CAN estimate at
250 kbit/s with threshold presentation at 70% and 90%; it never blocks start.

## 5. Logging

High-rate sends feed one-second per-message aggregates containing attempted,
succeeded, failed, last ID/DLC/payload, and latest error. Lifecycle,
configuration, DBC, transport, and error events remain individual records.
Every record receives a monotonic sequence and producer tag.

An in-memory ring backs the WebSocket stream and cannot backpressure the core.
An asynchronous writer appends JSONL in the platform-standard per-user log
directory and rotates five files at about 20 MB each. Download handlers stream
the current file or a point-in-time archive without doing disk work in the CAN
loop.

## 6. React application and distribution

The frontend lives under `tools/can_gateway/web/` as React + TypeScript + Vite,
Tailwind CSS, and source-owned shadcn/ui components. Vite emits relative static
assets into the Gateway resource tree; the target machine needs no Node.js.

The console contains status/transport cards, DBC source and message tables, a
signal editor, per-message enable/rate controls, payload validation preview,
bus-load warnings, explicit start/stop controls, and aggregated live logs.
Managed mode renders the status/log subset only.

Both packaging flows build/include the static Web bundle and bundled DBC
resources. They also place byte-identical copies of the two approved DBC files
under the executable-adjacent `dist/.../dbc/` directory. Repository provenance
records their original paths, hashes, and project-owner approval. Packaged and
adjacent identical copies collapse to one catalog entry at runtime.

## 7. Godot semantic adapters and compatibility

The existing QML/profile mapping remains responsible for deriving coordinates,
main/vice antenna positions, velocity, heading, joint/IMU pose, and calibration.
It emits physical signal dictionaries into the shared codec rather than raw
bytes. RTK A000-A700 and A900 must remain byte-identical to the manual encoders;
A800 intentionally changes only from the historical big-endian exception to
the DBC's little-endian layout.

The IMU adapter preserves the receiver-facing mounting contract:
`Pitch_Angle=-reported_pitch`, `Roll_Angle=reported_roll`, and
`Yaw_Angle=reported_yaw`, with reserved fields chosen to reproduce existing
bytes. It also prevents the raw all-zero triple that the reference parser treats
as invalid. Generic Web editing continues to use the DBC's declared physical
signals and does not inherit this Godot mounting transformation.

## 8. Compatibility and verification boundaries

- Existing UDP control/telemetry, CSV recording, fixed timed bursts, ICT result
  semantics, EFF packing, PC001 framing, slew/travel/timed encoders, and Godot
  signal derivation/cadence remain unchanged.
- A800 fixtures cover positive, negative, zero, bounds, scale rounding, and
  rejection, and prove equal values from both producers yield equal bytes.
- Differential fixtures prove RTK A000-A700/A900 and all four IMU angle frames
  remain byte-identical to their current manual encoders, including mounting,
  reserved, rounding, boundary, and invalid-marker behavior.
- External DBC reload/failure tests prove the bundled protocol catalog remains
  stable and Godot telemetry continues without adopting operator files.
- API tests cover mode/platform authorization, optimistic revisions, lifecycle
  failures, reload/disarm, and bounded event behavior.
- Scheduler tests use a fake monotonic clock and fake sink; no hardware is
  needed for deterministic cadence, failure, load, and no-catch-up assertions.
- React tests cover managed/standalone visibility and validation; a packaged
  browser smoke test covers static routing and live API integration.
- Physical PC001 and USB-CAN/can0 tests remain release gates on target systems.

## 9. Task decomposition

1. `08-28-gateway-web-runtime-core`: establish ownership, modes, API,
   platform transport lifecycle, safe PC001 sending, snapshots, and logs.
2. `08-28-gateway-dbc-periodic-engine`: add catalog/codec/persistence/scheduler,
   bus-load estimate, hash-bound protocol catalog, and shared RTK/IMU encoding
   authority.
3. `08-28-gateway-react-console-packaging`: build the UI, bundle static/DBC
   assets, update both distributions, and perform cross-layer packaged checks.

The order is deliberate: the UI consumes a stable API, and the DBC producer
must attach to the core ownership boundary rather than create a second send
path.
