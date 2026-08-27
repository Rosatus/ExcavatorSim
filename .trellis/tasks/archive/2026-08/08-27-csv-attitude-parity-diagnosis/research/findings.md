# CSV Attitude Parity Findings

## Executive Finding

Godot -> CSV -> `_replay` -> QML parser 的工作装置 pitch 字段链在当前样本中一致；对全部 5770 帧的直接序列化核验也没有发现 CAN ID、DLC 或 payload 改写。实测方向不一致不是 `_replay` 主 PC001 路径或瑞芬 IMU remap 导致。

当前确认有两个 gateway 方向合同问题：`basis_forward_from_quat()` 取了本地 `+X` 而不是 Godot forward `-Z`；RTK 主位置/heading/velocity/副天线全部取固定下车 `chassis`，而参考 GNSS 标定与 QML 3D guidance 合同要求 RTK frame 随上车回转。后者会丢失样本中的 `197.02 deg` slew，即使只修 `+90 deg` 也无法闭环。

当前 CSV 没有双端运行时 model transform，不能证明最终模型 pose 一致。QML 3D 正常算法路径也只有一个 world heading，不同时表达下车 heading 与上车相对 slew；最终验收必须先确定比较 guidance frame，还是扩展 QML 以支持完整 chassis/upper 双 yaw。

## Input And Coverage

- CSV：`godot/dist/windows/output/can_gateway/can_telemetry_20260827_082941.csv`
- 编码：UTF-8 BOM
- 行数：5770
- 时间：`08:29:41.149 -> 08:29:57.181`，约 `16.032 s`
- 主要帧：
  - `0x18FF3A00` body IMU：802
  - `0x18FF3B00` boom IMU：802
  - `0x18FF3C00` arm IMU：802
  - `0x18FF3D00` bucket IMU：802
  - `0x18FFF000` slew：802
  - `0x0CFDA900` RTK heading：160

复现脚本：`research/analyze_csv.py`。

## Heading Result

QML 使用 `canManager.rtk_heading`，来源为 RTK 帧 `0x0CFDA900`：

- first：`90.00 deg`
- last：`105.86 deg`
- unwrapped delta：`+15.86 deg`

body IMU yaw（`0x18FF3A00`）：

- first：`0.00 deg`
- last：`-15.86 deg`
- unwrapped delta：`-15.86 deg`

因此样本期间的物理航向变化幅值为 `15.86 deg`。样本同时满足：

```text
rtk_heading = (90 - body_yaw) mod 360
```

符号相反来自现有 yaw/heading 约定；额外的 `90 deg` 是需要修复验证的固定轴偏差。

## Attitude Data Path

瑞芬 payload slot 解码：

```text
slot = uint16_le * 0.01 - 180
parser output = (roll=s1, pitch=-s0, yaw=s2)
```

gateway encode 侧生成 slots=`(-pitch, roll, yaw)`，所以 parser remap 后 QML 收到的 `(roll, pitch, yaw)` 与 gateway 输入参数一致。

sy135 安装补偿：

```text
boom   +35 deg
arm    -20 deg
bucket -95 deg
```

Godot 世界 elevation 可按以下关系离线还原：

```text
elevation = compensation - parser_reported_pitch
```

观测样本：

- body roll/pitch 约为 `0 deg`
- boom reported pitch：`0.00 -> -23.28 deg`，还原 elevation：`35.00 -> 58.28 deg`
- arm reported pitch：`35.00 -> 34.36 deg`，还原 elevation：`-55.00 -> -54.36 deg`
- bucket reported pitch：`10.00 -> 36.07 deg`，范围 `-9.19 .. 72.49 deg`

完整复刻下游 `Sensor2Ang`：

```text
first: boomPhi=-0.58, armPhi=144.34, bktPhi=49.47
last:  boomPhi=22.70, armPhi=121.70, bktPhi=-13.32
```

这支持工作装置 pitch 数据链路正常。QML 关节角算法不消费 link yaw/roll。此前脚本漏把 parser-reported body pitch 传入 `Sensor2Ang`，从而漏掉 `roll_error_IMU_Car=1.0475 deg` 对 `boomPhi` 的影响；任务内脚本已修正。

## Replay Input/Output Semantics

以实录 CSV 直接调用参考仓 `tools.can_replay.csv_parser.read_can_csv()`，再调用 `pc001_server.pack_can_frame_raw()`，逐行与原 CSV 比较：

```text
frames=5770 parse_mismatch=0 pack_mismatch=0
extended=5610 channels=[3]
```

相关姿态帧在主 `send`/PC001 路径中保留原始行序、29-bit ID + `CAN_EFF_FLAG`、DLC 和前 DLC 个 payload 字节，不做单位、符号或字节序转换。回放器仍会丢弃 CSV 的传输方向/帧类型语义，重写为相对时间并执行 speed/batch/repeat；vcan/bridge 路径还会丢失 channel。这些限制不解释本次单 CAN3 姿态字段差异。

## Slew And Euler Interpretation

slew 帧 `0x18FFF000`：

- first：`0.00 deg`
- last：`197.02 deg`

boom/arm/bucket 是世界姿态，所以上车回转时其 yaw 会随 slew 跨越 `+/-180 deg`。这些 yaw 不是 chassis heading，不能拿来与 QML 的 RTK heading 做一对一比较。

bucket 接近竖直并叠加 slew 时，Euler 分解的 roll 出现 `0/+/-90 deg` 跳变。这是接近奇异姿态时的表示现象。因为当前 `Sensor2Ang` 只读取 pitch，该现象不是本次整机朝向差异的直接原因。

