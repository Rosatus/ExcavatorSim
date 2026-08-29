# Godot-first release-candidate boundary

The release candidate keeps a standalone Jolt-authoritative Godot product plus
an optional gateway and two explicit Python compatibility profiles:

- `gateway-only`: an optional Python service owns only gateway lifecycle/input
  validation, model identity and bounded telemetry storage. It does not
  construct/step Simulator or emit `view_state`; Godot/Jolt owns product motion
  and contacts even when this service is running.
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

The standalone matrix includes `offline_product_test.gd`; this is the required
offline-default smoke and must pass with no service listening on port 8765.

Final product-experience evidence uses
`godot/client/tests/capture_visual_baseline.ps1 -EvidencePhase after`. The
automated driver proves real tooth contact, curl, nonzero carry, outward dump,
terrain change, support, reset, artifact integrity, and error logs for both
models and all quality profiles. Composition, endpoint naturalness, camera
clipping, material appeal, audio balance, and five-minute discoverability remain
one explicit human gate; automated screenshots do not approve those judgments.

## Reproducible release evidence

Run the following from the repository root. The standalone runner accepts an
explicit Godot 4.7 executable, so it does not depend on a user profile PATH:

```powershell
.\godot\client\tests\run_standalone_matrix.ps1 `
  -GodotExe "E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64.exe"
.\godot\client\tests\run_terrain3d_release_validation.ps1
pixi run backend-smoke
pixi run verify
```

The Terrain3D release runner keeps the production entry scene unchanged. It
exports an isolated Windows smoke entry, proves native-default/material and
source/export lifecycle parity, exercises the explicit `soil_shader` rollback,
verifies the native DLL against its vendored release binary, and stages license
and provenance files beside the package. The rollback does not migrate authority
data.

Run the rendered Jolt product soak against a fresh `gateway-only` process for
both models:

```powershell
pixi run soak-jolt-quick
pixi run soak-jolt-release
```

Quick mode runs 90 seconds per model; release mode runs 15 minutes per model.
Both commands pass `--quality-profile balanced` explicitly. For the full visual
quality integration gate, run `pixi run soak-jolt-quality-matrix`; it executes
the same 90-second interaction/lifecycle scenario for SY205 and SY135 at low,
balanced, and high quality. Reports use the v2 schema and reject missing or
mismatched requested/observed quality identity.
The dedicated benchmark process disables VSync so frame percentiles measure
renderer throughput instead of the display refresh wait; product display
settings are not changed.
The gate requires fixed-step p95 <= 4 ms and peak <= 10 ms, rendered-frame p95
<= 16.7 ms and p99 <= 33.3 ms, zero telemetry drops, bounded 256-batch history,
and post-warmup combined Godot/backend working-set growth <= 10% and <= 128 MiB.
It also requires track and articulation movement, cut/load/dump/support evidence,
reset, reconnect, the selected model identity, and exactly one Jolt runtime. The
JSON report and per-process logs are written under `artifacts/benchmark/`.

The soak runner also supports the bucket pass-through inverse contract. For the
required alternating three-pair balanced comparison on both production models:

```powershell
pixi run python backend/scripts/jolt_product_soak.py --models sy205 sy135 --quality-profile balanced --bucket-ground-mode normal bucket_passthrough --repetitions 3 --output artifacts/benchmark/bucket-pass-through-paired.json
```

Each pass-through cell requires zero bucket query execution, soil steps,
bucket terrain commits, payload, cut/dump, support response, and effects update,
while the corresponding bypass counters must advance. The summary records all
six raw fixed-step p95 values per model, their mode medians, counter deltas, and
requires the pass-through median to be lower than the normal median. Ordinary
mode retains the existing cut/load/dump/support gates unchanged.

Repetitions alternate order (`normal/pass-through`, `pass-through/normal`, then
`normal/pass-through`) and record run ordinal plus a stable trace identity.
ProductSession owns model and lifecycle; MotionClient is connected explicitly
only for Gateway telemetry/reconnect coverage. Active-patch dump/spill evidence
comes from accepted authority transactions. Completed inert scenario cells are
never retried or discarded; only a pre-scenario Gateway health startup failure
may receive the existing single retry.

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

For the authoritative smoke, use the default
`simulation/authority_profile=jolt_authoritative` through
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
