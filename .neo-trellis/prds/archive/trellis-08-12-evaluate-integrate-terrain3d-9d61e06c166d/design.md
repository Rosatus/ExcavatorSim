# Terrain3D integration design

## Architecture and boundaries

The integration uses Terrain3D as a replaceable Godot backend behind a project
adapter. The semantic owner remains the existing `TerrainState`:

```text
fixed-step command input
  -> TerrainState stable/loose layers
  -> immutable snapshot (epoch, revision, generation, Float32 bytes/digest)
  -> Terrain3DAdapter
       -> Terrain3D mesh/heightmap regions
       -> optional Terrain3D collision generation
            -> Jolt local raycasts/contacts
```

`BucketSoilState` continues to consume `TerrainState` APIs and remains the only
bucket inventory owner. `ExcavationWorld` continues to own command sequencing,
generation reset, and presentation update orchestration.

The adapter must never call Terrain3D editor sculpting as a gameplay mutation
path. Terrain3D's `set_height`/`import_images`/`update_maps` APIs are used only
to materialize an already accepted snapshot. If the plugin cannot load, map
conversion fails, or collision construction fails, the current custom mesh /
collider fallback remains usable.

## Data mapping

- Map `TerrainState.origin_xz`, `rows`, `columns`, `spacing_m`, and row-major
  `surface` into a Terrain3D region with explicit X/Z orientation and height
  scale. The adapter must document whether it uses `Terrain3DData.import_images`
  for full snapshots or a bounded `set_height`/region-image update for edits.
- Do not use Terrain3D's internal map digest as the logical snapshot digest.
  `TerrainState.surface_bytes` and `snapshot_sha256` remain the parity oracle.
- Every queued adapter job captures `(terrain_epoch, terrain_revision,
  world_generation)`. Apply only if the identity is newer than the committed
  adapter state and still matches the current `TerrainState` snapshot.
- Runtime edits update logical state first, then enqueue one derived Terrain3D
  update. A Terrain3D update may be dropped/rebuilt without changing logical
  terrain or bucket volume.

## Collision and Jolt

Terrain3D collision mode is configured as an optional capability, initially
`Dynamic / Game` or disabled while the spike measures generation cost. Terrain3D
creates the static collision shapes; Jolt is the project-selected Godot 3D
physics server that answers local raycasts/contact queries against those shapes.
They are complementary.

The existing fail-open `TerrainCollider` contract remains the fallback and test
seam until Terrain3D collision parity is proven. A generation change disposes
or retires old collision resources before the new snapshot is installed. Local
physics diagnostics may affect contact presentation only; they cannot stop
logical excavation or alter Python motion authority.

## Compatibility and rollout

1. Add the plugin enablement and adapter behind a project/runtime feature flag.
2. Run a static Terrain3D scene with the current baseline snapshot and compare
   camera framing, material response, normals, and back-face winding.
3. Add deterministic snapshot-to-Terrain3D mapping tests and preserve current
   `terrain_state_test.gd` / `excavation_gameplay_test.gd` tests unchanged.
4. Add runtime cut/deposit updates and measure map rebuild latency at the current
   grid and a representative larger region.
5. Enable Jolt-backed Terrain3D collision only after dynamic-collision and
   fail-open tests pass. Keep the custom fallback until release evidence is
   recorded.
6. Decide package minimization and provenance before staging native binaries.

Rollback is a feature-flag flip back to `TerrainRenderer` and
`TerrainCollider`; no logical state or protocol migration is needed.

## Trade-offs

- Benefits: clipmap LOD, region-based storage, editor tooling, heightmap import,
  optional collision generation, and less custom mesh code.
- Costs: native GDExtension lifecycle, roughly 55 MiB vendored package, D3D12
  TextureArray/mipmap caveat, platform binary packaging, and a required adapter
  to preserve stable/loose deterministic gameplay semantics.
- The current 41x41 terrain is small enough that Terrain3D's performance win is
  not guaranteed; the first spike must measure visual quality and edit latency,
  not assume a speedup.
