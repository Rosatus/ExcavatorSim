# Terrain3D evaluation for ExcavatorSim

## Recommendation

Adopt the local Terrain3D 1.0.2 addon as the Godot terrain presentation and
optional collision backend, but do not make its editor or direct mutation API a
second gameplay authority. Keep `TerrainState` as the logical Godot-first
terrain owner and feed Terrain3D generation-gated snapshots through a narrow
adapter. Keep `BucketSoilState` as the bucket inventory and volume-accounting
owner.

This is a good fit for the visual problem, while a direct replacement of the
current `TerrainState` would lose the stable/loose layers, fixed-step command
ordering, snapshot digest, and bucket-volume semantics that the current tests
protect.

## Evidence from the official asset and documentation

- The [Godot Asset Store entry](https://store.godotengine.org/asset/tokisangames/terrain3d/)
  identifies Terrain3D v1.0.2 as a MIT-licensed C++ GDExtension for Godot 4.4+.
  It advertises GPU-driven clipmap terrain, 64x64 m to 65.5x65.5 km regions,
  up to 10 LOD levels, heightmap import, sculpting, holes, texture painting,
  and GDScript/C# access. The local project is Godot 4.7 Forward+.
- The [Terrain3D 1.0.2 documentation](https://terrain3d.readthedocs.io/en/stable/index.html)
  exposes `Terrain3D`, `Terrain3DData`, `Terrain3DCollision`, region storage,
  height/color/control maps, and heightmap import/export.
- The [collision documentation](https://terrain3d.readthedocs.io/en/stable/docs/collision.html)
  says Terrain3D generates StaticBody/CollisionShapes for configured regions and
  offers Dynamic/Game, Full/Game, Editor, and Disabled modes. It also documents
  direct height/intersection queries that do not require physics.
- The [Terrain3DData API](https://terrain3d.readthedocs.io/en/stable/api/class_terrain3ddata.html)
  provides `import_images`, `set_height`, `update_maps`, `get_height`, and
  `get_normal`. Bulk image import/update is the likely snapshot path; the exact
  region/coordinate mapping must be validated in a Godot spike before relying
  on it for runtime edits.
- The official platform page documents Windows support and Forward+ D3D12
  caveats: TextureArray mipmaps are not fully supported on D3D12 in the 1.0.2
  documentation. This is a release-risk for the current project, which targets
  Windows Forward+ D3D12, and requires a visual/material smoke gate.

## Local addon audit

- `godot/client/addons/terrain_3d/plugin.cfg:3-7` reports Terrain3D 1.0.2.
- `godot/client/addons/terrain_3d/terrain.gdextension:1-16` requires Godot 4.4+
  and references the Windows x86_64 debug/release DLLs that are present locally.
- `godot/client/project.godot:15,33-45` targets Godot 4.7 Forward Plus, enables
  `godot_ai` and the Terrain3D editor plugin, and selects Jolt Physics. Runtime
  use is controlled by `terrain3d/runtime_enabled`; native collision remains
  disabled by default until the Jolt smoke is measured.
- The addon is roughly 55 MiB including native binaries, EXR brushes, scripts,
  and multi-platform builds. `bin/~libterrain.windows.debug.x86_64.dll` is an
  unreferenced temporary-looking file and should not be blindly packaged.
- The primary addon is MIT-licensed (`addons/terrain_3d/LICENSE.txt:1-20`),
  but `extras/3rd_party/` contains integration scripts that need a separate
  license/provenance check before release packaging.

## Compatibility with current terrain contracts

The current logical contracts are in:

- `godot/client/scripts/terrain_state.gd:4-24,41-95,121-209` — stable Float32
  heights plus loose Float32 depth, monotonic sequence, fixed-step brush
  application, terrain revision/generation, and row-major little-endian digest
  snapshots.
- `godot/client/scripts/terrain_world.gd:9-46` — owns the logical state and
  hands snapshots to derived rendering.
- `godot/client/scripts/terrain_renderer.gd:4-5,17-103` — copied,
  generation/revision-gated mesh derivation.
- `godot/client/scripts/terrain_collider.gd:4-7,18-123` — optional,
  generation/revision-gated, fail-open collision derivation.
- `godot/client/scripts/bucket_soil_state.gd:6-24,56-160` — bucket capacity,
  cut/deposit semantics, volume accounting, and generation reset.

Terrain3D can satisfy the rendering and collision portions, but its heightmap
is not equivalent to the two-layer stable/loose logical state. Runtime writes
must therefore be adapter-owned and derived from accepted `TerrainState`
commands. Terrain3D editor sculpting must not be used on the runtime authority
path unless a later migration explicitly replaces the logical contract and its
tests.

## Jolt relationship

Terrain3D is the terrain data/rendering/collision-shape producer. Jolt is the
Godot 3D physics backend selected in `project.godot`. Terrain3D can generate
static collision shapes; Jolt then services raycasts, contacts, and body
queries against those shapes. They are complementary, not competing terrain
systems.

The current authority boundary remains:

```text
TerrainState / BucketSoilState
  -> accepted snapshot (generation, revision)
  -> Terrain3D visual data and optional collision shapes
  -> Jolt raycasts/contacts (presentation aid only)
```

Neither Terrain3D nor Jolt may write terrain heights, bucket inventory, or
authoritative excavator transforms back to Python. A missing or failed
Terrain3D/Jolt collision path must remain fail-open for motion and local terrain
state.

## Risks and required spikes

1. Validate Terrain3D 1.0.2 loading under Godot 4.7.1 Forward+/D3D12 and record
   whether material/TextureArray mipmaps are acceptable.
2. Validate the row/column/origin/height-scale mapping from the existing
   `TerrainState.surface_snapshot()` into a Terrain3D region without changing
   the digest contract.
3. Validate runtime height updates and map rebuild cost for cut/deposit edits.
4. Validate Terrain3D collision mode with Jolt and prove that disabling or
   failing collision leaves excavation and motion usable.
5. Decide whether the full addon/demo/native binary package belongs in source
   control or must be reduced to Windows runtime files plus license/provenance.

## First implementation slice

`Terrain3DAdapter` now lives at `godot/client/scripts/terrain3d_adapter.gd` and
is mounted in `scenes/main.tscn` beside the custom renderer and collider. It
copies and generation/epoch/revision-gates snapshots, attempts
`Terrain3DData.import_images`, and hides the custom mesh only after a successful
native materialization. The custom renderer remains visible on native load,
map-import, or collision configuration failure. The adapter test is included in
`tests/run_standalone_matrix.ps1`; the Godot-specific smoke is still pending
because this workspace does not currently expose a `godot.exe` executable.
