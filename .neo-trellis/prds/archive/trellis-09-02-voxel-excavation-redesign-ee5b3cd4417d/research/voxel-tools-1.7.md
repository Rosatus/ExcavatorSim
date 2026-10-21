# Voxel Tools 1.7 planning evidence

Research date: 2026-09-02.

## Local toolchain facts

- `tools/godot_voxel_toolchain.json` pins
  `E:/applications/godot_voxel/godot.windows.editor.x86_64.exe` to Godot
  `4.7.2.stable.custom_build.ed1daf0bf` and Voxel Tools `1.7`.
- `assets/licenses/VoxelTools-PROVENANCE.md` records upstream tag `v1.7` and
  commit `2ac9f5f`.
- `godot/client/tests/voxel_module_smoke.gd` currently proves only that
  `VoxelTerrain` and `VoxelLodTerrain` exist and can be instantiated. Product
  terrain/generator/editor API integration remains unimplemented.

## Official upstream facts used by the design

- `VoxelTerrain` uses a constant-detail grid and is intended for blocky or
  moderate-size smooth volumes. `VoxelLodTerrain` adds octree LOD for much
  larger view distances. Both support runtime edits and remesh edited blocks.
  Source: https://github.com/Zylann/godot_voxel/blob/master/doc/source/overview.md
- Smooth terrain uses `VoxelMesherTransvoxel` and the SDF channel. Negative SDF
  is matter, positive SDF is air, and gradients must remain continuous.
  Source: https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/
- Voxels are one engine unit in Voxel Tools 1.7. Smaller cells require uniform
  node scale; non-uniform scale is discouraged because it may cause collision
  problems. The planned `0.125 m` starting scale maps the `32 m` side to 256
  voxels, within the documented moderate `VoxelTerrain` range.
  Source: https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/#voxel-size
- `VoxelTool` exposes native bulk primitives including `do_path`, `do_sphere`,
  `do_box`, and `do_mesh`. `do_path` is a linearly connected variable-radius
  capsule chain. `do_mesh` accepts a baked `VoxelMeshSDF` but costs more than
  primitives. Repeated single-voxel terrain calls are the slow path.
  Source: https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/
- `VoxelTerrain.mesh_block_size` supports 16 or 32. Larger blocks reduce draw
  calls but make edits slower; 16 is therefore the foundation starting point.
  Source: https://voxel-tools.readthedocs.io/en/latest/api/VoxelTerrain/
- A `VoxelViewer` is required for generation and collision. Multiple viewers
  influence load/update priority and can independently request visuals and
  collision.
  Source: https://voxel-tools.readthedocs.io/en/latest/api/VoxelViewer/
- Generated collision is built with the mesh and is expensive, especially its
  main-thread acceleration structure. `is_area_meshed()` and statistics such as
  `remaining_main_thread_blocks`, `dropped_block_meshs`, and `updated_blocks`
  are observable readiness/backlog evidence, but do not expose an explicit
  per-edit collider revision.
  Sources:
  - https://voxel-tools.readthedocs.io/en/latest/api/VoxelTerrain/
  - https://voxel-tools.readthedocs.io/en/latest/performance/

## Design consequences

1. Use bounded `VoxelTerrain`, not `VoxelLodTerrain`, unless the foundation
   benchmark disproves the constant-detail choice.
2. Start with uniform `0.125` scale, 16-voxel mesh blocks, 16-bit smooth SDF,
   one always-on zone viewer, and a chassis-local collision-priority viewer.
3. Keep a project-owned generation/revision/ticket wrapper because Voxel Tools
   does not publish the strict collider identity required by current Jolt
   contracts.
4. Treat SDF mutation as synchronous data acceptance and mesh/collider creation
   as asynchronous derivative work. Never use collider timing to decide which
   soil is removed.
5. Establish exact v1.7 API behavior in an isolated foundation scene before
   product integration, including scaled bounds, SDF channel depth, copy/paste,
   editability, `is_area_meshed()` transitions, reset teardown, and Jolt mesh
   collision readiness.

