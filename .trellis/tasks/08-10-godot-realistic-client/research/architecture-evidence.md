# Architecture Evidence

## Current project state

- `godot/client/` is a Godot 4.7.1 Forward+ project with MCP plugin `3.1.3`, Windows D3D12, and Jolt configured in `godot/client/project.godot:9-40`.
- No product `.tscn`, `.gd`, `.glb`, `.tres`, `.res`, or shader files exist in `godot/client/` yet; the existing scripts are Godot MCP plugin files.
- The MCP editor session is connected and reports project `ExcavatorSim`, current scene empty, and readiness `no_scene`; this is a healthy connection with no scene open.

## Motion contract

- `Simulator` implements fixed-step four-joint motion, limits, acceleration and emergency-stop behavior in `backend/src/babylon_sim/simulation.py:23-153`.
- `RuntimeController` publishes snapshots, accepts sequenced input, and exposes lifecycle commands in `backend/src/babylon_sim/runtime.py:115-240`.
- Active joints are `swing_joint`, `boom_joint`, `arm_joint`, and `bucket_joint` in `backend/src/babylon_sim/constants.py:5-18`.
- `view_state` serializes named frame transforms and state identity in `backend/src/babylon_sim/web.py:96-125`; the protocol schema defines the corresponding fields in `protocol/babylon-sim-v3.schema.json:319-381`.

## Visual contract

- The future client loads five visual parts and applies authoritative named-frame transforms from Python in `docs/godot-integration.md:3-6`.
- The manifest maps `base_link`, `upper_structure_link`, `boom_link`, `arm_link`, and `bucket_link` to GLBs with local transform calibration in `assets/visual/original/visual-model-v1.json:7-75`.
- The frame-parity baseline defines `T_world_visual = T_world_link * T_link_visual` in `backend/tests/fixtures/frame-parity/baseline.json:9`.

## Terrain and lifecycle contract

- The current runtime also constructs `TerrainController`, recording, and replay workers in `backend/src/babylon_sim/runtime.py:115-155`; a staged motion-only boundary is required before those subsystems can be retired.
- The documented client boundary allows Godot-derived terrain mesh, particles, and local colliders, while Python remains authoritative only where the product chooses to keep it in `docs/godot-integration.md:17-25` and `.trellis/spec/frontend/client-boundary.md:3-7`.
- The project quality rules forbid a second untyped terrain store, one rigid body per soil grain, authority inversion, and wall-clock simulation authority in `.trellis/spec/backend/quality-guidelines.md:7-20`.

## Planning inference

The lowest-risk architecture is a one-way motion service plus a Godot-owned world: Python sends deterministic joint/frame state; Godot sends sequenced controls and owns seeded terrain, bucket interaction, volume accounting, rendering, UI, and disposable effects. Keep the old terrain/replay backend paths behind an optional compatibility boundary until the Godot world is validated.
