# Godot tests

Deterministic fixtures and focused Godot-side checks belong here. Tests should cover scene contracts, motion decoding, generation guards and world-state repeatability as those milestones land.

Run the complete standalone matrix from PowerShell (replace the executable
with the installed Godot 4.7 binary when `godot` is not on `PATH`):

```powershell
.\tests\run_standalone_matrix.ps1 -GodotExe "E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe"
```

For one focused contract, run the same executable from `godot/client/`:

```powershell
& $GodotExe --headless --path . --script res://tests/foundation_scene_test.gd
```

The release-candidate matrix is:

```text
foundation_scene_test.gd
operator_ui_test.gd
camera_workflow_test.gd
jolt_capability_probe.gd
jolt_bucket_query_spike.gd
jolt_chassis_track_test.gd
jolt_articulated_equipment_test.gd
authority_shadow_test.gd
sensor_telemetry_test.gd
sy205_glb_test.gd
motion_client_test.gd
model_switch_test.gd
tracked_chassis_locomotion_test.gd
bucket_ground_lift_test.gd
construction_site_terrain_test.gd
terrain3d_adapter_test.gd
terrain_state_test.gd
excavation_gameplay_test.gd
visual_pass_test.gd
release_candidate_test.gd
offline_product_test.gd
```

These scripts are standalone `SceneTree` checks rather than an addon test
framework. They use fake transport or local seams and never require a running
Python service. The MCP add-on discovers only `res://tests/test_*.gd` classes
that extend `McpTestSuite`, so these files are intentionally run by the
PowerShell matrix instead of `test_run`; MCP remains a development-time scene
and runtime smoke tool.

`jolt_bucket_query_spike.gd` is the permanent real-Jolt query contract: it
asserts translational cast/endpoint overlap/rest-info behavior, exact terrain
collider ownership, initial overlap, bounded query cost, and teardown. The
articulated/runtime tests then assert the product hybrid shape: one chassis body,
four accepted kinematic frames, no work-equipment physics bodies, payload
slowdown, query identity, and bounded next-tick support wrench.

`offline_product_test.gd` is the default-product contract: it starts the real
main scene with Gateway disabled, exercises local lifecycle/reset and model
switching, and asserts that no Python listener is required.

The standalone matrix does not replace the live service probes:

```powershell
cd E:\projects\ExcavatorSim
pixi run backend-smoke
pixi run verify
```
