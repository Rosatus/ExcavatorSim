# Excavator GLB Export Guide

## Purpose

This guide describes how to produce a BabylonSim-ready excavator GLB from either:

1. the original SOLIDWORKS assembly, which is the preferred source; or
2. the currently supplied `E:/projects/135URDF.SLDASM` ROS export, which contains only URDF and STL
   files and is suitable only for a provisional visual reconstruction.

The target is a rigid, articulated visual model with accurate link origins and named work frames.
Mass, inertia, collision geometry, hydraulic behavior, and dynamic response are not required by this
guide.

Do not replace committed BabylonSim visual assets with a newly exported model until its scale,
kinematic pivots, node mapping, source rights, and known-pose checks have passed.

## Important Current-State Limitations

`E:/projects/135URDF.SLDASM` is a directory, not a native `.SLDASM` file. It contains:

- `urdf/135URDF.SLDASM.urdf`;
- five binary STL meshes under `meshes/`;
- ROS launch/configuration files; and
- an SW2URDF export log.

It does **not** contain the source `URDF1.SLDASM`, source STEP parts, FBX, glTF, or GLB files.

The current export cannot be treated as verified kinematic truth:

- the `j1` axis is `0 0 0`;
- all four joints are unlimited `continuous` joints;
- the export log records failures while automatically creating all four joints; and
- tooth, bucket-fill, and bucket-outlet frames are absent.

The STL package can still produce a useful provisional GLB, but the joint pivots and work frames
must be corrected or confirmed against the original CAD assembly before acceptance.

## Required Output

The preferred handoff contains:

```text
excavator-source.blend
excavator.glb
node-map.csv
known-poses/
  neutral.png
  pose-a.png
  pose-b.png
SHA256SUMS.txt
SOURCE-RIGHTS.md
```

For immediate compatibility with BabylonSim's current visual loader, also export these five rigid
link files when requested:

```text
base.glb
upper-structure.glb
boom.glb
arm.glb
bucket.glb
```

The current runtime maps five separate GLBs to five backend-authored frames. A unified
`excavator.glb` is an intake artifact until the runtime model contract is deliberately migrated.

## Required Node Structure

Use ordinary transform nodes for a rigid excavator. Do not use deforming skin weights unless a
separate non-rigid component genuinely requires them.

```text
base_link
└── swing_joint
    └── upper_structure_link
        └── boom_joint
            └── boom_link
                └── arm_joint
                    └── arm_link
                        └── bucket_joint
                            └── bucket_link
                                ├── tooth_left
                                ├── tooth_center
                                ├── tooth_right
                                ├── bucket_fill_reference
                                └── bucket_outlet
```

Rules:

- Every name is unique, stable, lowercase, and case-sensitive.
- Each `*_joint` node is an empty transform located at the true CAD rotation center.
- Each joint node has exactly one moving child link.
- Each link mesh is rigidly attached below its corresponding `*_link` node.
- Every ancestor scale is exactly `[1, 1, 1]` after preparation.
- Do not use negative, mirrored, or non-uniform ancestor scale.
- The neutral exported pose is the agreed mechanical zero pose.
- Work-frame nodes are empty transforms, not visible geometry.

The sensor nodes currently used by BabylonSim may be added later if they remain part of the approved
model contract. They are not necessary merely to produce the visual GLB.

## Coordinate And Scale Contract

glTF 2.0 uses a right-handed coordinate system, metres for linear distance, radians for angles, and
`+Y` as up. BabylonSim currently uses a right-handed, `+Z`-up world. Keep the GLB in standard glTF
coordinates and perform one documented root conversion during BabylonSim integration. Do not rotate
individual links independently to compensate for the up-axis difference.

Before any export, decide whether the source represents:

- a full-size excavator; or
- a physical scale model such as `1:35`.

The currently supplied STL extents are approximately:

