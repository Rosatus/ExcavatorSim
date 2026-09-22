# Godot-first implementation — 2026-09-08

User approved execution and deferred Blender work. Workbench implemented in `godot/worldbuilding/earthworks_site`; task remains in progress pending human visual acceptance.

## Delivered

- Independent Godot project, copied ignored addon cache, SHA-verified custom engine and curated GLB cache, tracked import policies and missing-asset proxies.
- Eight 64m Terrain3D regions, no central region, explicit background NONE, four procedural texture roles, native hard-ground collision.
- 64×20×64m finite voxel volume at 0.25m/voxel with image-generated raised workface and protected perimeter. Initial editor mesh is disabled at runtime.
- 9m rounded haul loop, entrance, maintenance shelter, material stacks, stockpile proxies, drainage, boundary barriers and sparse vegetation. Three review cameras, free camera and switchable dimensions/vehicle templates.
- Four GLB types copied unchanged: pipe, pallet, sand, plant. One each of heavy anchors, 12 small plant instances. No Blender work or source asset mutation.
- README and deferred Blender requirements list.

## Verified

- Target editor and Terrain3D load in Forward+/Vulkan on RX 9070 XT.
- Representative sample smoke passed before full build.
- Full reload smoke passed: 8 regions, background NONE, 4 texture roles, voxel bounds, initial mesh hidden, deep solid SDF (-47.99035 at -12m), actual voxel collision, local removal lowering collider without hard ground beneath, haul route support and four-edge seam probes, forced proxy loading.
- Engine/addon critical files and source-cache SHA checks passed. Import params match tracked files.
- One stationary Forward+ overview snapshot: 1280×720, 144 FPS, p50 6.992ms, p95 7.252ms, 1176 draw calls, 1364 render objects, 4,705,218 primitives, 746,195,168 bytes reported video memory. This is not a vehicle/soil-cycle benchmark; VSync may cap FPS. No aesthetic pass inferred.
- Independent read-only review found regeneration/cache-policy issues; sample now rejects existing scene/data, addon critical files are hashed against repository sources, cached import params are compared to tracked policy.
- No current-run script/shader errors in final editor/performance logs. Terrain3D uses one deprecated engine interpolation method and still emits its upstream warning.
- MCP: original product `client@fefe` remains stopped on main.tscn. Separate `earthworks-site@b232` ready on workbench scene (session IDs are ephemeral).

## API lessons

- Voxel Tools pinned source `generators/simple/voxel_generator_heightmap.h` has a below-height_start raw-zero optimization. With current format it yielded SDF 0 deep underground. Encode the complete bound range: image=(height_m+16)/20, height_start=-64, height_range=80; regression reads actual deep SDF.
- Finite voxel mesh ends at last sample 63.75m, while Terrain3D starts at 64m. Two disjoint 0.25m strips in the reserved perimeter fill only that gap; collision mask bits 1|2|4 cover all three owners.
- Terrain3D resources require explicit saved paths; take_over_path preserves external resources in PackedScene. free_editor_textures=false keeps texture assets inspectable in the standalone workbench. Terrain3D saves and reloads the 64m region size through data resources.

## Pending / limitations

- AC8 and subjective parts of AC2/AC5: human Forward+ review. Scene is a baseline for continued dressing, not declared finished photorealism.
- Frame snapshot includes no active meshing edits; edit spikes were not benchmarked. Actual vehicle swept-path/dynamic validation remains product migration work; current map contains dimensional templates and a 9m/15m horizontal route.
- Stockpile shapes and repeated prop optimization recorded in blender-requirements.md. All static dressing is visual, not authoritative dump soil or vehicle obstacle collision.
- Existing product dirty files from parallel work are untouched by this task. No commit/archive performed while visual acceptance remains pending.
