# construction 地图地面视角画面与性能

## Goal

提升 construction 大地图的**地面视角**（玩法视角）画面质量与渲染性能。
俯瞰视角明确不在考察范围。

## Requirements

### 关键约束（本次调查确立，纠正了早前误判）

**R1 — 出货画面不由 workbench 决定。**
`godot/client/scripts/main_map.gd:28-31` 在加载地图时主动释放 `Construction-Site.tscn` 里的
`WorldEnvironment`：

```gdscript
# Product Sky3D remains the single lighting owner; the workbench sky is preview-only.
var preview_sky := map.get_node_or_null("WorldEnvironment")
if preview_sky != null:
    preview_sky.free()
```

出货光照完全来自 `main.tscn` 的 `WorldEnvironment` + `godot/client/scripts/visual_environment.gd`。
因此：基于 workbench 截图做的画质判断测的是被丢弃的预览；改
`maps/construction/WorldEnvironment.tscn` 只影响预览。

**R2 — 出货画质已在 `VisualEnvironment` 调好。**
`visual_environment.gd`（由 `VisualQualityController` 调用，`main.tscn:194/197`）已实现
low / balanced / high 三档，含：固定 10.5 时、暂停时间、SSAO（radius 0.4 / intensity 0.8）、
Glow（仅 high）、ACES + `tonemap_white 5.5` + exposure 0.96、adjustment
（brightness 1.01 / contrast 1.06 / saturation 0.94）、太阳
（`light_angular_distance 0.35`、`fff1dc`、bias 0.035、normal_bias 1.15、blur 0.85、
`directional_shadow_max_distance 80(high)/55`）、ambient/sun 比 0.58/1.02、0.72/1.16、0.78/1.20；
雾由 Sky3D 屏幕空间着色器负责，内置 fog 显式关闭；月亮与 KeyLight 关闭。

**R3 — `MM_Packs/` 来自上游工程，无生成器。**
`.workbuddy/memory/2026-09-15.md:272` 记录 `E:\projects\unreal\construction` 为上游授权工程，
内含 `MM_Packs` / `Prefabs` / `Shaders` / `Occluders`。全仓搜索确认无任何打包生成器，
只有运行时脚本 `MM_Packs/mm_init.gd`。

Pack 设计（一种类型 × 一个空间格）＝ 1 个 `MultiMeshInstance3D`
（`Meshes/<type>_mesh.res` + `xforms`）→ 1 次 draw call，加 N 个
`StaticBody3D` + `CollisionShape3D` 共用一份 `Shapes/<type>_shape.tres`。
→ **只降 draw call，不降物理体数量**。

覆盖现状：1233 个顶层实例中 356 个已批处理（76 种类型），**692 个未批处理**。
实测 draw call：俯瞰 206 / 出生点（地面）1273。

**R4 — 已否决的改动。**
`maps/construction/ground_runtime.gd:24` 的 `collision.set_mode(3)` **不是 bug**。
`api_manage` 内省 ClassDB 得 `Terrain3DCollision.CollisionMode`：
`DISABLED 0 / DYNAMIC_GAME 1 / DYNAMIC_EDITOR 2 / FULL_GAME 3 / FULL_EDITOR 4`。
`3` 即 `FULL_GAME`。编辑器两条提示仅为"裸整数代替命名常量"的风格警告，且其文本
（`no enum member has matching value`）暗示该枚举在脚本 reload 时可能尚未注册——
改用命名常量有把警告升级为硬报错的风险，**故不改**。

## Acceptance Criteria

- [ ] 出货客户端、地面视角、construction 地图的画面经人工确认优于基线
- [ ] 未引入新的引擎/脚本错误
- [ ] 批处理改动（若进行）必须给出改前/改后 draw call 与帧时间实测对比
- [ ] 不因合批损害地面视角的视锥剔除（MultiMesh 整体剔除，过度合批会变差）

## Notes

- 地图包：`godot/dist/maps/construction.pck`（714 MB，2026-09-12 构建）。
  任何地图内容改动都需重建（`tools/build_construction_pack.ps1`，含 10 GB 资产完整导入）。
- 项目已有客户端视觉取证管线：`godot/client/tests/visual_evidence_capture.gd`、
  `capture_visual_baseline.ps1`、`visual_pass_test.gd`。

## Progress

### 用户决策（2026-09-15）

聚焦**模型本身**的优化（性能 + 拟真），在 workbench 编辑器完成；全局光照留到下一步。

### Completed

