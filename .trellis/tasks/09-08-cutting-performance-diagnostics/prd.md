# Cutting performance and optional diagnostics

## Goal
Reduce avoidable CPU work during the current SY135 voxel cutting loop while preserving cut geometry, mass accounting, input cadence and collision correctness.

## Background and authorization
The user accepted the proposed first optimization pass (visual/diagnostic snapshot separation and native coverage sampling optimization) and requested a diagnostic switch on 2026-09-08. This follows the previous code-based proposal; implementation is authorized in that reply.

## Requirements
- R1: Visual and audio consumers obtain the same gameplay fields without constructing full voxel diagnostics.
- R2: Advanced exposes a runtime cutting-performance diagnostic switch, default off. Disabling stops optional timing/allocation sampling and full diagnostic aggregation; enabling begins a fresh measurement window. It must not reset terrain, inventory, queues or collision readiness.
- R3: Native coverage uses the identical stencil, probe/cell caps, accepted coordinates and legacy lexical coordinate order, with less string allocation and a bounded tight SDF read buffer.
- R4: Preserve transaction identity/mass/error evidence, gameplay gates, collision acknowledgements and deterministic results regardless of the diagnostic switch. Optional native SDF digest fields are empty while diagnostics are off; exact-path validation remains active.

## Acceptance
- Agent automated: focused snapshot/diagnostic toggling tests, legacy-versus-optimized coverage equality including cap boundaries and negative/multi-digit coordinates, real native cut equivalence and representative timing evidence, world/UI wiring and reset persistence.
- Human manual: in SY135, enable Advanced, toggle cutting diagnostics, cut/dump and verify perceived smoothness and unchanged soil presentation. No subjective pass is claimed by headless checks.

## Out of scope
Changing voxel resolution, sweep density, mass calibration, commit cadence, collision range, native threading, transport or unrelated dirty files.
