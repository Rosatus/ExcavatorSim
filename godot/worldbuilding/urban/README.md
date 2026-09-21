# Urban 地图工程

城市地图独立维护在此处。主项目只保存地图选择与加载逻辑；本目录的模型、贴图不进入精简版。

## 编辑

用项目固定的 Godot Voxel 4.7.2 编辑器打开此目录的 `project.godot`。

- `maps/urban/Urban-City.tscn`：迁移后的布景，所有地图资源位于 `res://maps/urban/`。
- `maps/urban/WorldEnvironment.tscn`：预览环境。运行产品时使用主项目已有 Sky3D，避免叠加两套环境和太阳光。
- `preview.tscn`：独立地图预览。右键 + WASD 飞行，Q/E 升降，Shift 加速，Esc 释放鼠标。
- `maps/urban/WorkArea.tscn`：出生点。出生点位于路面 (X=-15, Z=20)，朝向 +X。城市为纯静态地图：无 `ExcavationArea`，不启用 voxel 挖掘，驾驶完全依赖 prefab 静态碰撞。注意多数楼顶/街区内部没有碰撞体，出生点已选在实测可行驶的路面口袋（约 20m 净空走廊）。

## 构建与分发

在仓库根目录执行：

```powershell
./tools/build_urban_pack.ps1
```

地图包输出为 `godot/dist/maps/urban.pck`。编辑器运行主项目时从此处读取；导出程序从可执行文件旁的 `maps/urban.pck` 读取。

打包器只收录 `res://maps/urban/` 及其导入缓存，不包含 `project.godot`、插件或客户端脚本。

## 验证

`tests/urban_pack_test.gd`（客户端）在真实 PCK 下验证：包挂载、UID 恢复、场景实例化、出生点应用、Jolt `static_map` 履带支撑、行驶不穿地、WorldEnvironment 已移除、地图 DirectionalLight 禁用、无 voxel/训练场碰撞泄漏。

## 来源

`source_manifest.json` 记录从 `E:/projects/unreal/godot/urban` 复制的源路径、字节数和 SHA-256。源工程由 UnrealToGodot 从 UE4 资产包导出并修复（碰撞变换泄漏、植被 MultiMesh 化、发光材质、天空强度 2915 归一等）。原始目录未改动。
