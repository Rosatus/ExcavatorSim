# Implementation Plan: Generate SY205 URDF from GLB

1. [x] Add focused GLB decode and transform helpers under the generation script.
2. [x] Add the checked-in v4 estimation parameter file with explicit provisional labels.
3. [x] Generate link bounds, fixed landmarks, primitive proxies, masses, and inertias.
4. [x] Render and validate the candidate URDF and evidence manifest through validated sibling-file
       replacements with rollback on commit failure.
5. [x] Preserve the old URDF bytes as `assets/model/library/sy135_reference.urdf` for future SY135
       GLB work.
6. [x] Add generator unit tests for determinism, coordinates, malformed inputs, and estimates.
7. [x] Run focused Ruff, strict mypy, pytest, full `pixi run verify`, and `git diff --check`.

Exit gate: candidate artifacts exist and pass Pinocchio/contract tests, while
`backend/src/babylon_sim/paths.py` and the current runtime default remain unchanged.
