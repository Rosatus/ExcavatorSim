# Bound SocketCAN latency under congestion

## Goal

Prefer fresh physical telemetry over lossless stale playback when the Linux
PCAN-USB FD cannot sustain Gateway's offered load, while keeping CSV complete,
ICT alive through recoverable congestion, and every CAN byte unchanged.

## Background

- `SocketCanSink.append()` currently calls blocking `sock.send()` directly and
  latches every `OSError` as terminal (`tools/can_gateway/sinks.py:67-100`).
- Timed, Web DBC, and Godot telemetry producers all execute in the single owner
  loop and call that sink synchronously (`tools/can_gateway/gateway.py:336-343,
  542-585,760-818`).
- `txqueuelen=1000` is centralized in `CAN_TX_QUEUE_LEN` but repeated in tests,
  Web copy, README, and built assets (`tools/can_gateway/can0_setup.py:12-16`,
  `tools/can_gateway/tests/test_can0_setup.py:30-136`,
  `tools/can_gateway/web/src/App.tsx:126-127`).

## Requirements

### Kernel and syscall boundary

- Set the fixed can0 readiness/helper target to `txqueuelen=10`, update all
  source-owned tests/docs/UI, and regenerate the Web bundle.
- Put the SocketCAN socket into non-blocking mode.
- Classify `ENOBUFS`, `EAGAIN`, and `EWOULDBLOCK` as recoverable congestion;
  count/drop according to queue policy and continue servicing ICT. All other
  send `OSError` values remain terminal, disarm periodic/timed sending, close
  the transport, and report the established ICT send failure.

### Latest-value queue and fairness

- Insert a bounded SocketCAN-only transmit buffer before `sock.send`; CSV stays
  an immediate independent sink.
- Keep at most one pending payload per CAN ID. A newer submission for an
  already-pending ID replaces the old payload and increments `coalesced`.
- Service pending work with deterministic round-robin fairness across CAN
  IDs/families and a finite per-loop syscall budget. Continuous high-frequency
  IMU/DBC traffic must not starve low-frequency RTK or travel IDs.
- Define a fixed maximum set of pending IDs and deterministic overflow behavior;
  overflow must be counted and cannot create an unbounded or FIFO history.
- A congestion return must not spin: drop the attempted occurrence, yield to
  the owner loop, and let a later producer submit a fresh value fairly.

### Observability and compatibility

- SocketCAN owns raw counters `submitted`, `sent`, `congestion_dropped`,
  `coalesced`, and `terminal_error`; the Gateway runtime publishes snapshots and
  one-second/rate-limited aggregates by source/family and CAN ID.
- Do not infer SocketCAN success from CSV availability. Log lifecycle/error and
  aggregate congestion records only; no per-frame log spam.
- Preserve IDs, DLC, payload, endian, scale, DBC/manual codecs, EFF packing,
  producer schedules, Windows PC001, receive behavior, and Web editing behavior.
- Preserve timed CAN ID/payload/nominal 50 Hz/10-second wall-clock definition.
  CSV retains every due occurrence; SocketCAN permits same-ID coalescing and
  congestion loss, never extends/catches up, and discards a pending timed frame
  at the deadline so no late command escapes the window.

## Acceptance Criteria

- [ ] can0 readiness and helper require `txqueuelen=10`; ready state skips a
  cycle and mismatch performs the unchanged fixed transaction with value 10.
- [ ] A fake SocketCAN socket proves non-blocking configuration and errno
  classification for all three recoverable values plus representative terminal
  unplug/down errors.
- [ ] Repeated same-ID submissions leave only the newest payload pending and
  produce exact coalesced counts; pending memory and ID count remain bounded.
- [ ] Deterministic stress tests prove round-robin progress for RTK/travel while
  high-rate IDs continuously overwrite their slots, with no busy-loop or FIFO
  replay after recovery.
- [ ] Permanent congestion keeps owner-loop commands, heartbeat/snapshots,
  schedulers, and UDP processing live and keeps ICT active.
- [ ] CSV contains every expected row even when physical `sent == 0`; recovery
  sends only current pending values, never seconds of historical frames.
- [ ] Submitted/sent/congestion-dropped/coalesced/terminal-error statistics and
  bounded aggregate logs match injected outcomes.
- [ ] Terminal failures still retire SocketCAN and disarm timed/Web periodic
  sending; recoverable congestion never does.
- [ ] Existing exact CAN packing, frame-golden, DBC, timed, CSV, Godot, Web, and
  Windows PC001 tests retain wire semantics.

## Out of Scope

- Lossless physical delivery under overload, changing producer cadence or CAN
  bytes, Windows PC001 buffering, CAN receive, adapter driver changes, or a
  general multi-threaded transport rewrite.

## Key Decisions

- Use SocketCAN-only latest-value buffering; CSV never enters this queue.
- Use deterministic two-level family/ID round robin rather than insertion-order
  draining, so a family with many hot IDs cannot indefinitely suppress RTK or
  travel.
- A non-blocking congestion errno drops the attempted occurrence, keeps the
  transport active, stops the current drain turn, and lets a future producer
  submit a fresh value. It is not retained as a retry backlog.
- Timed CAN is coalescible and droppable under congestion. Its logical schedule
  and CSV record remain 50 Hz for 10 seconds, while physical delivery is
  explicitly best effort and observable through counters.
