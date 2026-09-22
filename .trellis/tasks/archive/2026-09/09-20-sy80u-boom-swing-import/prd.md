# SY80U 导入 + 动臂偏摆（boom swing）本地自由度

## Context

`E:\projects\blender\Excavator\SY80U\80u_bucket_corrected.blend` 是 SY80U 整机模型，
比 SY135 多一个**动臂偏摆**自由度（摆动支架绕竖直销轴 P5 侧摆，真实机型规格
L 65° / R 51° 非对称）。用户要求按 godot-adapt-articulated-glb 技能导入，
并用 E/U 键控制该自由度。

## Confirmed Decisions

- **偏摆轴 = Godot 本地表现层自由度**，不进 Python `Vector4` 协议
  （协议 4 轴 hash 锁定；规范明确"添加本地运动不得扩展四轴协议"；
  AttachmentRig tilt/rotate 已是同等级先例）。权威 4 轴、rig、URDF、
  parity fixture 全部保持不变语义；偏摆只作用于视觉/土壤切割跟随的
  表现节点。
- **键位**：E = `operator_boom_swing_left`（向机身左侧摆），
  U = `operator_boom_swing_right`（向右摆），限位 [+65°, -51°]（SANY 规格）。
- **部件归属**（几何证据）：bed→底盘；Carbin+pianbai→上车（pianbai 是
  偏摆固定座）；huizhuan+偏摆_销轴及紧固件→摆动支架（绕 P5）；
  arm1→动臂（绕 P6）；arm2→斗杆（P2）；bucket.001→铲斗（P3/P4 tip）。
- 层级：`CTRL_EXCAVATOR_ROOT → PIVOT_SLEW(P1) → PIVOT_BOOM_SWING(P5)
  → PIVOT_BOOM_BASE(P6) → PIVOT_ARM_JOINT(P2) → PIVOT_BUCKET_JOINT(P3)
  → REF_BUCKET_TIP(P4)`；semantic zero 沿用家族契约
  （boom RotX(+35)/arm RotX(-55)/bucket RotX(-105)，世界 -Z 朝前）。
- 原始单位 = 分米（P6→P2 = 35.2u = 3.52m 与规格一致），S=0.1；
  朝前 -Y，绕 Z 转 180° 后到 Godot -Z；动臂偏置在机身右侧 (+X)。

## Design

- `export_godot.py`（SY80U 目录，headless）：重定位 boom/arm/bucket 到契约
  零位，建 6 节点 pivot 链，烘焙网格，导出 GLB + contract_values.json。
- `build_sy80u_assets.py`：GLB→client，manifest（新增
  `local_articulation.axes` 声明 swing 轴 + `via_local_axis` 父子豁免）、
  physics rig（4 关节，8.8t 整机参数）、parity fixture、soil contract、
  fill profile、catalog/registry/provenance。
- `sy80u_reference.urdf`：4 关节权威链（P1/P6/P2/P3），偏摆不入 URDF。
- `MotionPresentation`：解析 `local_articulation`，`_physics_process`
  按速率/限位积分摆角，`rest_local * RotY(θ)` 施加于 PIVOT_BOOM_SWING；
  `via_local_axis` 放宽容差校验；reset/switch 归零。
- 输入链：`EquipmentCommandMapper.LOCAL_INPUT_ACTIONS` 声明 E/U 两 action
  （独立于 INPUT_ACTIONS——绑定测试要求每个权威 action 恰有一个手柄事件）；
  `MotionClient`/`ProductSession.get_local_axis_input(neg, pos)`
  （focused + lifecycle==running 门控）。
- 接线：product_session.MODEL_IDS、mapper alias（sy80u→sy135 signs）、
  operator_ui selector/strings、camera_rig、bucket_fill_surface、
  voxel whitelist、assist/digging profiles。

## Acceptance Criteria

- [x] GLB 通过 inspect_mechanical_glb 与 sy80u_import_probe（含摆轴断言）。
- [x] 6 poses parity 与 URDF fixture 一致；摆轴 E/U 限位 ±规格内
  （sy80u_import_probe + sy80u_switch_smoke 验证符号/限位/积分/复位）。
- [x] 切到 sy80u 后 E/U 平滑偏摆动臂总成（sy80u_session_switch_smoke 全栈通过）。
- [x] reset/model switch 后摆角归零；sy205/sy135/sy135neo 回归 PASS。
- [x] registry/catalog/provenance hash 同步（verify_provenance + 注册表 schema 通过）。
