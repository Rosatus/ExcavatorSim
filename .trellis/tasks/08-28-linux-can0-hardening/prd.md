# Harden Linux can0 control and low-latency transmission

## Goal

Make the physical Linux `can0` path safe to configure and predictably low-latency
under adapter congestion, while preserving every CAN byte contract, complete CSV
recording, Windows PC001 behavior, and unrelated ICT functionality.

The work is split into two independently verifiable children:

1. `08-28-can0-helper-secure-lock` — root-only helper serialization and stable
   lock failure diagnostics.
2. `08-28-socketcan-low-latency-tx` — bounded kernel/userspace queues,
   non-blocking send, fairness, congestion semantics, and observability.

## Background and Confirmed Facts

- The archived `08-28-align-gateway-linux-can0-sending` task established the
  fixed helper, automatic Connect ICT preparation, SocketCAN sink, and a
  `can0 / 250 kbit/s / restart-ms=100 / txqueuelen=1000` readiness contract.
- The helper currently opens `/run/lock/excavatorsim-can0.lock` with `a+` and
  does not validate its parent, owner, mode, inode type, or link count
  (`tools/can_gateway/can0_setup.py:16-17,189-203`).
- All SocketCAN producers currently call synchronous `sock.send()` from the
  single Gateway owner loop. One blocked call delays commands, heartbeat,
  scheduling, UDP intake, and later CSV work (`tools/can_gateway/sinks.py:91-97`,
  `tools/can_gateway/gateway.py:542-585`).
- `ENOBUFS` currently becomes the same permanent `last_send_error` as unplug/down
  failures and retires ICT (`tools/can_gateway/sinks.py:91-97`,
  `tools/can_gateway/gateway.py:352-365`).
- CSV and SocketCAN share production fan-out but have separate sink instances;
  therefore SocketCAN buffering can be changed without changing encoded bytes or
  intentionally dropping CSV rows.

## Requirements

### R1 — Secure helper lock

- Use a root-owned runtime lock directory that ordinary users cannot create in
  or replace. Safely create/open and validate the directory and lock inode.
- Reject wrong owner, unsafe mode, symlink/non-regular/hard-linked lock objects,
  and open/flock failures before running any can0 mutation command.
- Convert lock creation, validation, open, and acquisition failures to a bounded
  stable `CAN0_SETUP_FAILED` diagnostic with no Python traceback.

### R2 — Bounded low-latency can0 transmission

- Change the readiness/helper contract to `txqueuelen=10` while preserving
  bitrate 250 kbit/s, `restart-ms=100`, no-cycle-ready behavior, and exact
  down/configure/queue/up/post-check ordering.
- Use non-blocking SocketCAN send. Treat `ENOBUFS`, `EAGAIN`, and
  `EWOULDBLOCK` as recoverable congestion drops; keep ICT active. Other send
  failures remain terminal and retain the current ICT teardown/result behavior.
- Before the kernel, keep a bounded latest-value queue: an unsent frame may be
  replaced by a newer frame with the same CAN ID. Scheduling must be fair across
  pending IDs/families so low-frequency RTK and travel frames cannot starve.
- Keep CSV writes independent and complete even when SocketCAN is permanently
  congested.
- Expose aggregate `submitted`, `sent`, `congestion_dropped`, `coalesced`, and
  `terminal_error` counts plus rate-limited diagnostic events; never log each
  successful or dropped physical frame individually.

### R3 — Compatibility boundaries

- Do not change CAN ID, DLC, payload, byte order, scale, DBC/manual encoding,
  EFF packing, producer cadence, or frame construction.
- Do not change Windows PC001, CAN receive behavior, Web DBC semantics, ICT
  control protocol, or unrelated Gateway lifecycle behavior.
- Preserve timed CAN ID `0x18FFF100`, payload `01 00 00 00 00 00 00 00`,
  nominal 50 Hz schedule, and fixed 10-second wall-clock window.

## Acceptance Criteria

- [ ] Both children pass their focused acceptance criteria and a parent
  cross-layer review proves no CAN byte or non-Linux transport drift.
- [ ] A ready `can0` uses `txqueuelen=10`; mismatched state invokes the fixed
  helper and post-verifies 10 without changing the remaining setup sequence.
- [ ] A hostile/preoccupied lock object cannot make the helper traceback or run
  a partial can0 mutation.
- [ ] Sustained SocketCAN congestion leaves Gateway/ICT responsive, bounds
  stale pending data, preserves low-frequency progress, and does not reduce CSV.
- [ ] Recoverable congestion and terminal transport failure produce distinct
  state transitions, counters, and bounded logs.
- [ ] Existing Gateway, DBC, timed scheduler, CSV, EFF packing, Godot launch,
  Web console, and PC001 regressions pass unchanged in wire semantics.
- [ ] Linux packaging and a target-host procedure verify helper permissions,
  real process mutual exclusion, `txqueuelen=10`, and congestion diagnostics.

## Out of Scope

- Any encoder, DBC schema, CAN frame content, receive path, Windows PC001, USB
  driver installation, `can0` creation, or general privilege framework change.
- Guaranteeing lossless physical delivery while the adapter cannot sustain the
  offered load; the required policy is bounded latency with observable loss.

## Key Decisions

- Timed CAN remains a 50 Hz logical schedule in one fixed 10-second wall-clock
  window. Each due occurrence is preserved in CSV when recording, but an unsent
  SocketCAN occurrence may be superseded by the next same-ID occurrence.
- Congestion may therefore reduce timed CAN's physical `sent` count below 500.
  The window is never extended and missed/unsent frames are never replayed.
- Any timed frame still pending at the 10-second deadline is discarded and
  counted; it cannot leak onto can0 after the command window ends.
