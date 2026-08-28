# Implementation Plan — Linux can0 hardening integration

## 1. Baselines

- [ ] Record current helper lock failure, can0 readiness/setup, SocketCAN error,
  timed, CSV, PC001, DBC, Web contract, and package test results.
- [ ] Preserve exact frame/golden and EFF packing fixtures as non-regression
  authority; do not regenerate them unless a provenance-only dependency hash
  requires it.

## 2. Secure-lock child

- [ ] Complete and check `08-28-can0-helper-secure-lock` first.
- [ ] Verify root-only lock creation/validation, stable diagnostics, concurrency,
  and unchanged fixed helper/install contract.

## 3. Low-latency TX child

- [ ] Complete and check `08-28-socketcan-low-latency-tx` on the hardened helper.
- [ ] Verify `txqueuelen=10`, non-blocking send, fair bounded coalescing,
  congestion/terminal separation, CSV independence, timed deadline semantics,
  statistics, logs, Web DTO/copy, and package output.

## 4. Parent integration gate

- [ ] Run focused Gateway unit/process tests and the full backend quality gate.
- [ ] Run frontend lint/typecheck/component tests and production build.
- [ ] Check Python formatting/types, provenance, standalone paths, and Linux
  shell syntax/package asset layout.
- [ ] Inspect Windows PC001 tests to prove no behavior/counter drift.
- [ ] On target Linux, verify helper owner/mode, concurrent invocation,
  `ip -j -d link show can0` reports txqlen 10, sustained overload remains
  responsive, counters rise, stale frames do not replay, and unplug/down remains
  terminal. Keep hardware evidence separate from deterministic CI results.

## 5. Finalization

- [ ] Update `.trellis/spec/backend/can-gateway-control.md` with the root-only
  lock and SocketCAN queue/error/statistics contracts.
- [ ] Commit implementation, archive both children then parent, record session,
  and push only after all non-hardware gates pass.

## Rollback points

- Keep the lock hardening independently revertible before changing TX policy.
- Do not ship `txqueuelen=10` without the non-blocking/coalescing/error changes;
  the smaller kernel queue intentionally exposes congestion sooner.
- Do not ship new statistics if CSV and SocketCAN success remain conflated.