## Confirmed Direction Contract Defects

位置：`tools/can_gateway/conventions.py::basis_forward_from_quat()`。

函数文档声明返回 Godot forward，即本地 `-Z` 轴；当前公式却是四元数旋转矩阵第一列，对应本地 `+X` 轴：

```text
(1-2(yy+zz), 2(xy+wz), 2(xz-wy))
```

项目 Godot 车辆代码使用 `-basis.z` 作为 forward，例如：

- `godot/client/scripts/jolt_chassis_track_runtime.gd`
- `godot/client/scripts/tracked_chassis_controller.gd`

候选的 `-basis.z` 公式为：

```text
(-2*(x*z+w*y), -2*(y*z-w*x), -(1-2*(x*x+y*y)))
```

identity quaternion 下：

- 当前函数返回 `(1, 0, 0)`，即 east/right
- 契约预期返回 `(0, 0, -1)`，即 north/forward

这与 CSV 中 RTK heading 固定多出 `90 deg` 的表现一致。

第二个缺陷是 RTK source frame。`MachineState.geodetic()`、`heading_degrees()`、`velocity_enu()` 和 `vice_antenna_geodetic()` 都读取 `sample.bodies["chassis"]`。参考工程则用回转过程中的 GNSS 天线轨迹拟合回转中心，并把“GNSS 天线到回转中心”偏移随 RTK heading 旋转；3D QML 也把 RTK heading 当作 O 点处上车/工作装置的 world heading。固定在下车的 chassis 不会因上车回转而产生这条轨迹，因此当前 source frame 与参考合同冲突。

样本末帧进一步支持这个判断：

```text
body yaw = -15.86 deg
slew = 197.02 deg
boom/arm/bucket world yaw = -178.84 deg
wrap(body yaw + slew) = -178.84 deg
```

工作装置 world yaw 明确包含 slew，而当前 RTK heading 只跟随 chassis。只替换 forward 公式会去掉固定轴偏差，但仍会遗漏上车回转。

## Impact Surface

方向/source-frame 修复不只影响 heading。后续 agent 应搜索并验证全部调用方，当前已知包括：

- `heading_degrees()`：RTK heading / QML 整机朝向
- `velocity_enu()`：由 forward 推导 ENU 速度
- `vice_antenna_geodetic()`：由车辆朝向推导副天线位置

仅在 QML 加减 `90 deg` 会保留速度和副天线方向错误，不是推荐修复。

参考 UI 称主天线为右天线、副天线为左天线；gateway 当前却把副天线放在 heading 反方向、默认相距 1 m。参考仓没有找到明确 baseline 数值和左右符号，必须补合同，不能把当前假设当作既定事实。

## Final Pose Evidence Gap

- CSV 只有 gateway 输出 CAN bytes，没有 Godot authoritative/post-step transform、QML parser runtime trace 或 QML node world transform。
- Python `analyze_csv.py` 复刻的是 parser 与 `Sensor2Ang` 数学，不是参考二进制或 QML 运行时观测。
- QML 3D 的正常 `setAlgorithmData()` 把唯一 `bodyHeading` 写入 root，并把可用于相对上车旋转的 `bodyAngle` 清零；`slew_angle` 只出现在状态栏。它不能同时保留下车 heading 与上车相对 slew。
- 因此严格 pose parity 需要同 source sequence/tick 的双端 trace，并先定义可比较 frame。完整证据矩阵见 `research/cross-repo-pose-parity.md`。

## Independent Defects Outside The Main PC001 Replay Finding

- `tools/can_gateway/sinks.py::pack_can_frame()` 使用 `can_id & 0x7FF`，使直接 SocketCAN/TCP sink 的 29-bit 扩展 ID 无法被参考 parser 命中；CSV sink 和 `_replay` 主路径不受此问题影响。
- 参考 `ProtocolParser::parseDxingSlewPDO()` 把 raw `uint16` 直接赋给 angle，与注释/测试的 `0..65535 -> 0..360 deg` 合同冲突；它影响 2D guidance，不是当前 3D RTK 主路径的解释。

## Required Verification

1. 为 identity quaternion 建立契约测试：forward=`(0,0,-1)`，north=`-Z`/east=`+X` 时 heading=`0 deg`。
2. 为正负 Y-up yaw 建立方向测试，验证 heading 的符号、wrap 和与 body yaw 的关系。
3. 验证 ENU velocity 在 identity 和 yaw 旋转下沿预期 north/east 方向。
4. 验证副天线偏移在 identity 和 yaw 旋转下落在正确地理方向。
5. 运行现有 gateway 测试，确认瑞芬姿态、安装补偿和 `Sensor2Ang` 无回归。
6. 重建目标平台 gateway，用 Godot/QML 同场景确认固定 `90 deg` 偏差消失。
7. 为 RTK source frame 建立“chassis 不动、upper 纯 slew”的测试，要求 A900 heading 与主/副天线位置按已确认安装合同变化。
8. 以同序号记录双方 root/link/bucket-tip transform，按最终选定的 frame 边界做刚体比较，而不是只比 Euler 数字。

## Handoff State

- 跨仓诊断和回放逐帧核验已落盘。
- 未修改产品代码。
- 未运行 `task.py start`。
- `research/analyze_csv.py` 已修正 body pitch 标定遗漏。
- 任务保持 `planning`；等待用户决定完整 mesh parity 或 QML guidance-frame parity，随后才能定稿 `design.md`、`implement.md` 并进入最终规划评审。
