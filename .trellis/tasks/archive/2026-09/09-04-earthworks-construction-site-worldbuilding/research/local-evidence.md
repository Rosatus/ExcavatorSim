# Local evidence

## Project/toolchain

- `godot/client/project.godot:11-15` 指向 `res://scenes/main.tscn`；本任务不得修改该入口。
- `tools/godot_voxel_toolchain.json` 锁定 Godot `4.7.2.stable.custom_build.ed1daf0bf` 与 Voxel Tools `1.7`，Windows editor 默认位于 `E:/applications/godot_voxel/godot.windows.editor.x86_64.exe`。
- `godot/client/addons/terrain_3d/plugin.cfg:1-7` 声明 Terrain3D `1.0.2`。
- 2026-09-04 规划时 Godot AI MCP 会话 `client@7994` 正在播放 `res://scenes/main.tscn`。因此不应在该 session 中切换或保存 workbench scene。

## Existing implementation evidence used only as API proof

- `godot/client/tests/voxel_module_smoke.gd:3-15,53-62` 已验证 custom engine 中 `VoxelTerrain`、`VoxelLodTerrain` 和 `Terrain3D` 的 ClassDB 可用性。
- `godot/client/scripts/voxel_work_zone.gd:40-92` 证明项目能组合 `VoxelTerrain`、`VoxelGeneratorFlat`、`VoxelMesherTransvoxel`、碰撞与 `VoxelViewer`，但其坐标和车辆路径绑定现有场景，本任务不复用布局。
- `godot/client/tests/terrain3d_forwardplus_probe.gd:165-218` 证明 Terrain3D 可在不加载产品主场景的最小 Forward+ rig 中建立。

## Construction asset inventory

- `E:/projects/blender/construction/roadside_construction_godot/manifest.csv` 包含 44 个转换后 GLB，总量约 2,790.7 MiB、约 54.7M triangles。
- 常规施工道具通常约 0.94M–2.0M triangles；`rough_stone_boulder__xksldamqx.glb` 约 6.0M，`broken_asphalt_slab_pile__tlhjacuva.glb` 约 5.3M，首轮排除。
- 首轮候选来自 `roadside_construction_godot/models/`：sand/fine-sand pile、concrete drainage pipe、wooden pallet、wheelbarrow、green dumpster、shovel、folding sawhorse barricade、traffic barrel/cone、stop sign 和少量 `sfcnq` 枯植被变体。
- 所有 GLB 内嵌纹理。按 `.trellis/spec/frontend/godot-mcp.md`，源字节保持不变并使用 embedded-image import policy；`.godot/imported` 不作为源。

## Isolation conclusion

`godot/worldbuilding/earthworks_site/` 是独立 Godot project，位于 `godot/client` project root 之外。它避免当前客户端编辑器扫描 GLB，同时仍处于同一 Git repository，便于后续显式迁移与审阅。
