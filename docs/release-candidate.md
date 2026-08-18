# Godot-first release-candidate boundary

The release candidate keeps two explicit runtime profiles:

- `motion-only`: Python owns kinematics, input safety and lifecycle; Godot owns
  its local deterministic terrain, bucket convenience state and presentation.
- `legacy`: the existing Python terrain, recording and replay services remain
  available for compatibility and protocol regression coverage.

The legacy terrain/recording/replay implementation is intentionally retained in
this milestone. It will only be deprecated or archived after an independently
approved migration plan identifies all clients, telemetry and rollback needs.
No Godot local terrain, bucket volume, particles or physics transforms are sent
back to Python.

Release-candidate checks include the Godot standalone matrix in
`godot/client/tests/README.md`, Godot MCP scene/runtime smoke, and `pixi run
verify` for the backend/provenance/standalone gates.

## Reproducible release evidence

Run the following from the repository root. The standalone runner accepts an
explicit Godot 4.7 executable, so it does not depend on a user profile PATH:

```powershell
.\godot\client\tests\run_standalone_matrix.ps1 `
  -GodotExe "E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe"
pixi run backend-smoke
pixi run verify
```

The backend smoke starts a temporary legacy service and verifies health, URDF,
the five-part visual manifest/GLB, WebSocket handshake, aligned `view_state` /
`terrain_view`, and the authoritative Float32 terrain snapshot. It is kept out
of `pixi run verify` because it launches a live network process.

With the Godot editor connected to MCP, use this exact smoke sequence:

1. `editor_manage({"op":"state"})` must report `project_name="ExcavatorSim"`,
   Godot 4.7.x and `readiness="ready"`.
2. `scene_open({"path":"res://scenes/main.tscn"})`, then
   `project_run({"mode":"main"})`.
3. `game_manage({"op":"get_ui_elements"})` must expose the connection,
   authority/lifecycle and bucket-soil status labels; inspect
   `PresentationRoot/SY205Excavator`, `TerrainRoot/TerrainWorld`,
   `TerrainRoot/ExcavationWorld`, `VisualEnvironment`, `CameraRig` and
   `SoilEffects` with `game_manage({"op":"get_scene_tree"})`.
4. Exercise Start and Reset through `game_manage({"op":"input_action",...})`
   or `editor_manage({"op":"game_eval",...})`; observe lifecycle revision and
   authority-generation changes, pose clearing and bucket-soil reset. Stop the
   game with `project_manage({"op":"stop"})`.

For the opt-in authoritative smoke, preserve the current
`simulation/authority_profile`, set it to `jolt_authoritative` through
`project_manage(settings_set)`, run the main scene, and inspect the controller's
current runtime snapshot. For both SY205 and SY135 it must contain exactly one
`chassis` body, four named `kinematic_frames`, four logical joints, and a bucket
query carrying matching authority/tick/terrain/motion identity. The runtime tree
must contain no work-equipment `RigidBody3D` or `HingeJoint3D`. Restore the saved
profile after stopping, even when the smoke fails. Long cutting/support motion
is covered by `jolt_bucket_query_spike.gd`, `jolt_articulated_equipment_test.gd`,
and `excavation_gameplay_test.gd`; MCP remains the live composition check.

MCP test discovery is not part of this matrix: the add-on only loads
`res://tests/test_*.gd` `McpTestSuite` classes, while the product contracts are
standalone `SceneTree` scripts. This keeps the optional editor bridge from
becoming a runtime or CI dependency.
