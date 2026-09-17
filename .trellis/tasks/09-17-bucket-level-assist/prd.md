# Bucket level assist pipeline

## Goal

在 `jolt_authoritative` 默认链路中加入"末端辅助控制"：开启后大臂（I/K）与铲斗（J/L）输入被完全接管禁用，仅保留回转（A/D）与小臂（W/S）；W 推远、S 拉近铲斗，系统自动协调 boom/arm/bucket 三关节，保持铲斗齿尖对地高度与对地姿态角不变。架构上做成可扩展的指令整形流水线，后续深度限制/虚拟墙等 governor 类辅助可直接挂入。

## Requirements

- 新增 `EquipmentAssistPipeline`（RefCounted）：有序 stage 执行、channel mask 校验、neutral 闸（操作输入为零且无人声明 hold 时输出强制为零）、多 stage scale 取最小合成、status/flags 聚合。
- 新增 `EquipmentKinematicsContext`：每 tick 构建一次，提供关节世界系铰轴/铰点、铲斗参考点（soil contract cutting_edge，缺省回退 bucket_link origin）、公共俯仰轴、水平外展方向、有效速度上限（vmax×load_factor）、切削/限位预测系数。
- 新增 `EquipmentAssistStage` 基类：enabled/writes_mask/holds_at_neutral 契约 + configure/reset/step/status。
- 新增 `BucketLevelAssist`（modulator）：任务空间 3×3 速率解算（竖直/水平/俯仰），DLS 奇异位形降级，P 反馈锁存 h_ref/θ_ref，输入空闲时输出为零并重锁存；可行性统一缩放（预除 cut/limit 逐关节乘子，保任务空间方向）。
- `JoltChassisTrackRuntime` 持有 pipeline：`_build_rig` 时以 descriptor+soil_contract+model_id 配置；`_update_joint_actuators` 内在 `propose_step` 前将 `_equipment_commands` 变换为有效指令；`teardown/reset/stop_motion` 重置；status snapshot 暴露 `assist_pipeline`。
- `TrackedChassisController`：`@export level_assist_enabled`、`set_level_assist_enabled` 透传、`operator_level_assist` 热键（G）注册与轮询。
- `ProductSession.request_level_assist` + status 字段；`operator_menu_controls.tscn` Tools 行新增 `末端辅助` CheckButton；`operator_ui.gd` 绑定/sync/`get_control_for_test`/tooltip。
- 参数资源 `resources/physics/assist_profiles.json`（schema `assist-profiles-v1`，按 model_id 分档：三个模型同值起步）。
- 不改动 `EquipmentCommandMapper`、hash 锁定资源、InputMap 既有绑定、Python 侧；compat profiles 不受影响（assist 只在 jolt runtime 内）。

## Acceptance Criteria

- [x] `tests/bucket_level_assist_test.gd` headless 通过（已实跑）：sy135 驱动 90 tick 行程 0.63m，**全程峰值**高度误差 <0.05mm / 姿态 0.00001rad；sy205 峰值 0.1mm / 0.00002rad（容差收紧至 0.015m/0.015rad）；零输入零输出；禁用透传（arm 动、boom 不动）；assist 开启时 boom/bucket 操作输入被完全忽略（关节不动）；近限位/奇异位形下有界且**反向输入立即恢复运动**；I/K/J/L 不再改变设定值——设定值在输入空闲/启用瞬间/不可行 tick 时锁存。
- [x] pipeline 级断言覆盖 neutral 闸（零输入→零输出）与 mask 越权剥离（swing-only 输入不被 stage 吃掉，stage 未声明 swing 写入）。
- [x] 既有 `equipment_command_mapper_test`、`cut_resistance_test`、`jolt_chassis_track_test` 全部 PASS（实跑）。`operator_ui_test` 在本环境与无改动基线同样失败（"did not publish soil timing"），为既有问题且已在 `run_standalone_matrix.ps1` 中注释为 pre-existing。
- [ ] 手感由人工验收（按 validation-budget）：W/S 推拉的速度感与方向、I/K/J/L 被禁用是否符合预期、A/D 回转不受影响、到限位/奇异位形时应**干脆停住且反向输入立即恢复**（用户选定的语义，见实现注记）。

## Implementation Notes

