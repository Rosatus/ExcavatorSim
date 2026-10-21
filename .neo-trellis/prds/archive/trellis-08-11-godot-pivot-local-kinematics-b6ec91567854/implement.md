# Implement SY205 local pivot kinematics

## Checklist

1. [x] Add guide-backed local pivot contract metadata/fixtures without editing
   the GLB or changing protocol identifiers.
2. [x] Replace independent nested global writes with root base delta plus
   adjacent-frame local single-axis rotation deltas; retain finite/residual
   guards and last-valid behavior.
3. [x] Re-run passive four-bar solver after corrected hierarchy application and
   restore all captured local pivot/control transforms on reset/stale/disconnect.
4. [x] Add guide local position/parent/axis/scale tests and independent
   boom-only, arm-only, bucket-only, asymmetric, unreachable and zero-restore
   regression cases.
5. [x] Update frontend motion spec/docs with the local-pivot authority boundary
   and the distinction between Python link-frame origins and visual pin origins.
6. [x] Run MCP runtime smoke on the real GLB, Godot standalone matrix,
   `pixi run backend-smoke`, `pixi run verify`, task validation and diff check.
7. [x] Run Trellis quality check, commit scoped changes, archive task and record
   session journal after explicit approval of this planning summary.

## Risky files

- `godot/client/scripts/motion_presentation.gd`: local delta order and axis
  extraction; incorrect multiplication order can invert or offset joints.
- `godot/client/tests/motion_client_test.gd`: must test local invariants rather
  than only global parity, otherwise the old defect can pass again.
- `godot/client/resources/visual/sy205_visual_manifest.json`: separate source
  authoring axes from runtime axes; do not rename GLB paths.

## Validation commands

```powershell
& 'E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe' --headless --path godot/client --editor --quit
& .\godot\client\tests\run_standalone_matrix.ps1 -GodotExe 'E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe'
pixi run backend-smoke
pixi run verify
python ./.trellis/scripts/task.py validate 08-11-godot-pivot-local-kinematics
git diff --check
```
