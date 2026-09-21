# Contained soil and real-mouth unloading

Use for a new soil-holding attachment or changed bucket geometry. Runtime and tooling support
one convex planar opening, with lining representable as a height field along that mouth's
normal. Articulated jaws, multiple outlets, strongly nonplanar rims or overhangs that hide
usable cavities need a different representation; do not disguise them with arbitrary points.

## Ownership and files

- `godot/client/scripts/bucket_soil_geometry.gd`: measured mouth polygon → shared local frame,
  cavity and consistency/provenance checks.
- `bucket_fill_surface.gd`: profile → contained visual solid. New attachments call
  `configure_contract`; `PROFILE_PATHS` is only the existing native-model compatibility map.
- `bucket_soil_release.gd`: orientation/threshold policy. Authority retains confirmation,
  obstruction, queue and exact material ownership. Do not move ledger mutations into visuals.
- `resources/attachments/gb12_s50_soil_bake.json`: working recipe example.
- `tools/bake_bucket_soil.gd`: generic imported-mesh baker; `--check` compares outputs without
  writing. `tools/preview_bucket_soil.gd`: Forward+ renders at 5%, 50% and 100% stock.

Paths above are relative to `godot/client/` unless prefixed `tools/`.

## Determine the mouth before baking

Inspect source documentation and imported hierarchy/transforms. Select the actual inner outlet,
not tooth tips, bounding-box corners or a rear edge hidden beneath a crown. GB12's outlet uses
the lip top and crown front underside; that choice is specific to its mesh.

Choose 3–32 ordered polygon anchors. The first edge defines cavity width; the polygon's
right-hand normal must point out of the cavity. Anchor coordinates are tool-root-local meters,
even when their source mesh has transformed parents. The baker snaps each hint to an actual
imported mesh vertex within `anchor_tolerance_m`, then rejects nonconvex/nonplanar polygons.
Do not raise the tolerance to conceal a source-model change.

Select exact, unique imported mesh names for all interior obstructions: lining, side plates,
crown and internal gussets. Exclude decals, pins and external wear runners. Footprint maximum
sampling prevents thin gussets from disappearing between rays; it remains a height-field
approximation, not a volumetric mesh solid solver.

## Recipe (`bucket-soil-bake-v1`)

Copy the GB12 recipe and replace asset-specific data:

| Fields | Meaning |
|---|---|
| `tool_id`, `fill_profile_id` | Catalog tool and independent visual profile identity |
| `asset_path`, `asset_sha256`, `root_node` | Imported GLB and tool-local frame |
| `contract_path`, `profile_path`, `catalog_path` | Project `res://` resources; create base contract/catalog entry first |
| `lining_nodes` | Exact imported mesh names; every entry must resolve uniquely |
| `mouth_anchors` | `{node, near_tool_local: [x,y,z]}` in perimeter order |
| `anchor_tolerance_m` | Maximum source-vertex displacement accepted by the recipe |
| `cavity_depth_m` | Sampling frame center sits half this distance behind the mouth |
| `columns`, `rows` | Grid dimensions, 5–129; use 25×33 initially |
| `x_bounds`, `z_padding_m` | Cavity-local width domain and dry depth border; domain must cover mouth |
| `release_opening_down_dot` | Behavior threshold in [0.15,1), not a geometric measurement |
| `evidence` | Why these meshes, mouth boundaries and behavior parameters were selected |

Keep cut/shell regions, capacity and other base-contract tuning intentional. The baker updates
only opening/cavity geometry, their semantic regions, fill resource references and the release
threshold. It does not infer tooth locations, change nominal capacity or recalibrate soil mass.

Generated `soil_geometry` stores the single authoritative tool-local mouth polygon, cavity depth,
profile path/hash and GLB path/hash. Opening/cavity proxies and semantic region fields are
generated compatibility projections, checked against that geometry. Do not hand-edit them.
The profile carries the same mouth transformed into cavity coordinates. Runtime release uses
the transformed opening's +Y axis; host curl, coupler tilt and rotation are inherited naturally.

## Execute and inspect

Use PowerShell non-login mode and the repository voxel Godot toolchain. The following resolves
the editor; launch it hidden with redirected stdout/stderr, wait for completion and check both
the exit code and logs (GDScript assertion errors may otherwise look like a successful run).

```powershell
. ./tools/godot_voxel_toolchain.ps1
$soilToolchain = Get-GodotVoxelToolchain -Components @('windows_editor')
$soilGodot = $soilToolchain.components.windows_editor.path
```

Bake arguments:

```text
--headless --path godot/client --script ../../tools/bake_bucket_soil.gd -- res://resources/attachments/<tool>_soil_bake.json
```

Run the same arguments with `--check` appended to verify deterministic output without writing.
The baker validates inputs/generated data before writing and updates the catalog hash last.
If interrupted during output, rerun the recipe; do not accept a partially updated hash chain.

Preview arguments (requires rendering; omit `--headless`):

```text
--path godot/client --resolution 960x720 --script ../../tools/preview_bucket_soil.gd -- res://resources/attachments/<tool>_soil_bake.json <absolute-output-directory>
```

Inspect all three PNGs for floating patches, lining penetration, covered-mouth mistakes,
incorrect normals, and implausibly small/full stock. Rotate the view if the default camera
cannot see the relevant cavity. Rendering checks appearance; it does not establish unloading
physics or manufacturer-rated capacity.

## Verification and tuning

Use `bucket_soil_geometry_test.gd` for schema, drift rejection and registry-independent loading.
Follow `gb12_soil_test.gd` to add source-specific containment and real attachment tests, including
low/full stock, compound tilt/rotation/curl, stale snapshots and switching back to a native bucket.
Follow `gb12_soil_dump_test.gd` for a terrain transaction that releases only when admitted and
conserves mass. Reuse standard fill/follow and attachment-switch regressions for shared changes.

The release threshold is an explicit gameplay choice: `down_dot = sin(degrees below horizontal)`.
GB12 currently uses .15 (~8.63°); do not copy it as a physical law for every tool. Confirmation,
cut engagement and outlet obstruction still apply. Fill-dependent/repose-based side spilling is
not implemented by this representation. Record any requested in-game human acceptance as
pending rather than inferring it from a headless pass.
