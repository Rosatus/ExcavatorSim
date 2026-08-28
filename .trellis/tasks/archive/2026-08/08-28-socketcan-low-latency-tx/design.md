# Design — Bounded low-latency SocketCAN transmission

## 1. Ownership and data flow

The Gateway owner loop remains the sole transport owner. SocketCAN gains a
bounded submit/service split; no background writer is introduced.

```text
producer occurrence (Godot / DBC / timed)
  ├─ CSV append immediately (complete logical stream)
  └─ SocketCAN submit(source, family, id, payload)
       ├─ same pending ID: replace old → coalesced++
       ├─ new ID and capacity: enqueue in family/ID rings → submitted++
       └─ capacity full: drop occurrence → congestion_dropped++

owner-loop SocketCAN service(finite syscall budget)
  → choose next family round-robin
  → choose next CAN ID in family round-robin
  → nonblocking send(pack_can_frame(id, payload))
       success: sent++, remove occurrence
       ENOBUFS/EAGAIN/EWOULDBLOCK: drop occurrence, congestion_dropped++, yield
       other OSError: terminal_error++, latch, yield to existing retirement
```

`pack_can_frame` stays immediately before the syscall and is unchanged.

## 2. Bounded latest-value scheduler

Use one global pending slot per normalized raw CAN ID plus a two-level ready
ring: families rotate, then IDs within a family rotate. On replacement, update
payload/source/timestamp in place without adding another ring entry. If the
latest source changes family, move the one ID entry atomically between rings.

Initial source-owned constants:

- maximum pending IDs: 128
- maximum send syscalls per owner-loop turn: 32

They are not user-facing tuning knobs in this task. Tests assert bounds and
fairness properties rather than relying on wall-clock performance. Capacity
overflow drops the newly submitted occurrence and retains the already-fair
pending set; it is counted with reason `capacity`.

Families are explicit producer metadata, at minimum `imu`, `rtk`, `slew`,
`travel`, `dbc`, and `timed`. Per-ID uniqueness remains global, so two sources
cannot build parallel stale queues for the same arbitration ID.

## 3. Congestion and terminal errors

The socket is configured non-blocking immediately after construction and before
bind/use. `ENOBUFS`, `EAGAIN`, and `EWOULDBLOCK` are the same recoverable class
(deduplicate aliases on platforms where errno values match). The attempted
occurrence is discarded, the socket remains usable, and the service turn stops
to avoid spinning against a full kernel queue.

All other send `OSError` values latch one terminal error. Gateway then reuses
the existing SocketCAN retirement path: disarm timed and DBC periodic send,
close ICT, publish failure, and never auto-resume.

## 4. Timed CAN

Timed CAN continues to produce due occurrences at nominal 20 ms intervals for
one 10-second monotonic window, with the same ID/payload and existing no-catch-up
scheduler. CSV receives every due occurrence when recording.

SocketCAN treats `0x18FFF100` as family `timed` and one latest-value slot.
Congestion/coalescing may make physical `sent < 500`. At stop, retrigger,
transport reconfigure, terminal error, or the 10-second deadline, purge any
pending occurrence owned by the retired timed generation. Generation tagging
prevents a late frame from the previous window escaping into a new one.

## 5. Statistics and logs

SocketCAN maintains monotonic totals and per `(source, family, CAN ID)` deltas:

- `submitted`: every occurrence offered to SocketCAN
- `sent`: successful kernel syscall
- `coalesced`: pending occurrence superseded before syscall
- `congestion_dropped`: capacity/deadline purge or recoverable-send rejection
- `terminal_error`: terminal syscall event count

These fields need not be mutually exclusive accounting identities; pending is
reported separately when needed. `GatewayRuntimeCore` publishes totals in the
status DTO and folds deltas into existing one-second aggregate events with a
reason field. Lifecycle and terminal events remain immediate; congestion is
rate-limited/aggregated and never logged per frame. Web types/fixtures display
the Linux totals without adding transport controls to managed mode.

## 6. txqueuelen and packaging

Change the single readiness constant from 1000 to 10 and propagate it through
helper command tests, readiness fixtures, helper/Web text, README/spec, built
Web assets, and Linux packaging smoke checks. Bitrate/restart/setup order stay
unchanged. Smaller kernel backlog and userspace latest-value coalescing ship as
one unit.

## 7. Compatibility and rollback

CSV, frame codecs, EFF packing, PC001, receive, DBC editing, and producer
cadences remain unchanged. Rollback must restore the Gateway and helper together
because a binary expecting txqlen 10 must not silently accept a 1000 queue.
