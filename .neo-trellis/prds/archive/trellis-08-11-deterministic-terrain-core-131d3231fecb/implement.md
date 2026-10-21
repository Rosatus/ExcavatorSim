# Implementation Plan

1. [x] Add `TerrainState` with seeded baseline, stable/loose Float32 layers,
   deterministic brush queue, revision/generation/reset and snapshot digest.
2. [x] Add `TerrainRenderer` and `TerrainWorld` scene integration under
   `TerrainRoot`; keep the foundation ground as a fail-open fallback.
3. [x] Add focused Godot headless tests for repeatability, validation/order,
   layer conservation, reset/generation and stale mesh rejection.
4. [x] Run Godot headless import/test checks, inspect the scene/resource diff,
   and run `pixi run verify` to prove backend/protocol compatibility.
5. [x] Update the frontend client-boundary spec with the Godot-first local-world
   profile and archive the completed child task.

## Exit gate

The same seed and ordered edits reproduce identical terrain bytes/digest and
layer values; invalid/stale input is mutation-free; reset advances generation
and stale mesh work cannot win; the main scene renders the derived mesh with a
fallback; focused Godot checks and the backend verification gate pass. [x]
