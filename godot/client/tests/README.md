# Godot tests

Deterministic fixtures and focused Godot-side checks belong here. Tests should cover scene contracts, motion decoding, generation guards and world-state repeatability as those milestones land.

Run the complete standalone matrix from PowerShell. It resolves the pinned
Godot 4.7.2 custom editor + Voxel Tools 1.7 from
`tools/godot_voxel_toolchain.json` and verifies its hash/version before launch:

```powershell
.\tests\run_standalone_matrix.ps1
```

Use `GODOT_VOXEL_ROOT` or `-ToolchainRoot` when the four pinned binaries are
installed outside the lock's default root. `-GodotExe` is retained for an
explicit editor path but does not bypass the pinned hash/version checks.

For one focused contract, run the same executable from `godot/client/`:

```powershell
& $GodotExe --headless --path . --script res://tests/foundation_scene_test.gd
```

Validate the Terrain3D product default and an actual Windows export from the
repository root:

```powershell
.\godot\client\tests\run_terrain3d_release_validation.ps1
```

This uses an isolated temporary project to select
`terrain3d_export_smoke.tscn` as the exported entry. It does not modify the
product main scene. Structured source/export evidence and the staged package
are written under `output/terrain3d_phase4/`.

The release-candidate matrix is:

```text
voxel_module_smoke.gd
foundation_scene_test.gd
operator_ui_test.gd
camera_workflow_test.gd
machine_feedback_test.gd
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
