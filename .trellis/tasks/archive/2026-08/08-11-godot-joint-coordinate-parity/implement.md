# Implementation plan

1. [x] Add the shared Z-up-to-Y-up conjugation to
   `MotionProtocol.rows_to_transform()` with pure matrix conversion tests.
2. [x] Extend the local parity fixture with the backend
   `swing_positive_90` five-frame handoff and preserve its source hash.
3. [x] Strengthen mounted-scene parity assertions for all five frames at zero,
   swing-positive-90 and asymmetric poses.
4. [x] Clarify source-authoring versus runtime Godot axes in the visual manifest
   and update focused GLB contract assertions without changing the GLB.
5. [x] Verify the Godot-local bucket tooth proxy follows the corrected bucket
   transform without introducing backend tooth authority.
6. [x] Update the frontend motion-transport spec with the executable coordinate
   conversion and parity requirements.
7. [x] Run the seven-script Godot standalone matrix, MCP live motion smoke,
   `pixi run backend-smoke`, `pixi run verify`, task validation and
   `git diff --check`; inspect each joint direction visually.
8. [x] Commit the scoped fix, archive the completed Trellis task and record the
   session journal.

## Risky files and rollback points

- `godot/client/scripts/motion_protocol.gd`: every accepted pose uses this
  boundary; conversion must occur exactly once.
- `godot/client/scripts/motion_presentation.gd`: zero offset and live pose must
  share the converted semantics.
- `godot/client/tests/fixtures/sy205_frame_parity_cases.json`: copied values must
  remain traceable to the hashed backend baseline.
- `godot/client/resources/visual/sy205_visual_manifest.json`: metadata change
  must not alter source GLB bytes or node paths.

## Validation commands

```powershell
.\godot\client\tests\run_standalone_matrix.ps1 `
  -GodotExe "E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe"
pixi run backend-smoke
pixi run verify
python ./.trellis/scripts/task.py validate 08-11-godot-joint-coordinate-parity
git diff --check
```
