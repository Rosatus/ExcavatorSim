# Terrain3D Forward+ render compatibility spike

## Goal

Reproduce, diagnose, and resolve the Terrain3D 1.0.2 black-surface regression
on the project's Godot 4.7 Forward+/D3D12 Windows target before any product
default or terrain authority change.

## Dependency

This is Phase 0 and has no child dependency. Parent task:
`08-29-restore-terrain3d-visual-parity`.

## Requirements

- Build a minimal project-owned render probe using the existing addon, adapter,
  copied `TerrainState` snapshot, camera, and target renderer.
- Capture structured evidence for Terrain3D class availability, material/shader
  identity, rendering driver/device, shader diagnostics, map import, native
  visibility, and applied generation/revision.
- Produce a real rendered-frame non-black assertion. Headless object state alone
  is insufficient.
- Isolate whether the black output comes from addon/Godot ABI compatibility,
  material resource initialization, shader compilation, texture arrays, render
  driver, map/control encoding, camera/clipmap target, or adapter ordering.
- Prefer an adapter/material/configuration fix. Do not patch vendored Terrain3D
  C++ or replace its binaries without a new explicit compatibility decision.
- Keep `terrain_backend="soil_shader"` as product default throughout this phase.
- Do not change TerrainState, soil authority, collider, Jolt, excavation,
  product dressing, or persisted data.

## Acceptance Criteria

- [x] A deterministic probe reproduces the original black-surface condition or
  records why the current environment no longer reproduces it.
- [x] The corrected native path renders a finite, non-black, height-varying
  Terrain3D surface in Godot 4.7 Forward+/D3D12 on Windows.
- [x] Logs contain no shader compile, GDExtension, material, texture-array, or
  map-import error for the successful run.
- [x] A deliberate native/material failure reports a bounded reason and leaves
  the current fallback visible.
- [x] TerrainState bytes/revision and collider/soil state are unchanged before
  and after the probe.
- [x] Evidence states whether Terrain3D 1.0.2 remains supportable; any required
  addon upgrade is deferred to a revised parent plan rather than hidden here.

## Out of Scope

- Final product soil appearance, product default cutover, native collision,
  vegetation, full excavation regression, or export release sign-off.
