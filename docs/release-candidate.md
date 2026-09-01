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

Run the following from the repository root. The runners resolve and verify the
pinned Godot 4.7.2 custom build with Voxel Tools 1.7, so they do not depend on a
user profile PATH:

```powershell
.\godot\client\tests\run_standalone_matrix.ps1
.\godot\client\tests\run_terrain3d_release_validation.ps1
pixi run backend-smoke
pixi run verify
```

`tools/godot_voxel_toolchain.json` locks the upstream `v1.7` assets, archive
and extracted-binary SHA-256 values, engine commit, and default toolchain root
`E:/applications/godot_voxel`. A machine may override that root with
`GODOT_VOXEL_ROOT` or `-ToolchainRoot`; `-GodotExe` remains available as the
highest-priority editor override. Every selected binary is still checked
against the lock before Godot starts; standard builds only are accepted, not
`double` or `tracy` variants.

After the implementation and focused checks are stable, build the distributable
Windows and Linux packages once from the repository root:

```powershell
.\tools\build_release_dist.ps1
```

The builder rebuilds both Gateway targets, creates an isolated copy of the
Godot project, injects the pinned Windows/Linux custom release-template paths
only into that copy, exports both presets into a staging directory, places the
platform Gateway beside the corresponding Godot executable, stages notices,
and only then replaces `godot/dist/windows` and `godot/dist/linux`. The tracked
`export_presets.cfg` therefore keeps both debug templates and release templates
empty. Each platform package and each standalone Gateway package contains
`build-manifest.json`. The Godot package sidecars additionally record the
verified editor/template version, upstream release, engine commit, and input
hashes under `build_toolchain`; all sidecars retain source commit, dirty-tree
state, software version, and raw-byte SHA-256 of every shipped file except the
manifest itself. A formal release should be built from a clean tree; a dirty
development build remains usable but is labelled `git_tree_dirty: true`.
Distribute Linux as `godot/dist/ExcavatorSim-linux-x86_64.tar.gz`; the archive
normalizes executable and data-file POSIX modes. Runtime `output/` residue found
in an old Gateway package is preserved under `output/release-build-residue` and
is never copied into the new release.

The Terrain3D release runner keeps the production entry scene unchanged. It
exports an isolated Windows smoke entry, proves native-default/material and
source/export lifecycle parity, exercises the explicit `soil_shader` rollback,
verifies the native DLL against its vendored release binary, proves the Voxel
module is present in both editor and exported template, and stages Terrain3D,
Sky3D, and Voxel Tools license/provenance files beside the package. The rollback
does not migrate authority data.

Rendered Jolt product soak is a conditional final gate, not an iterative
development loop. Run it only when the current release explicitly changes the
corresponding renderer/performance contract. First finish focused checks and
stabilize the implementation, then select the one applicable profile below and
run it once after the final relevant edit; do not run quick, release, and the
quality matrix cumulatively by default:

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

The bucket pass-through paired soak is retired. Its completed performance result
was accepted and remains in the archived task evidence; it is not a release,
regression, or archive command and must not be rerun automatically. The runner
may retain paired-comparison support for diagnostics, but using it again requires
a new explicit user-approved performance evaluation scope.

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
