# urban 路面高差修复

## 需求

Urban-City 地图中心 Intersection2 与四个方向的街道存在高差；井盖等路面
件也有可见高差。要求修复所有道路连接处的视觉/物理台阶。

## 发现（编辑器内 raycast 实测）

整张图的可行驶面只有一个 `GroundPlane`（1200m BoxShape，顶面 y=1.08）。
`SplineMeshComponent_*` 是 UE 迁移残留空标记，无几何。路面件统一浮高：

| 件 | 数量 | 原顶面 | 间隙 |
|---|---|---|---|
| Intersection1/2 (Cube 沥青平板, 带碰撞) | 2 | 1.14 | +6cm |
| prp_manhole* (4cm 盖) | 53 | 1.24 | +16cm |
| prp_sewerGrate* (1cm 篦子) | 81 | 1.169 | +8-10cm |
| CrssWk_* (零厚度斑马线) | 7 | 1.15-1.16 | +8-9cm |

## 修复

统一规则：顶面 = 脚下 raycast 支撑面 + 3~5mm（避让 z-fight）。
共调整 143 个节点（2 路口板、81 篦子、53 井盖、7 斑马线），全部通过
编辑器 `EditorUndoRedoManager` 单动作应用（可撤销），最终以文本补丁写入
`Urban-City.tscn`（规避编辑器保存副作用，见下）。

刻意跳过：12 个路缘区篦子/井盖（y≈1.34-1.38，路缘石/人行道高度，正常）、
1 个被 2.01m 覆盖物遮住的井盖（不可见）。

## 顺带修复

- `project.godot`：启用 `addons/godot_ai` 插件 + `_mcp_game_helper`
  autoload（MCP 接入必需）。
- `MultiMeshInstance3D` 的旧版 `mesh = ExtResource` 属性在加载时不迁移、
  保存即丢失 → 已把 `mesh=` 挪进 `[sub_resource MultiMesh]` 块内（正确位置），
  8 块植被实例网格引用持久化。此前编辑器保存曾静默丢弃。
- 撤销了编辑器重扫造成的 76 个 `.tres` uid 噪声改动。
- `urban/README.md` 记录路面标高契约与保存陷阱。
- `tests/test_road_survey.gd`：可重复的路面件 raycast 普查 + 幂等修复，
  供后续回归。

## 验证

- 编辑器内重跑 survey：所有路面件顶面-支撑面间隙 ∈ {0.003, 0.004, 0.005}m。
- 粗略网格 raycast（2.5m 步长，6000+ 点）：路面带无 >3.5cm 台阶。
- `urban.pck` 已重建（SHA256 75d2b95e…）。
- `godot/client/tests/urban_pack_test.gd`：PASS（2588 static bodies，
  无失败；UID fallback 警告为既有噪声）。

待办：人工目视检查交叉口过渡观感与驾驶手感。

## 修订（同日，用户反馈后）

原方案把所有路面件降到支撑面+3~5mm，结果视觉被地面吞没（井盖只剩 4mm 薄片、斑马线沉入路面）。按用户要求改为：**保留原始突起观感，移除碰撞**。

- 恢复全部 143 个节点的原始 transform（`git checkout 099c102` 回滚 + 重放 foliage 补丁）。
- `Cube.tscn`/`CrssWk_4L.tscn`/`CrssWk_1L_Pk.tscn` 三个 prefab 删除 `StaticBody`+`CollisionShape3D`+`BoxShape3D`——交叉口 6cm 台阶和斑马线浮空薄片碰撞消失，轮胎走 GroundPlane (y=1.08)。
- `prp_manhole`/`prp_sewerGrate` 本就无碰撞体，纯恢复高度即可。
- `Cube_1.tscn`（人行广场）保留碰撞体。
- 测试改为新契约：`test_props_are_collision_ghosts`（射线穿过道具）+ `test_intersection_drive_surface`（交叉口 footprint 内行驶面恒 ~1.08）。headless `_verify_flat.gd`：157 个道具实例 0 碰撞体，交叉口网格探测全平——PASS。
- 重建 `urban.pck`（SHA256 94ac3670…），`urban_pack_test` PASS（2579 static bodies = 2588−9 个被删碰撞体）。

坑：手工改写 CrssWk_1L_Pk.tscn 时把 instance id 抄成了 4L 的 `1_bkush`，导致场景加载失败弹"加载错误"模态框阻塞 MCP；headless 预检脚本 `check_tscn_parse.gd` 定位。改 prefab 文件后务必 headless 验证再重载场景。
