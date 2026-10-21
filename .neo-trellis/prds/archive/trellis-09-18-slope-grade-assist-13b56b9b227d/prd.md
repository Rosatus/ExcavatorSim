# Slope grade assist + assist-layer modularization

## Goal

在既有平地末端辅助（bucket_level）之上新增**修坡辅助**：操作者以沉浸式实时调节输入坡度角与坡脚距离，待确认期间地形上闪烁显示"本次修坡将削去的土壤"；确认后回转/大臂/铲斗输入全部禁用，仅 W/S 小臂通道驱动齿尖沿舱向轴平移，三关节自动协调使齿尖始终贴合目标剖面、铲斗姿态保持对地角度。同时为两类辅助抽取共享求解器与控制中层，做到"贴合一个面"类辅助不再重写同一代码。

## Requirements

### 目标剖面语义（已与用户确认）

- 剖面定义在**舱向竖直面**内：齿尖水平位置投影为原点，底盘朝向水平投影（`ctx.horizontal` 同义）为轴，s = 沿轴有向距离。
- 距齿水平距离 `d` 处为**坡脚**（slope toe），坡脚高度 = 该点**地形高度**（`terrain_state.sample_surface_bilinear_at`；voxel 区内走碰撞 raycast）。
- `s >= d` 段：`h(s) = h_toe + tan(θ)·(s - d)`，θ 支持正负（正=向远升坡修堆坡，负=向远降坡开坡道）。
- `s < d` 段（靠近机身侧）：水平面 `h = h_toe`——拉近穿越坡脚自动过渡。
- 铲斗姿态设定 = 激活时刻锁存的对地姿态角（与平地辅助同语义，非坡面相对角）。

### 交互（沉浸式实时调节，用户已选定）

- 新 InputMap action `operator_slope_assist`（T 键）+ 菜单入口进入修坡模式。
- **预览态**：整机指令冻结（工作装置+履带均不可动），W/S 连续调距离 d、A/D 连续调坡角 θ；削土体积实时闪烁 + UI 显示参数与预计削方量；Enter 或再按 T 确认，Esc 取消。
- **激活态**：swing/boom/bucket 通道锁零，W/S = 沿轴平移意图（W 推远沿坡上行、S 拉近下坡过坡脚转平地）；Esc/再按 T/手动关闭退出。
- 激活时若齿不在目标面上：有界修正通道自动把齿滑上目标面（复用现有语义，无特殊处理）。
- 与 bucket_level **互斥**（exclusive_group）：开启任一自动关闭另一个。

### 预览

- 可达域：三关节限位网格 FK 扫描（复用 `KinematicArticulationState._compute_frames`，新增公有 `frames_for_positions`），齿尖投影到舱向轴得 `[s_min, s_max]`。
- 削土区域 = 带区（s∈[s_min,s_max]，横向半宽=斗宽/2）内**地形表面高于目标面**的部分；体积 = Σ max(0, terrain − target)·cell_area。
- 可视化：`slope_cut_preview_visual.gd` Node3D 持 ArrayMesh 楔体（顶=采样地形面、底=目标剖面、带宽侧边），半透明脉冲材质闪烁；参数变化时重建（限频）。
- 地形采样走 Callable 注入：生产接权威查询（voxel 区内 raycast / 区外 bilinear），测试喂合成高度场。

### 模块化重构（行为零变化为验收线）

- 新增 `assist_rate_solver.gd`：从 `bucket_level_assist` 抽出 DLS + 积分器精确反演（accel/jerk 可达区间 ∩ 有效上限 ∩ 位置/制动界 → 统一缩放）+ 动量/限位堵死分类 + 病态条件限速。返回结构化 `{commands, scale, blocked}`，flag 命名留各 stage。
- 新增 `guided_profile_stage.gd`（抽象中层，extends EquipmentAssistStage）：step() 完整控制律——死区/上升沿锁存、误差窗口钳制、Jacobian 构建（up/horizontal/pitch × 3 关节）、任务空间速度阻尼、底盘前馈、期望向量组装、堵死策略（kinematic→relatch / momentum→hold）。钩子：`_surface_target(ctx)->{height,grade}`、`_intent_axis(ctx)`、`_attitude_target(ctx)`、`_latch_payload(ctx)`。
- `bucket_level_assist.gd` 瘦身为 thin concrete（surface=锁存常高）。
- `slope_grade_assist.gd`：surface=profile 查询，`writes_mask = MASK_WORK_EQUIPMENT | MASK_SWING`（swing 写零）。
- `EquipmentAssistStage` 增 `exclusive_group` 字段 + `apply_params(dict)` 运行时参数口。
- `EquipmentAssistPipeline`：注册两个 stage、互斥组语义、`set_stage_params`。

### 接线

- `kinematic_articulation_state.gd`：`frames_for_positions(positions)` 公有包装。
- `jolt_chassis_track_runtime.gd`：`set_equipment_assist_params` 链 + `update_slope_preview(params)->Dictionary`（FK 扫描+地形采样，内部限频）。
- `tracked_chassis_controller.gd`：预览态状态机（输入重路由+整机冻结）、T 键注册、激活态挂 stage。
- `product_session.gd`：`request_slope_preview/confirm/cancel` + status `slope_assist_state`/`slope_preview`。
- `operator_ui.gd` + `operator_menu_controls.tscn`：修坡面板（参数读数、削方量、按键提示、确认/取消）。
- `assist_profiles.json`：`slope_grade` 参数节（复用 level 字段 + 调节速率/预览网格参数）。

