# Implementation checkpoint

## Delivered

- Added `VoxelCutPreparation`: private, bounded SDF snapshot job. It computes coverage and edits an isolated `VoxelBuffer`; no scene, terrain, material field or mutable authority access.
- Added `VoxelCutWorker`: `WorkerThreadPool` completion receipt. Main thread copies a bounded SDF halo, launches the job, polls completion without waiting, then pastes exactly once and runs the existing material ledger/support/readiness publication. `clear()` abandons the receipt; reset/model/revision changes cannot publish stale work. Application shutdown reaps active task.
- `VoxelExcavationAuthority` keeps one ordered preparation at a time, bounded 12-cut queue, at most 3 fixed ticks per coalesced proposal, generation/revision guards and scheduler telemetry. Product sets threaded mode with a 3ms main-side budget; normal 60Hz physics is unchanged.
- Recorder schema adds cut preparation slice columns and source hashes; analyzer labels these columns. Status contexts include pending, age, queue and worker totals.
- Tests add synchronous/sliced/threaded exact SDF/journal/mass parity over the 421-frame residual trajectory, no-publication-before-completion, reset cancellation, revision restart, live bucket-capacity change before publication, bounded queue ordering and worker cleanup.

## Verification

- `voxel_cut_preparation_test.gd`: PASS (`CUT_PREPARATION failures=0`), including three-way parity and cancellation/publication tests.
- `voxel_cutting_performance_test.gd`: PASS; coverage oracle and paired commit evidence retained.
- `performance_capture_test.gd`: PASS.
- `voxel_excavation_world_test.gd`: PASS.
- `python -m unittest discover -s tools/tests -p test_analyze_performance_capture.py -v`: 4 PASS.
- `git diff --check`: PASS (line-ending warnings only).

## Soak evidence

Baseline normal Forward+ replay: P99 63.876ms, max163.624ms, 139 frames >50ms, 360 transaction events, 3590 replay ticks.

Accepted threaded-v1 normal replay: clean Godot log; runner PASS; P99 28.600ms, max55.884ms, 2 frames >50ms, 359 transaction events + 41 deposits, 3601 replay ticks, max queue2, max age4 physics ticks, worker coverage2.559s/edit1.887s accumulated off main thread, conservation error0, no queue_full. Main-side preparation slice max2.947ms; publish remains synchronous and bounded by existing transaction/readiness semantics.

60 FPS diagnostic replay: P99 36.793ms/max65.189ms with the same worker/queue health; it confirms bounded display pacing and does not indicate worker starvation. Existing short replay uses `--allow-incomplete-scenario`; this is not release acceptance. Two remaining >50ms frames in threaded-v1 are status/publish/physics catch-up outliers; GPU remains under3ms. Memory gate and subjective manual feel remain separate acceptance items.

## Next

Human manual: repeat SY135 cutting/lift/dump at normal Forward+ settings, observe that soil appears with bounded latency, no visual rollback, and bucket feel remains responsive. If the two residual long frames must be eliminated, profile status publication/readiness and engine native mesh/collision update separately; do not increase the worker budget or hide failures by limiting physics steps.
