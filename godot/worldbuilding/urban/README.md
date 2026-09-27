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

**植被实例删除**：`Foliage` 节点下的 `flg_bush_*`/`flg_groundLeaves`/`flg_plane*`/`flg_tree_*` 是 MultiMeshInstance3D——单个草丛/落叶堆/树在编辑器里无法点选删除，只能从 `MM_flg_*` 的 `transform_array`（PackedVector3Array，每实例 12 个数=9 基向量+3 原点）按坐标剔除对应实例并同步 `instance_count`。花坛内的绿篱草是 `flg_bush_01` 实例（y≈2.10 在花坛土层高度）。

**人行道砖删除（spline 合并网格）**：`sidewalk_Straight_Splines_0` 整块城市路面是一条**合并 ArrayMesh**（GLB 内只有 1 个 Mesh 子节点，surface 0=人行道/路缘、surface 1=车行道），砖块没有独立节点，编辑器里无法选中单删。删法：`tools/trim_spline_tiles.gd`（headless）按"三角面质心落入矩形"剔除 surface 0 的三角形，另存 `maps/urban/sidewalk_Straight_Splines_0_trimmed.res`；prefab `Prefabs/sidewalk_Straight_Splines_0.tscn` 里用 `mesh = ExtResource` 覆盖挂上（GLB 源资产不动，删 `mesh` 行即回退）。**切割边界用三角形裁剪可对任意 x 齐平**（顶点逐属性插值新增，不必对齐砖缝；相邻砖 x 接缝见脚本注释）。z 带宽 [27.45, 29.65] 覆盖路缘立面/黄色 curb 顶面/人行道砖，避开上层人行道（z≥30.6）与车行道 surface 1。已删区段：B6 左边缘（x=14.82，跨砖内平面裁剪）至 Tall107 绿篱（x=39.47 砖缝）的 **8.5 块砖 + 整段黄色 curb**；缺口内 `groundLeaves`/`flg_tree_01`/`flg_plane` 各删 1 个悬空实例，草簇（基座已在地面层）与路面下水道篦子保留。

## 风摆着色器（2026-09 修复后）

UE `SimpleGrassWind` 迁移出的 VisualShader 里，世界坐标曾被错译为 `INV_VIEW_MATRIX * vec4(VERTEX, 1.0)`——`VERTEX` 在 `vertex()` 阶段是模型空间，乘逆视图矩阵把相机位置混进风摆相位，表现为**车开越快旗子/树叶摆得越快**。已改为 `MODEL_MATRIX * vec4(VERTEX, 1.0)`（含实例变换，世界相位稳定）。

- 受影响且已修复：`Shaders/Flag_Inst.tres`、`Shaders/Foliage_01_Inst.tres`、`Shaders/prp_tarp_mat.tres`。
- **契约**：`vertex()` 阶段的世界坐标必须用 `MODEL_MATRIX`；`INV_VIEW_MATRIX * VERTEX` 只在 `fragment()` 阶段合法（那里 `VERTEX` 本就是视图空间）。其他 `MI_*`/天空材质里的同名片段都在 fragment 阶段，勿动。
- 回归检查：`tests/_check_wind_shader.gd`（headless）遍历三个 VisualShader 的表达式节点，断言无 `INV_VIEW_MATRIX * vec4( VERTEX` 且有 `MODEL_MATRIX`。

## 道具落地（2026-09 修复）

同源于 UE 迁移标高不统一：大量**独立道具**（绿篱、草丛、桌椅、垃圾桶、护栏、花坛、电线杆、标识牌等 40+ 类）的网格底部悬空于支撑面 5–32cm。与建筑不同，这些道具没有堆叠上层，**直接降 transform 落地**即可：

- 普查方式：对全场景实例化 Node3D 做"视觉 AABB 底 vs 向下 raycast 支撑面"对比，gap>2cm 标记（`tests/test_prop_grounding.gd`）。
- 处理：612 个道具按 raycast 命中的支撑面下落（植被嵌入 3cm 模拟栽种，硬质道具嵌入 5mm）；堆叠件先降支撑再降其上物件（迭代至收敛）。
- **挂墙件不降**：`Awning_mdl`/`StoreSign_*`/`prp_flag`/`prp_vent_*`/`prp_powerlines` 整类跳过；`prp_ac_*` 按单项判定（gap>0.6m 视为挂墙）。
- **花坛连带**：`gardenPlanter_*` 自身落地时，`MM_flg_*` transform_array 中落在其 footprint 内的灌木/树实例按相同 dy 平移（花盆内 y-band 约束，地面植被不受影响）。
- 排除：建筑套件全部（F1 由基座覆盖、F2/F3 堆叠属预期）、路面纯视觉道具（井盖/斑马线等，见路面标高节）。
- 契约：`prop_grounding` 套件断言全场景 lower=0；新摆的道具若悬空会被回归抓住。报告写 `tests/_prop_grounding.json`（已 gitignore）。

## 里程碑

- **本提交（包含本条目的文档提交）标记为体素地图编辑工作开始前的最后一次提交**，取代 `e45299c` 处的旧标记。此前城市地图为纯静态布景（无 `ExcavationArea`、无 voxel 挖掘），全部静态布景修复（路面标高、道具落地、建筑基座、花坛/植被清理、`GroundPlane` 视觉网格下移固化、内院填充方案回退）均已落地；此后的体素相关改动均以此为分界基线。

## 建筑基座（BuildingPlinths，2026-09 修复）

UE 迁移的地面层建筑模块（`B*_F1_*`、`door_*`/`Door*_mdl`、`Building_*_0*`）网格底部就在节点原点（局部 y=0），而原点标高不统一（1.0/1.15/1.25/1.3/1.35/1.36），多数落在路面 y=1.08 或人行道铺装 y=1.297 **之上 3~30cm**——表现为"建筑悬空"。F2/F3 楼层模块是绝对堆叠的，**降 F1 会在楼层间开缝，不能动 transform**。

修复方式：场景根部新增 `BuildingPlinths`（MultiMeshInstance3D），为每个地面层模块（原点 y<2）垫一块与立面齐平的混凝土基座盒——footprint 每边外延 5cm、顶面嵌入模块底 2.5cm、下探至原点下 80cm。材质用广场铺装同款 `concrete_ground_01_Inst.tres`。**纯视觉、无碰撞体**（建筑立面碰撞原本就在）。

- 校验：`tests/test_building_plinths.gd`——每个地面层模块必须有匹配基座（origin/basis 容差 0.01），且不允许碰撞体；`building_plinths` 套件可回归。
- 埋在地里的模块（基座低于地表）基座同样生成，只是不可见，属预期。

**手工编辑 tscn 的 Transform3D 陷阱**：本文件（及本引擎写出的 tscn/PackedVector3Array transform_array）的 9 个 basis 浮点是**按行存储**的——`Transform3D(a,b,c, d,e,f, g,h,i, ox,oy,oz)` 的基向量列 = (a,d,g)/(b,e,h)/(c,f,i)。按 GDScript `Basis(x,y,z)` 列序解读会把 ±90° 旋转的模块转置错向（对称旋转恰好无感）。写 transform_array 时也要写成行序。
