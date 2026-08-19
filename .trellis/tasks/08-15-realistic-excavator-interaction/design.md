# Final interaction acceptance design

## Design Intent

This task is an evidence and harness closeout, not another simulation architecture
phase. It consumes the accepted hybrid Jolt product path and proves that its
interaction remains stable across model, quality, lifecycle, and endurance axes.

## Authority Guardrail

```text
track/work-equipment inputs
  -> one hybrid Jolt fixed-step snapshot
  -> TerrainState/BucketSoilState transaction
  -> visual quality projection
  -> rendered evidence + sensor telemetry
  -> Python gateway validation/reporting
```

The harness may select a quality profile and observe state. It cannot write
chassis pose, joint pose, terrain volume, bucket inventory, or presentation
frames. Python remains a gateway/observer. The quality controller changes bounded
effects budgets only; it does not fork gameplay state.

## Evidence Matrix

| Gate | Models | Quality | Duration | Purpose |
|---|---|---|---:|---|
| Release endurance | SY205, SY135 | balanced | 900 s each | Published pre-release stability gate |
| Quality integration | SY205, SY135 | low, balanced, high | 90 s each | Full interaction and lifecycle coverage per tier |
| Live visual review | SY205, SY135 | low, balanced, high | scenario checkpoints | Human-readable soil/support evidence |

Release endurance remains separate from the quality matrix so the release gate
does not grow from 30 to 90 minutes. The quality matrix is long enough to execute
the existing loaded phases, reset, and reconnect, but is not treated as an
endurance claim.

## Harness Contract

- Add an explicit quality-profile argument to the Python and Godot soak runners.
- Keep `balanced` as the explicit default for existing quick/release commands.
- Add `soak-jolt-quality-matrix` as the six-cell runner.
- Each Godot result and aggregate row carries schema version, model id, requested
  and observed quality profile, authority profile, lifecycle evidence, and current
  performance/interaction metrics.
- The shared evaluator rejects unknown/missing quality values and a requested /
  observed mismatch before accepting a cell.
- Reports remain under ignored `artifacts/benchmark/`; the task research note
  records command, thresholds, hashes, and compact results.

## Visual Evidence Contract

Godot AI MCP is used after automated gates prove the scene is stable. For each of
the six cells, inspect the live authority/runtime identity and capture representative
carry, dump/deposit, terrain-change, and support frames. Assemble selected captures
into one compact committed contact sheet. The evidence note records the capture
mapping and separates observation (what is visible) from inference (why it is
considered acceptable).

## Failure Handling

- Harness/schema/identity failures: fix in this task, add regression coverage, and
  rerun affected cells.
- Product correctness regressions in existing scoped behavior: fix narrowly, run
  the full matrix again, and document the regression.
- Visual preference or physics-fidelity shortfall requiring tuning/redesign: create
  a separate Trellis task; do not lower budgets or widen this parent silently.
- Release endurance failure: retain raw logs/report, stop parent closeout, and
  isolate the failing model/profile before any change.

## Rollback

Harness changes are additive. Removing the new matrix command and quality argument
returns to the accepted quick/release runner without changing product runtime state.
No product profile, descriptor, or authority fallback is changed by this task.
