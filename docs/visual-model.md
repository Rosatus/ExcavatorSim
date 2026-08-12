# Visual Model Contract

The Godot/Pinocchio service's authoritative motion model remains
`assets/model/kinematic_excavator.urdf`. The `original-skin-v1` visual model is
a separate five-link appearance layer driven by the same backend-authored world
frame matrices.

## Runtime Assets

`assets/visual/original/visual-model-v1.json` maps exactly these assets:

| Asset id | Authoritative frame | GLB |
| --- | --- | --- |
| `base` | `base_link` | `base.glb` |
| `upper-structure` | `upper_structure_link` | `upper-structure.glb` |
| `boom` | `boom_link` | `boom.glb` |
| `arm` | `arm_link` | `arm.glb` |
| `bucket` | `bucket_link` | `bucket.glb` |

Each entry owns a raw SHA-256, local XYZ/RPY/scale calibration, expected raw
mesh bounds, and primitive replacement policy. The service validates the
strict JSON Schema, exact frame set, uniqueness, safe filenames, finite and
positive transforms, bounds, GLB 2.0 structure, mesh/material presence,
POSITION accessor bounds, and digest before the runtime starts.

## HTTP Boundary

- `GET /api/visual-model` returns the public manifest with same-origin opaque
  asset URLs.
- `GET /api/visual-assets/{asset_id}` serves only a validated manifest entry as
  `model/gltf-binary` with immutable caching and `nosniff`.

The request never supplies a filesystem path. Unknown, nested, traversal-shaped,
missing, corrupt, or mismatched assets fail instead of falling through to the
SPA or producing a partial visual model.

The frontend validates the public manifest, fetches all five assets, verifies
their SHA-256 values with Web Crypto, and stages the Godot visual scene.
Only after all five loads succeed does `VisualModelController` attach them to
the existing pose nodes and disable the corresponding primitive visuals. A
failure disposes staged resources and is surfaced as a model readiness error.

## Conversion And Rights Evidence

- `SOURCE-RIGHTS.md` records the authorization supplied by the project user and
  the limits of the available upstream metadata.
- `source-sha256.json` identifies the supplied URDF/OBJ/MTL snapshot by raw
  hashes.
- `CONVERSION.md` pins `trimesh` 4.11.2, the command/settings, output inventory,
  and reproducibility result.
- `visual-provenance.json` links each source OBJ to its committed GLB.

The GLBs are committed runtime assets. The adjacent source checkout and
conversion environment are never accessed by production or a clean build.

## Development Rollback

Open the application with `?visual=primitives` to render the unchanged
schematic URDF visuals. Production does not silently use that fallback after a
GLB error. Removing the manifest/assets/routes/loader integration restores the
previous renderer without changing motion, the Godot/Pinocchio protocol v3, authoritative terrain, recording, or RRD v1.