| Mesh | Approximate extent in source units interpreted as metres |
| --- | --- |
| `base_link.STL` | `0.024856 × 0.008835 × 0.036417` |
| `link1.STL` | `0.033717 × 0.025864 × 0.019198` |
| `link2.STL` | `0.003160 × 0.048054 × 0.013204` |
| `link3.STL` | `0.002269 × 0.030652 × 0.006132` |
| `link4.STL` | `0.010137 × 0.014692 × 0.008950` |

These dimensions look like a small physical model rather than the existing full-size BabylonSim
machine. Do not silently multiply by `35` or any other guessed factor. Record one approved scale at
the model root, apply it once, and recheck all link pivots and work-frame coordinates.

## Route A: Export From The Original SOLIDWORKS Assembly

This is the preferred route because the native assembly retains mates, part identities, reference
geometry, and actual rotation centres.

### A1. Prepare the assembly

1. Open the original source assembly, identified by the previous export log as `URDF1.SLDASM`.
2. Save a versioned copy before changing suppression states or reference geometry.
3. Resolve all components; do not export lightweight, missing, or suppressed moving components by
   accident.
4. Group components into exactly five rigid visual groups:
   - base;
   - upper structure/cabin;
   - boom;
   - arm/stick; and
   - bucket.
5. Remove or suppress geometry that is irrelevant at runtime, such as hidden manufacturing detail,
   duplicate fasteners, construction sketches, and tiny hardware that has no visible value.
6. Keep the mechanical rotation centre of every active joint available as a reference coordinate
   system or reference point.
7. Put the assembly into the agreed neutral pose.
8. Record the source document unit, intended real-world scale, SOLIDWORKS version, configuration,
   display state, and included/suppressed component list.

### A2. Export a raw GLB

Recent SOLIDWORKS versions support direct glTF/GLB export through Extended Reality:

1. Select **File > Save As**.
2. Select **Extended Reality Binary (`*.glb`)**.
3. Open **Options** and select the GLTF/GLB export settings.
4. Do not export cameras, lights, exploded views, or motion studies for the first kinematic asset.
5. Disable Draco compression for the first diagnostic export. Compression may be enabled later only
   after Babylon and validator checks pass.
6. Export appearances and textures that are needed by the runtime model.
7. Save as `excavator-solidworks-raw.glb`.

Official SOLIDWORKS procedure:
https://help.solidworks.com/2026/chinese-simplified/SolidWorks/sldworks/t_export_using_extended_reality.htm

Treat the direct SOLIDWORKS GLB as a geometry and appearance transfer. Do not assume that CAD mates
became BabylonSim revolute-joint metadata.

### A3. Normalize in Blender

1. Start a clean Blender file.
2. Set the scene unit system to **Metric** and unit scale to `1.0`.
3. Import `excavator-solidworks-raw.glb` with **File > Import > glTF 2.0**.
4. Confirm that the imported overall dimensions match the intended real machine or scale model.
5. Remove imported cameras, lights, animation tracks, and redundant wrapper nodes.
6. Split or join objects so that every visible object belongs to one of the five rigid link groups.
7. Create the empty joint and link nodes shown in **Required Node Structure**.
8. Place each joint empty at the corresponding CAD rotation centre.
9. Parent each link while preserving its world transform.
10. Apply mesh-object scale and rotation only after the hierarchy and neutral pose have been checked.
11. Ensure every joint/link ancestor reports scale `[1, 1, 1]`.
12. Add the required tooth, bucket-fill, and outlet empty nodes using CAD measurements.

## Route B: Reconstruct From The Current URDF And STL Package

Use this route only when the native assembly is unavailable. Its output is provisional until CAD
reference checks repair the known export defects.

### B1. Create the Blender scene

1. Start a clean Blender file.
2. Set **Scene Properties > Units** to:
   - Unit System: `Metric`;
   - Unit Scale: `1.0`; and
   - Length: `Meters`.
3. Import all five files from `E:/projects/135URDF.SLDASM/meshes`.
4. Do not apply an import scale until the intended physical scale is approved.
5. Rename the imported mesh objects:

| Source mesh | Provisional semantic name |
| --- | --- |
| `base_link.STL` | `base_visual` |
| `link1.STL` | `upper_structure_visual` |
| `link2.STL` | `boom_visual` |
| `link3.STL` | `arm_visual` |
| `link4.STL` | `bucket_visual` |