| 项 | 文件 | 说明 |
|---|---|---|
| 地面宏观变化 | `maps/construction/Ground.tscn` | `enable_macro_variation=true` + `macro_variation1 Color(0.72,0.66,0.58)` + `macro_variation2 Color(0.9,0.9,0.85)` + `noise1_scale 0.06` / `noise2_scale 0.1`。Terrain3D 开关本默认开启，但两个色调默认纯白等于无效。运行时已验证参数生效；地面截图出现大尺度泥土色斑，远景不再是惨白平板。**传付出货** |
| 地面材质换车辙泥土 | `maps/construction/Ground.tscn` + 新贴图 | 用 `Straight_01` 车辙 decal 源图（8192²）经 `tools/make_dirt_terrain_texture.gd` 处理出无缝 2048² albedo/normal（裁内容→填透明→边缘融合），替换原混凝土贴图；`uv_scale 0.13` 使车辙物理宽度与 decal 一致（单幅 ≈15.4 m）。**传付出货** |
| 小道具距离剔除 | 48 个 `maps/construction/Prefabs/*.tscn` | 各插入 1 行 `visibility_range_end`（AABB 最长边 <1.2 m → 110 m，1.2–2.5 m → 160 m）。工具：`tools/add_visibility_ranges.gd`（按 AABB 自动分级，dry-run/--apply）。截图确认 110 m 内无可见突变。**传付出货** |
| 贴图清晰度 | 10 个 `.import` sidecar + 新贴图 | 8 张车辙 decal + 2 张新地面贴图 `size_limit` 1024→2048，重导入。针对"稍远就糊"的近场清晰度部分 |
| Sky3D `_set` 空引用 | `godot/client/addons/sky_3d/src/Sky3D.gd` + workbench 拷贝 | `sky.environment` 加 `if sky:` 保护。编辑器重启后未再复现 |
| MultiMesh 变量遮蔽 | `maps/construction/MM_Packs/mm_init.gd` | 局部 `basis` → `xform_basis` |
| 预览时间钉死 | `maps/construction/WorldEnvironment.tscn` | 仅影响预览 |
| 测量工具 | `tools/measure_draw_calls.gd` | 固定机位（地面/俯瞰）输出 draw call 与图元数，含阴影开关与阴影距离对照。命令行驱动，不受窗口焦点影响 |

### 实测（tools/measure_draw_calls.gd，同机位）

| 配置 | 地面 | 俯瞰 |
|---|---|---|
| 基线 | 1335 | 919 |
| + 距离剔除 | 1311 (-1.8%) | **782 (-15%)** |
| + 阴影距离 100→55 m（production 值） | **1022 (-23%)** | 631 |
| 阴影全关（参照） | 468 | — |

**关键发现：阴影 pass 占地面视角 draw call 的 64%**（1311 − 468 = 843）。
阴影距离 100→55 m 单项 -289（-22%），属于光照阶段的最大杠杆。

### 调查后否决的方案

- **扩展 MultiMesh 批处理**：258 个可批处理实例分布在 214 个 64 m 格里（多数类型 1 实例 1 格，
  如 11 个线缆卷散布 11 格），64 m 格只能省约 44 个 draw call，且需新写生成器 + 重写 313 KB
  场景。工具 `tools/build_mm_packs.gd`（analyze/apply 两模式）已写好备用，未 apply。
  附带查证：541 个"类型已有 pack 但仍是原始实例"的实例与 pack 内容**位置零重叠**，
  上游是有意为之（聚堆的合批、散置的保留），无双重渲染 bug。
- **`ground_runtime.gd:24` 改用命名枚举**：`set_mode(3)` = `FULL_GAME`，合法；警告文本暗示
  该枚举在脚本 reload 时可能未注册，改常量有升级为硬报错的风险，不改。
- **anisotropic_filtering_level 提到 16**（清晰度修复的一部分）：**该定制 Godot 4.7.2 build 的
  D3D12 路径在 aniso ≥ 8 时必触发 `DXGI_ERROR_DEVICE_REMOVED (0x887a0005)`**，aniso 4 正常
  （client 工程默认值 1 也正常，Vulkan 下 16 也正常——GPU 硬件无损，是 build/驱动 bug）。
  实测：16 崩 / 8 崩 / 4 正常。**本项目在该 build 上 aniso 上限为 4**，已回退 4。
  "稍远就糊"由 2048 贴图上限缓解；`Terrain3DMaterial.mipmap_bias` 语义未查证（扩展内无
  GDScript 源），未盲设。

### 构建环境备注

`addons/terrain_3d/bin/` 会堆积 Godot 加载 GDExtension 时的 `~libterrain*.TMP` 临时拷贝
（每次编辑器启动留一个，约 4 MB/个），堆积后可致后续进程 DLL 拷贝失败、构建报
"map-import reported engine errors"。2026-09-15 已清理 31 个。必要时可在
`bootstrap.ps1` 加清理步骤。

### Blockers

无（本里程碑已完成）。下一里程碑（光照）待用户启动。

### Pending（下一里程碑：全局光照，按用户排序）

1. 阴影距离 100→55 m（对齐 production balanced）：实测地面 -289 draw call
2. `VisualEnvironment` 已有的其余调优项按需对齐预览
3. 地面材质进阶（如需）：`uv_scale`（现 8 m 循环）、补 splat 贴图
4. 84 个独立 `Decal` 合并/烘焙

### Next

向用户汇报实测结果与截图，等待光照阶段启动。
