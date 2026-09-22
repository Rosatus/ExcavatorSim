# Implementation Plan — Physical CAN PC001 bridge

## 1. Preserve baseline

- [x] Create original and modified project-root snapshots before source edits.
- [x] Record SHA-256 hashes and exclude transient `__pycache__`/`.pyc` files.
- [x] Establish the focused test baseline or record missing test dependencies.

## 2. Physical preparation and routing

- [x] Separate virtual and physical default channel mappings.
- [x] Add read-only interface validation and txqueuelen-only preparation.
- [x] Convert `setup_can0.sh` into the compatible physical bridge launcher.

## 3. Low-latency bridge egress

- [x] Implement non-blocking per-interface sockets and bounded per-ID latest
  slots with fair service and finite budgets.
- [x] Split TCP receive and CAN service into independent asyncio tasks.
- [x] Add recoverable-congestion, unmapped-channel, disconnect-purge, and
  terminal-error semantics plus aggregate counters.

## 4. Verification and delivery

- [x] Add deterministic unit tests for routing, exact bytes, coalescing,
  fairness, bounds, errno handling, reader liveness, and setup mutations.
- [x] Run focused and full can_replay tests plus Python/shell static checks.
- [x] Generate hashes, application notes, and portable `changes.patch`.
- [x] Verify plain `git apply --check`, apply to scratch, and byte-compare the
  result to the modified snapshot.

## Rollback

Use `original-project` as the byte-preserved rollback source. Do not combine the
new physical launcher with the old blocking/FIFO bridge or `txqueuelen=1000`.
