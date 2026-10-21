# Deterministic Godot terrain core

## Goal

Create the first Godot-owned terrain/world state used by the realistic client.
It must be repeatable on the supported Windows/Godot runtime for an explicit
seed and ordered edit sequence, while remaining presentation/gameplay state
that never writes terrain heights or bucket authority back to Python.

## Requirements

- Add a versioned `TerrainState` with an explicit unsigned seed, bounded stable
  grid dimensions/spacing, deterministic baseline generation, and a public
  derived surface (`stable + loose`).
- Keep stable substrate and non-negative loose depth as separate Float32 arrays;
  render mesh data is derived and must not be used as the state store.
- Accept only monotonically increasing local edit sequence numbers. Apply queued
  brush edits in sequence order during an explicit fixed-step call; duplicate,
  stale, invalid, or non-finite commands must not mutate state.
- Keep revisions monotonic and deterministic. A changed edit increments
  `terrain_revision`; a no-op does not. Terrain reset restores the baseline,
  increments revision, and advances a local world generation so stale derived
  work can be discarded.
- Produce row-major Float32 snapshot bytes and a stable digest/metadata fixture
  for the same seed and command sequence. Keep grid size below 50,000 cells.
- Add a generation-gated `TerrainRenderer` that builds an `ArrayMesh` from a
  copied surface snapshot. Older generations/revisions and stale queued rebuilds
  must never replace a newer mesh.
- Put a reproducible terrain node under `TerrainRoot` in `main.tscn`, without
  removing the existing foundation ground or changing the Python motion path.
- Add headless Godot tests for seed repeatability, command ordering/no-op
  behavior, stable+loose conservation, reset/generation cleanup, snapshot bytes,
  and stale renderer rejection.

## Acceptance Criteria

- [x] Two fresh states with the same seed/config and identical ordered edits
  have identical surface bytes, digest, revision, and layer values.
- [x] Invalid or stale edits leave all authoritative local arrays, revision and
  pending sequence unchanged.
- [x] Reset produces the original baseline bytes, increments revision, clears
  loose depth, and advances generation; an older queued render cannot win.
- [x] The terrain node builds a visible derived mesh in the main scene and the
  mesh can be rebuilt from a snapshot without changing `TerrainState`.
- [x] The client remains usable if mesh generation is skipped or fails; no
  Python request is issued by the M4 terrain core.
- [x] Focused Godot tests and headless import pass, and `pixi run verify` remains
  green because no backend/protocol code changes are required.

## Constraints

- This is the Godot-first local world profile approved by the parent PRD. The
  legacy Python terrain API remains available for compatibility and is not
  mirrored into a second Godot authority in this milestone.
- Do not implement bucket interaction, particles, colliders, replay, or full
  terrain HTTP/WS synchronization here; those belong to M5/M7.
- Do not use wall-clock time, renderer cadence, nondeterministic hashing, or
  editor/MCP state in the terrain algorithm.
