# Implementation plan

1. [x] Add guide-backed passive linkage metadata and context manifests without
   changing the GLB or Python protocol.
2. [x] Implement the arm-local Y-Z circle-intersection solver in the Godot
   presentation layer, including branch continuity, finite guards and reset.
3. [x] Invoke the solver after authoritative frame application and restore its
   local controls on pose clear/zero/reset.
4. [x] Extend GLB and motion parity tests for A/B/C/D paths, AB/AC/CD lengths,
   passive motion, unreachable-pose safety and rest restoration.
5. [x] Update the frontend/code-spec with the four-bar authority boundary and
   failure behavior.
6. [x] Run Godot standalone matrix, MCP live motion/linkage smoke,
   `pixi run backend-smoke`, `pixi run verify`, task validation and
   `git diff --check`.
7. [x] Commit the scoped fix, archive the task and record the session journal.

## Risky files and rollback points

- `godot/client/scripts/motion_presentation.gd`: passive solver runs after every
  authoritative pose and must not overwrite the five frame globals.
- `godot/client/resources/visual/sy205_visual_manifest.json`: linkage metadata
  must describe existing paths only; no asset re-export.
- `godot/client/tests/motion_client_test.gd`: all geometry assertions are
  presentation-only and must not become backend tooth/physics parity claims.

## Validation commands

- `godot/client/tests/run_standalone_matrix.ps1 -GodotExe "E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe"`
- `pixi run backend-smoke`
- `pixi run verify`
- `python ./.trellis/scripts/task.py validate 08-11-godot-passive-fourbar-linkage`
- `git diff --check`
