# M4 research: terrain contracts and compatibility

## Existing backend contract

- `docs/terrain-api.md` defines the legacy Python terrain algorithm and its
  Float32 stable/loose layers, surface bytes, terrain epoch/revision, patches,
  reset semantics and 50,000-cell bound.
- `protocol/babylon-sim-v3.schema.json` requires terrain view/patch metadata,
  but M4 intentionally does not implement the Python HTTP/WS synchronization;
  the local state uses compatible names and identity semantics for M5/M7.
- Backend tests in `test_terrain_excavation.py` prove exact repeatability,
  stable+loose surface equality, checkpoint bytes and reset behavior. These are
  reference invariants, not code to copy into Godot.

## Godot implementation boundary

- `godot/client/scenes/main.tscn` already has `TerrainRoot` and a visible
  `FoundationGround`; M4 adds a derived mesh child while keeping the fallback.
- `.trellis/spec/frontend/client-boundary.md` and
  `docs/godot-integration.md` require stale/generation-safe derived terrain and
  fail-open local physics. M4 implements mesh generation only; colliders and
  bucket interaction remain M5.
- No Godot terrain script or terrain test currently exists, so the first local
  seam should be pure `TerrainState` plus a renderer queue that can be tested
  without a running backend or MCP session.
