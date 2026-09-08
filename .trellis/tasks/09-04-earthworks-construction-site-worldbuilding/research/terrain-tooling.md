# Terrain tooling research

## Voxel Tools 1.7 official findings

- Release/toolchain: <https://github.com/Zylann/godot_voxel/releases/tag/v1.7>
- `VoxelTerrain` 是恒定 LOD，`VoxelLodTerrain` 面向大型可变 LOD terrain：<https://voxel-tools.readthedocs.io/en/latest/api/VoxelTerrain/>、<https://voxel-tools.readthedocs.io/en/latest/api/VoxelLodTerrain/>
- 平滑可挖地形使用 SDF 与 `VoxelMesherTransvoxel`；SDF 负值是实体、正值是空气：<https://voxel-tools.readthedocs.io/en/latest/smooth_terrain/>
- terrain 至少需要一个 `VoxelViewer` 才会生成；viewer 可请求 visuals/collisions：<https://voxel-tools.readthedocs.io/en/latest/api/VoxelViewer/>
- `VoxelTerrain.bounds` 限制可存在 voxel 的空间；data block 固定 16³，mesh block 可用 16 或 32：<https://voxel-tools.readthedocs.io/en/latest/api/VoxelTerrain/>
- runtime editing 使用 `get_voxel_tool()`，批量编辑前可用 `is_area_editable(AABB)`：<https://voxel-tools.readthedocs.io/en/latest/api/VoxelTool/>

Decision: 有限、近距离、要求全分辨率编辑的 64 m 工作区使用 `VoxelTerrain`，而不是引入 LOD0 编辑半径和 streaming 复杂度的 `VoxelLodTerrain`。初始 `mesh_block_size=16`，bounds 对齐 data blocks。

## Terrain3D official findings

- 每张地图必须使用独立 `data_directory`；material/assets 可外置复用：<https://terrain3d.readthedocs.io/en/stable/docs/installation.html>
- region 默认为 256，可配置 64–2048；region size 同时定义 map 像素/顶点尺度：<https://terrain3d.readthedocs.io/en/stable/docs/introduction.html>
- control hole 同时影响视觉和 collision；控制图是专用 uint32 bitfield：<https://terrain3d.readthedocs.io/en/stable/docs/controlmap_format.html>
- 只有已定义 region 才生成 Terrain3D collision；region 外 `get_height()` 返回 NAN：<https://terrain3d.readthedocs.io/en/stable/docs/collision.html>
- import position 会对齐 region grid；Terrain3D 会切片/填充 region：<https://terrain3d.readthedocs.io/en/stable/docs/import_export.html>
- Terrain3D 1.0.2 官方明确支持 Godot 4.4–4.6，4.7 仅为可能兼容，因此必须执行目标 custom build canary：<https://terrain3d.readthedocs.io/en/stable/docs/installation.html>

Decision: 中央可挖区对齐并独占一个完整未分配的 Terrain3D region。外围 hard terrain 只分配其他 region，由 VoxelTerrain 填充中央空间。这比像素级 control-hole mask 更易证明不存在双表面/双碰撞，也最适合作为后续产品集成前的独立地编基线。

## Integration limit

Voxel Tools 与 Terrain3D 均没有官方提供的彼此裁切或无缝拼接 API。边界质量由所有权划分、region/voxel 网格对齐、过渡带构图和实际碰撞可视化验证保证，不能把不同 collision layer 当作消除视觉重叠的方案。
