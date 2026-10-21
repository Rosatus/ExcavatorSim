# Implementation Plan — Bounded low-latency SocketCAN transmission

## 1. Baseline and contract tests

- [ ] Record focused sink/Gateway/timed/DBC/CSV/PC001/Web/package results.
- [ ] Add failing tests showing current ENOBUFS retirement, blocking socket,
  stale FIFO potential, and txqlen 1000 contract.

## 2. Fixed can0 queue

- [ ] Change `CAN_TX_QUEUE_LEN` to 10 and update readiness, helper command,
  post-check, fixtures, source Web copy, README, spec, and package assertions.
- [ ] Preserve bitrate 250000, restart-ms 100, ready no-cycle, mutation order,
  and absence/no-create behavior.

## 3. SocketCAN TX scheduler

- [ ] Add typed pending-frame/outcome/stat structures and source/family labels.
- [ ] Implement global per-ID latest slots, bounded capacity, family/ID
  round-robin rings, replacement/migration, purge-by-generation, and invariants.
- [ ] Make the socket non-blocking and add finite owner-loop `service()` calls.
- [ ] Route Godot IMU/RTK/slew/travel, Web DBC, and timed occurrences with
  metadata while keeping CSV immediate and PC001 behavior unchanged.

## 4. Error and lifecycle integration

- [ ] Classify ENOBUFS/EAGAIN/EWOULDBLOCK as count/drop/yield without ICT
  teardown; cover errno aliases portably.
- [ ] Preserve all other send errors as terminal and reuse current disarm,
  close, ICT result, and no-auto-resume behavior.
- [ ] Purge timed generation state on deadline/retrigger/stop/reconfigure/error;
  prove no late frame or catch-up leaves the queue.

## 5. Observability

- [ ] Publish monotonic SocketCAN totals/pending count in Gateway status and Web
  contract fixtures/types.
- [ ] Extend aggregate events for source/family/ID outcomes and bounded reasons.
- [ ] Display diagnostic totals without per-frame event/disk/browser spam.

## 6. Verification

- [ ] Unit-test capacity, same-ID overwrite, family/ID fairness, source-family
  migration, recoverable errno drops, terminal latch, finite service budget,
  and purge semantics with fake sockets/clocks.
- [ ] Process-test permanent congestion liveness, CSV completeness, recovery
  freshness, ICT active state, aggregate counters, and terminal failure.
- [ ] Test timed 50 Hz/10-second logical count and CSV count while physical
  sent is lower, with zero post-deadline sends and no replay.
- [ ] Run full Gateway/backend regression, frontend lint/typecheck/tests/build,
  provenance, Linux shell/package checks, and PC001 non-regression.
- [ ] Document target-PCAN overload procedure and capture real sent/drop/latency
  evidence separately from deterministic CI.

## Rollback

- Revert scheduler, status DTO, Web copy, and txqlen contract together. Never
  leave the smaller kernel queue paired with the old terminal-on-ENOBUFS path.