## Acceptance Criteria

- [x] 重构后 `bucket_level_assist_test.gd` 全部断言不变通过（行为零变化，逐位一致）。
- [x] `slope_profile` 纯数学单测：分段 height/grade/along/toe_world、正负坡（含在 slope_grade_assist_test 内）。
- [x] `slope_grade_assist_test.gd` headless：齿尖贴面轨迹稳态 <0.05m（空中剖面，无土）、姿态 <0.02rad、坡脚过渡、swing 通道锁零、无 profile 拒绝 enable、互斥组落平地、预览 band/体积断言。
- [x] 预览计算单测：合成地形 sampler 注入，band 边界/体积/最大深度断言正确。
- [x] 回归：`equipment_command_mapper_test`、`cut_resistance_test`、`jolt_chassis_track_test` PASS。
- [ ] 手感人工验收：预览闪烁直观性、W/S-A/D 调节速率、激活后贴面/坡脚过渡、退出链路。

## Implementation Notes

### 落地与计划稿的差异

- **Enter 确认改走内置 `ui_accept`**：`operator_slope_assist` 只绑 T；Enter 仅在预览态被解释为确认——OFF 态按 Enter 不会意外入场。
- **参数读数用 `Label3D` 挂在预览楔体上**（世界空间、随预览消亡）而非菜单面板文本——菜单收起时仍可见，符合"沉浸式"。菜单 Tools 行另有 `SlopeAssist` Button 显示三态（修坡/预览/作业）。
- **session API 定稿为 `advance_slope_assist()` / `cancel_slope_assist()`**（镜像 T/Esc 语义）+ status `slope_assist` 字典（state/distance/angle/volume/toe）。
- **`profile_params` 上移到 `EquipmentAssistStage` 基类**：非控制参数（调节速率、预览网格）供预览状态机回读。
- **`slope_grade.set_enabled(false)` 只在真实 enabled→disabled 跃迁时清空 profile**——互斥组给未启用的兄弟 stage 发 disable 时不能吃掉刚注入的剖面（否则 level→slope 切换顺序下 enable 永远被拒绝）。
- **预览地形采样**：`terrain_state.sample_surface_bilinear_at`（与切削探针同一 heightfield），网格外下行 raycast mask=1。
- **`frames_for_positions` 公有包装**开在 `KinematicArticulationState`（预览 FK 扫描不污染 accepted 状态）。

### 实施中发现/修复

- **测试侧 `_command_identity` 回退陷阱**：`set_equipment_commands(commands, identity)` 的 identity 必须单调递增；测试在 settle 数百 tick 后重置计数器会使后续指令被当成陈旧命令静默丢弃（症状=整机冻结、零 flags）。修坡测试不重置计数器。
- **无 ExcavationWorld 的 fixture 中地形不屈服**：目标面锚在地面高度时齿尖被未切土顶住 ~0.3m——属土壤物理非跟踪缺陷；stage 测试改为穿过当前齿位的空中剖面（纯运动学契约）。
- **sy205 深收臂位形进入病态限速区**（继承自 solver 的 rate conditioning）：~3cm/s 物理爬行是特性非缺陷；测试位形避开深收区，进度断言只证"能平移"。
- **DLS 矩阵转置修正**：抽取 solver 时 `solve_dls` 初版误用 `J·w`（行点积）代替 `J^T·w`（列点积），平地回归立即捕获——验证矩阵是验收网兜。
- **互斥/profile 时序 bug**（见上）：apply_params 注入后若 slope stage 收到兄弟 enable 的互斥 disable，profile 被误清。

### 已验证测试输出

```text
sy135 slope drive: s=1.319 m, peak surface err=0.0000 m, peak pitch err=0.0018 rad
sy135 toe return: s=0.116 m, bench err=0.0000 m
sy205 slope drive: s=0.390 m, peak surface err=0.0000 m, peak pitch err=0.0029 rad
sy205 toe return: s=0.390 m, bench err=0.0142 m
slope_grade_assist_test: PASS
bucket_level_assist_test: PASS（数值与重构前逐位一致）
```

### 遗留

- 预览楔体的视觉验收（闪烁节奏、侧壁、Label3D 可读性）需人工场景确认。
- `operator_ui.gd` 的改动与并行 menu-theme 任务在同一文件——提交时需 hunk 级分离。

## Notes

- Godot 可执行文件：`E:/applications/godot_voxel/godot.windows.editor.x86_64.exe`。
- 权威地形高度查询：`terrain_state.sample_surface_bilinear_at(world_xz)`；voxel 区内 `VoxelZone.owns_world_xz` 为 true 时需走碰撞 raycast（参照 `_heightfield_support_hit` dispatch 模式）。
- 键位：G=平地辅助、T=修坡（H 已被右履带占用）；预览态 W/S=距离、A/D=坡角（整机已冻结，工作装置键可复用）。
