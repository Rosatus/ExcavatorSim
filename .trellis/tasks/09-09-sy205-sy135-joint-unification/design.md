# 技术设计

## 统一语义，保留几何适配

沿用 operator → command mapper → kinematic articulation → accepted FK → presentation/telemetry。SY135 现有 q 是基准，不重新定义它。

SY205 使用相同逻辑 q，模型变换吸收资产方向与必要中性位差异：`q_asset = s*q_common + offset`，`v_asset = s*v_common`。offset 不是 gateway 假角度，不能在输入、可视和遥测各转换一次。

优先用 rig 已有 axis/anchors/rest 表达适配，不增加运行时模型分支。loader 接受单位轴（`physics_rig_descriptor.gd:252-257`）；FK 为 `parent * parent_anchor * rotation(axis,q) * inverse(child_anchor)`（`kinematic_articulation_state.gd:_compute_frames`）。SY205 工作装置 -X 轴是方向适配候选，必须与 signs 成对验证；必要 neutral offset 保持 rest closure 和 pivot origins。

## 统一维护入口

以现有 SY135 rig 为只读数值来源，增加小型确定性同步/check 工具，仅刷新 SY205 共享关节字段及 catalog hash。保留 SY205 几何、质量、履带、轴向适配；必要限位修正集中声明，不散落 controller。无需通用继承框架。

canonical profile 的 SY135 条目不变；SY205 对齐逻辑坐标 signs，使用现有 `backend/scripts/sync_equipment_command_profile.py` 同步 Godot 副本/SHA。共享 SHA 变化是允许的元数据变化，不允许 SY135 行为变化。

速度/加速度/jerk 已同值；torque/damping 可随基准收敛，但当前积分未使用它们，不宣称液压动力学改进。

| 关节 | SY205 当前资产 q | SY135 基准 q |
|---|---|---|
| boom | [-15°,45°] | [-25°,45°] |
| arm | [-45°,30°] | [-60°,45°] |
| bucket | [-95°,30°] | [-45°,45°] |

先确定 s/offset，再验证基准行程。以上不是世界倾角或 QML 绝对角；不能逐端点盲抄。小幅端点调整只为避免翻折、连杆无解或无法卸料。

## 保护区

SY135 rig、visual manifest、golden fixtures 保持不变，禁止重录期望值掩盖回归。以下链路只读：

- `can_telemetry_bridge.gd:677-715` 的真实 global frame/相对回转来源。
- `tools/can_gateway/conventions.py`：SY135 累积 rest 补偿 +35/-20/-95，不等于 local rest +35/-55/-75。
- `qml_compat.py`、`qml_profile.py`、SY135 profile/calibration：QML neutral 35/90/130，对应 renderer local 35/-90/-50。
- `gateway.py`、DBC、编码和 CTN1 协议。

SY205 保持自己的身份和真实 frame 输出，不获得 SY135 专有 QML 标定。SY205 运动变化自然改变其真实输出，不需要改 gateway 算法。

## 兼容性与风险

canonical profile 也被 Python compatibility runtime 使用。实施需同步检查 SY205 URDF/模型坐标消费者，禁止 Godot 改新方向而 Python 仍用旧方向；优先数据适配，不改 SY135 或 gateway 业务链路。若无法在边界内保持兼容，回到方案评审，不能静默破坏兼容模式。

重点核验双重符号转换、零位混淆、连杆可达性、bucket opening/卸料可达性、hash 漂移。共享积分中负向切削减速假设也需检查，但不得借机改变 SY135 行为。

当前工作区含其他任务改动。实施前记录保护文件当前字节/hash和 baseline，不以 HEAD 覆盖用户现状；回滚仅针对本任务新增工具/测试和 SY205 数据/生成物。


## 2026-09-09 user follow-up

SY205 bucket proxy alignment, geometry exception [-20,95] degrees, zero spawn yaw and +Z-aware external cameras implemented. See followup-result.md for revised evidence and pending manual acceptance.
