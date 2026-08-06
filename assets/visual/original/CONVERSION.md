# Original Excavator GLB Conversion Record

## Toolchain

- Converter: `trimesh` 4.11.2 from conda-forge in a Pixi temporary environment.
- Script: `backend/scripts/convert_original_visual.py`.
- Command, run from the ExcavatorSim repository root:

```powershell
pixi exec --spec trimesh=4.11.2 python backend/scripts/convert_original_visual.py `
  --source <approved-original-snapshot> `
  --output assets/visual/original
```

The adjacent checkout is conversion input only. Runtime, frontend build, installation, tests, and
production do not access it and do not require `trimesh`.

## Settings And Results

`trimesh.load_scene(..., process=True)` loads each OBJ/MTL pair. Export uses GLB 2.0 with generated
normals and retains material partitions. No decimation, texture baking, geometry edits, or link
merging are applied. The source dimensions are treated as meters because the supplied URDF and
machine-scale bounds support that interpretation; the source files do not explicitly declare units.

| Source | Output | Bytes | Meshes | Materials | Output SHA-256 |
| --- | --- | ---: | ---: | ---: | --- |
| `base.obj` | `base.glb` | 401952 | 2 | 2 | `0bc9bbf9547dcaa1cf4e65968cd9723cd459cdfaea1df187cef0acf3f777057a` |
| `body.obj` | `upper-structure.glb` | 515412 | 4 | 4 | `1040412f87367ac3fd603ef91c1dc2b0e4599902b06c8c133bdfdaec8809bac8` |
| `arm1.obj` | `boom.glb` | 59048 | 1 | 1 | `3c76e3f832dab11bc21748341ad55369cc45fa4cc8e764ce48e2c2f55baa46c2` |
| `arm2.obj` | `arm.glb` | 105944 | 1 | 1 | `01d2f2fb9dbdd31eec5e121814daf1f1b729486640354533fc1ef934187bb6e4` |
| `shovel.obj` | `bucket.glb` | 85024 | 1 | 1 | `84561b463c2747dcc927fdd6898ffbd4c2beb76e6ac8882dfc1de90625784974` |

Two consecutive conversions produced identical byte counts and SHA-256 values. Local visual
translation, RPY, and scale are not baked into the GLBs; they remain reviewable in
`visual-model-v1.json` so calibration can change without regenerating geometry.