### B2. Rebuild the hierarchy

Create the empty joint/link structure from this provisional source chain:

```text
base_link --j1--> link1 --j2--> link2 --j3--> link3 --j4--> link4
```

Use the URDF joint origins only to obtain a first visual assembly:

| Joint | Parent -> child | Provisional origin XYZ (m) | Provisional RPY (rad) | Exported axis |
| --- | --- | --- | --- | --- |
| `j1` | `base_link -> link1` | `0, -0.0019295, 0` | `1.5708, -1.5708, 0` | `0, 0, 0` — invalid |
| `j2` | `link1 -> link2` | `0.000433, -0.000074648, 0.012206` | `-0.89033, 0, 1.5942` | `-1, 0, 0` |
| `j3` | `link2 -> link3` | `-0.00067063, -0.046082, 0` | `1.2431, 0, 0` | `1, 0, 0` |
| `j4` | `link3 -> link4` | `0, -0.024986, 0` | `0.42714, 0, 0` | `-1, 0, 0` |

The `j1` axis must be supplied from CAD before kinematic acceptance. All four origin/axis definitions
must be checked because the SW2URDF log reports automatic joint-creation failures.

Rename the final semantic nodes to `swing_joint`, `boom_joint`, `arm_joint`, and `bucket_joint` only
after the source-to-semantic mapping has been approved.

### B3. Add missing work frames

Create empty transforms under `bucket_link` for:

- `tooth_left`;
- `tooth_center`;
- `tooth_right`;
- `bucket_fill_reference`; and
- `bucket_outlet`.

These positions cannot be derived reliably from the URDF because they are absent. Obtain them from
the CAD operator or measure them against an agreed bucket reference drawing. Do not use mesh bounds
as the final values.

## Blender Export Settings

Keep one `.blend` source file containing the clean hierarchy and export only the approved model
collection.

1. Select the approved excavator collection.
2. Select **File > Export > glTF 2.0**.
3. Set **Format** to **glTF Binary (`.glb`)**.
4. Enable **Selected Objects** or **Active Collection** so helper objects are not exported.
5. Keep **Y Up** enabled to produce standard glTF coordinates.
6. Enable normals, UVs, and materials.
7. Enable **Apply Modifiers** only after checking that modifiers do not move joint references.
8. Disable animations for the first asset.
9. Disable cameras and punctual lights.
10. Disable Draco compression for the first validated baseline.
11. Enable **Custom Properties** only if approved BabylonSim metadata has deliberately been added to
    Blender objects.
12. Export as `excavator.glb`.

Blender's exporter writes custom properties to glTF `extras` when **Custom Properties** is selected.
Official Blender glTF documentation:
https://docs.blender.org/manual/en/3.6/addons/import_export/scene_gltf2.html

## Optional Current-Runtime Five-Link Export

BabylonSim currently expects one independently attachable GLB per authoritative link. To produce
these assets from the normalized Blender scene:

1. Duplicate the normalized scene or use five export collections.
2. For each link, select only its visible rigid geometry.
3. Express the geometry in that link's local frame; its intended runtime pivot must be at local
   origin.
4. Export one GLB with no parent transform baked from another moving link.
5. Use these filenames:
   - `base.glb`;
   - `upper-structure.glb`;
   - `boom.glb`;
   - `arm.glb`; and
   - `bucket.glb`.
6. Record any remaining local translation, rotation, and uniform scale in a reviewable mapping file
   rather than repeatedly editing geometry.

Do not overwrite `assets/visual/original` until the new asset version, bounds, hashes, provenance,
and authoritative-frame mapping are approved together.

## Validation Procedure

### 1. Validate the GLB container

Drag the file into the official Khronos glTF Validator and require no errors:
https://github.khronos.org/glTF-Validator/

Record warnings and explain why any retained warning is safe. Do not ignore invalid accessors,
non-finite transforms, missing buffers, or unsupported required extensions.

### 2. Re-import into a clean Blender scene

