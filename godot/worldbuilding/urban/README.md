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

## 路面标高（2026-09 修复后）

整张图的可行驶面只有一个 `GroundPlane`（1200m BoxShape，顶面 **y=1.08**）；`SplineMeshComponent_*` 节点是 UE 迁移残留的空标记，没有几何。路口、斑马线、井盖等都是叠在平面上的独立件。**契约：这些路面件是纯视觉道具，保留原始摆放高度（井盖突起等为刻意保留的观感），一律不带碰撞体**——行驶面物理上就是平整的 GroundPlane，压过去不再有台阶：

- `Intersection1/2`（`Prefabs/Cube.tscn` 沥青平板，厚 0.1）：节点 y=1.09，顶面 1.14，比路面高 6cm——视觉上是一块略厚的沥青补丁，物理上无碰撞。
- `prp_manhole*`（4cm 圆盘，底部枢轴）：路面上 y≈1.2（悬空摆放，无碰撞）。
- `prp_sewerGrate*`（1cm 篦子）：路面上 y≈1.159；路缘/人行道区的篦子（y≈1.336/1.359）在路缘石高度上，属正常。
- `CrssWk_*`（零厚度斑马线面片）：y≈1.15。
- `Cube.tscn`/`CrssWk_4L.tscn`/`CrssWk_1L_Pk.tscn` 三个 prefab 里的 `StaticBody`/`CollisionShape3D` 已删除——**不要给这些 prefab 加回碰撞体**，加了就会重新出现路面台阶。井盖/篦子本来就没有碰撞体。
- `GroundArea1_9809_Cube_*`（y=1.297 混凝土铺装块）是抬高的人行广场（Cube_1.tscn，保留碰撞体），不是路面。

验证脚本 `tests/test_road_survey.gd`：`test_survey` 对全部路面件向下 raycast 写 `tests/_road_survey.json`；`test_props_are_collision_ghosts` 断言射线穿过道具命中下方支撑面（即道具自身无碰撞）；`test_intersection_drive_surface` 断言两个交叉口 footprint 内行驶面恒为 ~1.08。改路面后跑整个 `road_survey` 套件即可回归。

**保存陷阱**：`MultiMeshInstance3D` 的旧版 `mesh = ExtResource` 写法在加载时不会迁移到 `multimesh.mesh`，编辑器再次保存会把植被网格引用丢掉。现在 `mesh =` 已写在 `[sub_resource MultiMesh]` 块内（正确位置），之后的保存不会再丢。如果植被突然消失，检查 `MM_flg_*` 块里有没有 `mesh` 行。