# Implementation plan

1. [x] Define persistent material/compaction and active-patch interfaces.
2. [x] Add generation-scoped fixed budgets and deterministic aggregate IDs.
3. [x] Build the CPU reference for activation, motion, contact, sleep, and settle.
4. [x] Add derived visual representatives and debug/performance telemetry.
5. [x] Benchmark standard cut/push/dump/pile scenarios at all quality profiles.
6. [x] Add compute path only if the CPU reference misses the documented gate. (Not required: CPU reference stays within the gate.)
7. [x] Select the production/fallback paths in a task-local decision record.
8. [x] Prove shadow invariance, conservation tolerance, cleanup, and regressions.

## Risk and rollback

- The prototype remains shadow-only and can be disabled without state migration.
- All settlement writes go through the scheduler; renderers never mutate field
  data.
- Do not accept a visually impressive path that requires unbounded particles or
  synchronous per-frame GPU readback.
