# Evaluate and integrate Terrain3D terrain backend

## Goal

Determine whether the locally downloaded Terrain3D 1.0.2 addon is a suitable
Godot terrain backend for ExcavatorSim, explain its relationship to Jolt Physics,
and plan a safe Godot-first integration that improves terrain rendering and
optional collision without weakening the existing terrain/soil contracts.

The desired outcome is a realistic and maintainable 3D terrain presentation
that still has one logical terrain authority, deterministic fixed-step
excavation, exact bucket-volume accounting, and generation-safe reset/reconnect
behavior.

## Background and confirmed facts

- The local addon is at `godot/client/addons/terrain_3d/` and reports Terrain3D
  v1.0.2 in `plugin.cfg:3-7`; its GDExtension requires Godot 4.4+ and has local
  Windows x86_64 binaries (`terrain.gdextension:1-16`).
- The project targets Godot 4.7 Forward Plus with D3D12 and selects Jolt Physics
  (`godot/client/project.godot:15,33-40`). Terrain3D is not currently enabled.
- Current terrain authority and gameplay are implemented by `TerrainState`,
  `TerrainWorld`, `TerrainRenderer`, `TerrainCollider`, `BucketSoilState`, and
  `ExcavationWorld`; current standalone tests assert their contracts.
- The approved release boundary keeps Python authoritative for motion/input/
  lifecycle, Godot authoritative for the motion-only local terrain/world, and
  legacy Python terrain/recording/replay available as a compatibility profile.
- Official Terrain3D material, heightmap, region, and collision capabilities
  make it suitable for the mesh/heightmap/collision backend, but its native
  heightmap does not inherently replace the current stable/loose logical layers
  and bucket inventory semantics.

## Requirements

- R1 — Produce an evidence-backed Terrain3D suitability decision covering
  rendering, heightmap storage/import, runtime editing, collision, Windows
  Godot 4.7.1/D3D12 compatibility, Jolt interaction, addon licensing, and
  package size. Findings are persisted in `research/terrain3d-evaluation.md`.
- R2 — Preserve `TerrainState` as the logical Godot-first terrain authority,
  including stable/loose Float32 layers, monotonic command sequences, fixed-step
  application, `terrain_epoch`, `terrain_revision`, `world_generation`,
  row-major little-endian snapshot bytes/digest, and the three-metre cut floor.
- R3 — Preserve `BucketSoilState` as the sole bucket inventory/volume owner.
  Terrain3D runtime/editor mutations must not bypass accepted commands or create
  a second authority.
- R4 — Introduce a narrow Terrain3D adapter plan that consumes copied,
  generation/revision-gated snapshots for visual terrain and optionally maps
  accepted snapshots into Terrain3D collision generation. The adapter must be
  disposable/rebuildable and fail open when native loading, map updates, or
  collision generation fail.
- R5 — Keep Jolt as the Godot physics backend. Terrain3D may produce static
  collision shapes and height queries; Jolt may answer local raycasts/contacts,
  but neither may author excavator motion, terrain logical state, bucket volume,
  or Python state.
- R6 — Preserve existing scene/test seams until parity is proven. Do not remove
  `TerrainRenderer`, `TerrainCollider`, or the existing logical tests in the
  first migration step; use a feature flag or adapter fallback during rollout.
- R7 — Review whether the vendored addon should be reduced to the Windows
  runtime/editor files needed by this project. Exclude the unreferenced
  `~libterrain.windows.debug.x86_64.dll` and resolve third-party integration
  license/provenance before release packaging.
- R8 — Do not change Python protocol schemas or send Godot terrain, physics,
  bucket, or replay state back to Python.

## Acceptance Criteria

- [x] A written decision states whether Terrain3D is adopted for the current
      Godot terrain backend and lists accepted limitations.
- [x] A Godot 4.7.1 Forward+/D3D12 smoke proves the plugin loads, the main scene
      can instantiate the Terrain3D adapter, and the material path is visually
      acceptable or records a blocked fallback decision.
- [x] Adapter parity tests prove that the same accepted seed/command sequence
      produces the same logical `TerrainState` bytes/digest and bucket volume,
      independent of Terrain3D mesh/collision availability.
- [x] Runtime edit tests prove snapshot generation/revision guards reject stale
      Terrain3D work and preserve newer terrain state.
- [ ] Jolt collision tests prove the selected Terrain3D collision mode produces
      usable local queries when available and that disabling/failing it leaves
      motion and logical excavation usable.
- [ ] Existing standalone terrain, excavation, release-candidate, backend
      verify, and provenance gates remain green where applicable.
- [x] Addon packaging has an explicit decision for binaries, demo resources,
      the temporary-looking tilde DLL, third-party scripts, and MIT license
      notices.

## Key decisions

- **Adopt conditionally**: Terrain3D is recommended for presentation and
  optional collision, not as an unwrapped replacement for logical terrain/soil
  authority.
- **One-way data flow**: accepted `TerrainState` snapshot → Terrain3D adapter →
  optional Jolt collision queries. No reverse authority flow.
- **Staged rollout**: keep the current renderer/collider fallback until plugin
  loading, D3D12 material behavior, map update latency, collision behavior, and
  deterministic parity are measured.

## Out of scope

- Replacing Python motion authority or changing WebSocket/schema identifiers.
- Making Jolt or Terrain3D authoritative for terrain, bucket inventory, or
  excavator transforms.
- Reauthoring the SY205 GLB, adding dynamic articulated rigid-body simulation,
  hydraulic forces, or per-grain soil rigid bodies.
- Removing legacy Python terrain/recording/replay in this task.

## Planning status

- Complex task: `prd.md`, `design.md`, `implement.md`, and research artifact
  required before activation.
- Blocking open questions: none for the proposed staged integration; any
  unresolved D3D12/material or package licensing result is a recorded rollout
  gate, not permission to bypass the authority contract.
