# 08-26-can-attitude-fix

## Goal

修复 CAN 网关俯仰/横滚通道错位（Y-up 轴系适配）、增加 IMU 零位安装角补偿层、
对齐 SY135 铲斗语义，使下游 dev_arch2.0（零改动）按真机语义解析仿真姿态。

## Background

- 解码权威：`dev_arch2.0/GuideSystem/services/can/protocolparser.cpp`（不可改动）。
  下游现役标定 pitch_error_IMU_Boom=0.4713 / Arm=−0.1928 / Bkt=4.9748。
- 瑞芬 IMU 帧 0x18FF3A00..3D00：三槽 uint16 LE，物理值 = raw×0.01−180°；
  三槽全零 = 无效哨兵。装车重映射（parser:150-191）：车辆 roll=s1、pitch=−s0、yaw=s2。
- 真机金样本语义：连杆 pitch 通道 = 臂杆段方向绝对俯仰取负（抬起为负）；roll≈横向侧倾。
- 回转帧 0x18FFF000：u16 LE，65536↔360°。

### 已实证的问题

1. **P0 欧拉轴系错误**：`conventions.quat_to_zyx_euler_deg` 用 Z-up 航空航天 ZYX，
   Godot 是 Y-up。抬臂 30° → 下游 roll=−30/pitch=0（应为 pitch≈−30）；
   航向转 45° → 进了 pitch 通道；回转 90°+ 抬臂 → (180,90,180) 万向节奇异。
2. **P1 零位安装角差**：仿真 link frame rest 为单位阵（或烘焙旋转），真机 IMU 固连
   臂杆钢面。需在 gateway 内补偿每段常量安装角，下游标定不动。
   - sy205：rest 帧单位阵，段几何烘焙（boom 段 rest 上扬 +47.65°、arm −78.24°）
   - sy135：段几何全水平（沿 −Z），但 rest_transforms 帧含 X 轴旋转
     （boom +35 / arm −55 / bucket −75）→ 补偿 = 段仰角 − 帧前向量仰角
     （boom −35 / arm +55 / bucket +75）
   - 统一公式：`mount_comp[link] = seg_rest_elevation − frame_fwd_elevation`
3. **P2 SY135 铲斗**：bucket_link 必须与被动四连杆 driven_frame 同源；相对 arm 的
   相对角全行程单调；rest 常量差并入安装角表。

## Requirements

### R1 Y-up 姿态分解（P0）
- conventions.py 新增 Y-up 分解：先绕世界 Y 提取 heading(yaw)，再绕水平侧向轴提取
  elevation(pitch)，最后绕纵轴提取 roll（Ry·Rx·Rz 序或等效四元数实现）。
- 符号契约：解析 pitch(link) = −(连杆参考方向绝对 elevation)（抬高为负）。
- sensor_slots() 反演不变；四个 link 调用路径全部切换；旧 ZYX 函数清理/deprecate。

### R2 IMU 安装角补偿层（P1）
- conventions.py 内按模型区分的常量表（程序化推导值钉死 + 测试锁定）：
  - sy205：boom=+47.65、arm=−78.24、bucket=按 tip 推导
  - sy135：boom=−35、arm=+55、bucket=+75（由 manifest rest_transforms 与水平段几何差导出）
- 编码路径：link frame 欧拉 + mount_comp → 等效钢面 IMU。
- README 记录语义、出处（manifest rest 铰点/rest_transforms）、与下游 calibration.toml 成套关系。

### R3 SY135 铲斗一致性（P2）
- can_telemetry_bridge.gd 取的 bucket_link 与 passive_linkage.driven_frame 同源校验；
- bucket 相对 arm 相对角行程单调无跳变（sy135 rest 单位旋转已并入 P2 表——实测
  sy135 bucket_link rest 旋转 −75° 已含于安装角表）；
- parity fixture 新增 bucket 行程 case，钉死 q ↔ CAN byte 映射。

## Acceptance Criteria

- [ ] 纯抬臂 30° → 解析 pitch=−30±0.01，|roll|、|yaw|<0.01
- [ ] 纯航向 45° → 解析 yaw=45±0.01，|pitch|、|roll|<0.01
- [ ] 回转 90°+抬臂 30° → pitch≈−30、yaw≈90，无奇异跳变
- [ ] rest 姿态全零 → 下游标定解算 boomPhi≈47.6±1、armPhi≈30.6±1、bktPhi≈rest 真值±2（sy205）
- [ ] 回转帧、行走压力帧、RTK 族不回归；golden_capture 经新编码器逆运算还原槽位分布
- [ ] README 关键约定更新三条契约
- [ ] 只改 ExcavatorSim 仓库；UDP 包结构/CAN ID/分频/sink 行为不变

## Non-goals

- 改动 dev_arch2.0 任何文件
- 改动 UDP 包结构（176B CTN1）、CAN ID 分配、分频策略、sink 行为