- 交付结构：`equipment_kinematics_context.gd`（每 tick 共享世界系 FK/预测系数）、`equipment_assist_stage.gd`（mask/holds_at_neutral 契约基类）、`equipment_assist_pipeline.gd`（有序执行 + mask 剥离 + neutral 闸 + min-scale 合成 + status 聚合）、`bucket_level_assist.gd`（3×3 DLS 速率解算 + 有界 P 反馈 + 限位即停 + 可行性统一缩放）。
- `JoltChassisTrackRuntime` 在 `_build_rig` 中 configure pipeline（descriptor + soil_contract + model_id），`_update_joint_actuators` 内 `set_cut_resistance` 之后、`propose_step` 之前变换指令；`stop_motion/teardown` 调 `pipeline.reset`；status snapshot 暴露 `assist_pipeline.stages.bucket_level`（height_error_m / attitude_error_rad / feasible_scale / flags）。
- 开关链路：菜单 `末端辅助 (G)` CheckButton 或 G 热键 → `ProductSession.request_level_assist` → `TrackedChassisController.set_level_assist_enabled` → `JoltChassisTrackRuntime.set_equipment_assist_enabled("bucket_level")`。状态以 chassis 为准回流到 session/UI。
- 语义按用户反馈修订：assist 开启后 boom/bucket 输入被完全忽略（禁用），仅保留 swing + W/S 水平推拉；设定值不再由 I/K/J/L 调整。
- 修复"动一下就不动"的根因：原先的饱和冻结是**锁存式**的——W 起步瞬态误差冲过阈值后，按住不放会永久冻结。
- 限位语义按用户拍板采用"每 tick 判定、任一关节堵死即整体停"（第三方案，非锁存）：`_rates_to_commands` 发现所需关节在求解方向上不可动 → 该 tick 三轴输出零 + `level_assist_infeasible` flag；同时 `step()` 在不可行 tick 把设定值锁存到实测位姿——修正项清零后下一 tick 退化为纯前馈，输入反向则全部关节速率反向，保证"来路永远可退"，不会卡死在死角。曾评估过"堵死关节剔除重解降级续行"方案，用户选择停住而非漂移。
- 精度升级（"外挂级"跟踪）：`_rates_to_commands` 改为**积分器精确反演**——每关节本 tick 可执行速度区间 = accel/jerk 可达步长 ∩ cut/限位缩放后速率上限 ∩ 硬限位位置界，三关节统一缩放使目标速率全部落在区间内 → 执行步进与指令方向逐位一致；ctx 新增 `chassis_point_velocity`/`chassis_hinge_rate` 前馈，齿尖保持改为对地坐标同帧补偿（而非靠反馈延迟一拍追底盘晃动）。配套调参：λ 0.08→0.02、增益 4/5→10/12 Hz。代价是模型耦合：propose_step 执行语义变更须同步 `EquipmentKinematicsContext` 的镜像方法（已写入 spec/frontend/model-joint-semantics.md）。
- 近限位"高度/角度突变"的诊断与修复（`bucket_level_diag_test.gd` 逐帧取证）：根因是三层叠加——① 硬位置界只防超调不减速，关节带速撞限位后其余关节各自残速滑行（无组织滑行=突变）；② sy205 深回收位形存在运动学换向点（toggle），求解合法地翻转关节方向，关节带着反向动量到达 → 判 infeasible → 滑行 10-20 tick → 每次 infeasible 的 `_latch` 把滑行漂移**追认成新设定值**形成棘轮，累积 5°/9cm；③ 保持通道只有 P 刚度无速度阻尼，修正项在换向区驱动 ~1Hz 极限环。修复：a) 制动定律软着陆 `v≤k√(2·a_max·d)`，到站速度≈0（sy135 归零漂移）；b) 堵死分类——运动学界堵死（真限位）报 `level_assist_infeasible`+锁存，纯动量符号冲突报 `level_assist_reversing`+保持设定值（反馈把滑行偏移拉回而非追认）；c) 病态条件限速——DLS 速率范数>1.5 时按比例收缩各关节速度上限，换向点以 ~0.1rad/s 爬行通过；d) 保持通道（高/俯）加 J·v0 任务空间速度阻尼（水平意图通道不动），极限环振幅从 ±0.075rad 压到 ±0.03。实测：sy205 限位段单帧峰值跳变 0.0021m/0.0012rad（旧 bug 0.009/0.005，断言界 0.004），sy135 <0.0002；恢复位移 sy205 120tick 0.39m（深奇异区固有爬行速 ~3cm/s，恢复断言窗口相应放宽至 120tick）。
- `assist_profiles.json`（schema `assist-profiles-v1`）：default + sy135/sy205/sy135neo 同值起步；per-model 调整只动 JSON。

## Notes

- 设计结论见会话评估：伺服级功能必须贴 Godot 积分器（cut_engagement/accepted_fraction/限位软化只存在于本地），Python/Pinocchio 仅适合未来低频 setpoint 规划层；assist 的 h_ref/θ_ref 以可写 setpoint 形式预留该扩展口。
- Godot 可执行文件：`E:/applications/godot_voxel/godot.windows.editor.x86_64.exe`（toolchain 以 `tools/godot_voxel_toolchain.json` 为准）。