1. Close the export source.
2. Open a new empty scene.
3. Import `excavator.glb`.
4. Confirm the exact node names and parent-child structure.
5. Confirm every moving ancestor scale is `[1, 1, 1]`.
6. Confirm mesh bounds and neutral-pose dimensions.
7. Confirm all five work-frame empty nodes are present.

This catches exporter-only hierarchy, transform, and custom-property loss.

### 3. Check in Babylon.js

Load the GLB in the Babylon.js Sandbox:
https://sandbox.babylonjs.com/

Check:

- the model faces the expected direction after one root-axis conversion;
- no link is mirrored or inside-out;
- materials and normals render correctly;
- there are no unexpected cameras, lights, or automatically playing animations; and
- the node hierarchy remains discoverable by its approved names.

### 4. Check known poses

Validate at least these configurations against CAD-provided reference values:

1. neutral pose;
2. one pose with a positive swing and nonzero boom angle; and
3. one asymmetric boom/arm/bucket pose.

For each pose, record joint values in radians and expected world positions for:

- `boom_link` origin;
- `arm_link` origin;
- `bucket_link` origin;
- `tooth_left`;
- `tooth_center`; and
- `tooth_right`.

A model that only looks correct in the neutral pose has not passed kinematic validation.

### 5. Record the file identity

From PowerShell:

```powershell
Get-FileHash -Algorithm SHA256 -LiteralPath .\excavator.glb
```

Record the digest together with:

- source assembly revision;
- SOLIDWORKS and Blender versions;
- selected source configuration/display state;
- export settings;
- intended scale;
- included/suppressed part list; and
- model author/owner permission.

## Acceptance Checklist

- [ ] The intended full-size or physical-model scale is explicitly recorded.
- [ ] The overall bounds match the approved CAD dimensions in metres.
- [ ] The GLB passes the Khronos validator with no errors.
- [ ] Re-import preserves the exact hierarchy and node names.
- [ ] All joint pivots match CAD rotation centres.
- [ ] Joint axes and neutral pose are explicitly documented.
- [ ] No moving ancestor has non-unit, negative, mirrored, or non-uniform scale.
- [ ] Three tooth frames, bucket-fill reference, and bucket outlet are present.
- [ ] Neutral and two nonzero known poses match CAD reference coordinates.
- [ ] Materials and normals render correctly in Babylon.js.
- [ ] There are no unnecessary cameras, lights, animations, or required unsupported extensions.
- [ ] SHA-256, source revision, exporter versions/settings, and rights evidence are recorded.
- [ ] The asset has not overwritten the current committed visual model before integration approval.

## Common Failure Modes

- **Model is 35 times too small or large:** scale was guessed or applied in more than one tool.
- **Links orbit instead of rotating in place:** the joint empty is not at the true CAD rotation centre.
- **One pose looks correct but motion is wrong:** a joint axis, zero offset, or parent frame is wrong.
- **Model is mirrored:** a negative scale or per-link coordinate conversion was retained.
- **Bucket excavation path is wrong:** tooth nodes were estimated from mesh bounds rather than CAD.
- **Re-export breaks integration:** node names or hierarchy were generated automatically and changed.
- **GLB validates but kinematics are wrong:** format validity does not prove mechanical correctness.
- **Current BabylonSim rejects the new asset:** one unified GLB was supplied where the existing
  five-entry visual manifest still expects separate link assets.

## References

- Khronos glTF 2.0 specification:
  https://registry.khronos.org/glTF/specs/2.0/glTF-2.0.html
- SOLIDWORKS Extended Reality GLB/glTF export:
  https://help.solidworks.com/2026/chinese-simplified/SolidWorks/sldworks/t_export_using_extended_reality.htm
- Blender glTF 2.0 importer/exporter:
  https://docs.blender.org/manual/en/3.6/addons/import_export/scene_gltf2.html
- Khronos glTF Validator:
  https://github.khronos.org/glTF-Validator/
- Babylon.js Sandbox:
  https://sandbox.babylonjs.com/
- Existing BabylonSim visual contract: `docs/visual-model.md`
