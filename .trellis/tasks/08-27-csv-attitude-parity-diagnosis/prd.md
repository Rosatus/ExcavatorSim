# CAN 姿态 Godot 与 QML 位姿一致性诊断

## Goal

基于 Windows CAN gateway 实录 CSV，确认 Godot -> CAN replay -> QML 姿态链路的帧语义，解释实测画面不一致的原因，并建立可由两端运行时观测闭环的位姿一致性合同。

用户价值：以 Godot 模型与 QML 模型的可比位姿一致为金标准，避免把 CAN 字节透明性、世界系 Euler 表现、上车回转、底盘航向和 QML guidance frame 混为一谈。

## Background And Confirmed Facts

- 分析样本：`godot/dist/windows/output/can_gateway/can_telemetry_20260827_082941.csv`。
- 用户给出的参考工程路径在本机不存在；实际只读工程为 `E:/projects/dev_arch2.0_36b5586c`，回放器为其 `tools/can_replay`。
- 样本覆盖 `08:29:41.149` 至 `08:29:57.181`，约 `16.032 s`；共 5770 行。
- 对全部 5770 行逐帧核验 `_replay` 主 `send` 路径：CSV parser 与 PC001 `can_frame` 打包后的 CAN ID、DLC、payload mismatch 均为 0；5610 个扩展帧均保留 `CAN_EFF_FLAG`，本样本全部来自 CAN3。因此本次 CSV 回放不会改变姿态 payload 语义。
- `_replay` 不保留 `传输方向`/`帧类型`，会把时间改为相对时间并受 speed/batch/repeat 影响；vcan/bridge 路径还会丢失 channel。这些行为不改变本次 PC001/CAN3 姿态字段值，但意味着它不是通用的全语义透明回放器。
- QML 整机航向使用 RTK 帧 `0x0CFDA900` 的 `rtk_heading`，不是 body IMU 帧 `0x18FF3A00` 的 yaw。
- RTK heading 首尾为 `90.00 deg -> 105.86 deg`，解包后净变化 `+15.86 deg`。
- body IMU yaw 首尾为 `0.00 deg -> -15.86 deg`，净变化 `-15.86 deg`。两者物理旋转幅值均为 `15.86 deg`，且样本中满足 `rtk_heading = (90 - body_yaw) mod 360`。
- 瑞芬链路约定为 slots=`(-pitch, roll, yaw)`，下游 parser remap 为 `(roll=s1, pitch=-s0, yaw=s2)`；encode/decode 后 QML 收到的 pitch 与 gateway 输入 pitch 一致。
- sy135 安装补偿为 boom `+35 deg`、arm `-20 deg`、bucket `-95 deg`，Godot 世界 elevation 可按 `compensation - reported_pitch` 还原。
- 下游 `Sensor2Ang` 仅消费 body/boom/arm/bucket pitch；link yaw/roll 不参与关节角计算。
- 回转帧 `0x18FFF000` 从 `0.00 deg` 到 `197.02 deg`。boom/arm/bucket 的世界系 yaw 随上车回转跨越 `+/-180 deg`，不能作为底盘航向对比。
- bucket 接近竖直且叠加回转时 roll 出现 `0/+/-90 deg` 跳变，属于 Euler/gimbal 表现；当前 QML 关节角计算不消费该 roll。
- 完整复刻 `Sensor2Ang` 并包含 body pitch 标定后的样本结果：首帧 `boomPhi=-0.58, armPhi=144.34, bktPhi=49.47`；末帧 `boomPhi=22.70, armPhi=121.70, bktPhi=-13.32`。此前分析脚本漏传 body pitch，已在任务研究脚本中修正。
- `tools/can_gateway/conventions.py::basis_forward_from_quat()` 的注释声明返回 Godot 本地 `-Z` forward，但当前公式实际返回旋转矩阵第一列，即本地 `+X` 轴。
- Godot 车辆代码以 `-basis.z` 为 forward；矩阵和 cardinal-case 推导已确认 RTK heading 的固定 `+90 deg` 来自 `basis_forward_from_quat()` 选错轴，不是合法的 Godot→QML 基变换。
- 更上游的 frame 选择也不一致：gateway 的 RTK 主位置、heading、ENU velocity 和副天线都取 `sample.bodies["chassis"]`。参考 QML/GuideSystem 的 GNSS 标定依赖“上车回转时天线绕回转中心走圆轨迹”，并用 RTK heading 旋转“天线到回转中心”偏移；这强烈证明 RTK frame 应随上车回转，而不是固定下车 chassis。
- QML 3D guidance 使用 RTK heading 作为回转中心 O 处的单一世界航向；正常 `setAlgorithmData()` 会把内部上车相对角清零。2D guidance 才使用 slew angle。当前 QML 3D 数据合同不能同时表达下车 chassis heading 和上车相对 slew 两个 yaw 自由度。
- QML 3D guidance 每 100 ms 消费主 GNSS 经纬高、A900 heading、body IMU 的 roll/pitch 和 boom/arm/bucket IMU 的 pitch；slew 不参与 3D pose，只属于 2D heading。
- QML 的 body IMU 标定会在上车回转过程中按 90/180/270/360 deg heading 采集 roll/pitch，证明其语义 frame 是上车/驾驶室。Godot 应使用 `upper_structure_link` 生成 body IMU；斜坡上的 upper roll/pitch 随 slew 改变，不能复用 chassis R/P。
- QML 的 3D 回转中心公式为 `O = Exca * GO + GNSSA`，所以 gateway 必须按 `GNSSA = O_Godot - Exca * GO` 反求主天线 ENU；当前直接发送 chassis origin 会留下随姿态旋转的位置误差。
- QML calibration 先使用 SY135C factory defaults，再由部署目录 `database/calibration.toml` 逐键覆盖。源码测试 fixture 与 factory defaults 数值不同，因此 parity 测试与 gateway compatibility profile 必须绑定明确的 calibration snapshot，不能猜测现场值。
- QML 监控只有在 `satelliteStatus == 4` 时认为 RTK 定向稳定；gateway 当前固定发送 0。它不改变 guidance 数学，但会让 QML 告警状态与模拟有效数据不一致。
- 因此当前 CSV 只能证明 CAN 数值链闭合，不能证明最终模型 pose 一致；它没有同序号的 Godot authoritative transform 和 QML runtime/model transform。
- 两个独立缺陷已确认但不应与本次 PC001/CAN3 根因混淆：ExcavatorSim 的直接 `SocketCanSink`/`TcpPc001Sink` 会把 29-bit ID 掩成 11-bit；参考 QML parser 的 slew 实现把 raw count 直接写成 angle，与注释和测试期望的 `0..65535 -> 0..360 deg` 换算冲突。

## Requirements

- R1：保留原始 CSV、分析脚本和诊断报告，使后续 agent 能复现首尾 heading、body yaw、slew、link 姿态以及 `_replay` 逐帧透明性检查。
- R2：明确双方可比较的 pose 合同、frame 映射、坐标变换、时间/序号 join 和容差；不能用 Euler 字段相等代替刚体 transform/关节/齿尖的一致性。
- R3：后续修复应使 `basis_forward_from_quat()` 符合 Godot 本地 `-Z` forward 契约，并验证 identity 与正负 Y-up yaw。
- R4：后续修复必须选择符合参考 GNSS 标定合同的 RTK source frame，并一起校正主天线位置、heading、ENU velocity、副天线方向/baseline；不能只给 QML 显示值加减 `90 deg`。
- R5：增加同一 source sequence/tick 的运行时 pose trace：Godot 记录 chassis/upper/boom/arm/bucket authoritative transform 与 gateway packet；参考端记录 parser、`Sensor2Ang`/runtimeResult 和最终 QML model transforms。
- R6：保留现有瑞芬 slots/parser remap 和真实 QML `Sensor2Ang` 数据流；legacy 无 profile 模式保留既有安装补偿，QML profile 模式改用显式 calibration inverse 和 joint-twist mapping。
- R7：pose parity 至少比较所选 root frame、boom/arm/bucket 世界刚体姿态、关节位置和 bucket tip；角度比较必须 wrap，四元数比较必须处理 `q` 与 `-q` 等价。
- R8：实现和发布前验证 Windows gateway；如 Linux gateway 仍作为交付物，则同步重建并验证 Linux 产物。
- R9：QML/GuideSystem 是本任务唯一金标准。Godot 和 Python gateway 必须适配其既有 3D guidance 数据合同；除非后续发现 QML 自身无法消费合同内的合法帧，否则不以修改 QML 来达成 parity。
- R10：新增一个显式 QML compatibility profile，绑定机型、QML calibration snapshot/hash、Godot↔QML 坐标基、GNSS GO、IMU/yaw offsets 和连杆参数；产品运行时不得依赖 sibling reference repository 路径。
- R11：body IMU、RTK heading 和合成 GNSS 主天线位置以 Godot `upper_structure_link` / slew origin 为 source；下车 chassis 仅保留为诊断/运动输入，不直接充当 QML 3D root。
- R12：GNSS 主天线输出必须通过 QML 的 `O = Exca * GO + GNSSA` 合同逆算，使 QML 恢复的 `slewingCenterENU` 与 Godot upper origin 一致；A900 必须通过 QML yaw calibration 的逆映射生成。
- R13：QML compatibility 验证必须调用真实 `ProtocolParser + GuidanceCore/lib_kin`，不能只依赖 Python 复刻；至少覆盖水平 identity、纯 chassis yaw、纯 slew、斜坡+slew 和工作装置组合动作。
- R14：有效模拟 RTK 应输出 QML 认可的稳定定向 status；状态修复不得掩盖无效/缺帧测试。
- R15：修复直接 PC001/SocketCAN sink 的扩展帧打包：29-bit ID 必须带 `CAN_EFF_FLAG`，标准 ID 仍保持标准帧；否则 QML parser 无法命中瑞芬、RTK 和 slew ID。
- R16：工作装置姿态生成必须以 Godot 相邻 frame 的相对 X-axis twist 为输入，并通过绑定 calibration 的 `Sensor2Ang` 逆映射得到 wire pitch；禁止继续用世界 Euler + 未验证的级联 compensation 作为 QML parity 权威。
- R17：bucket wire pitch 必须在 QML 四杆函数的机型合法单调区间内做确定性数值反解，并以前向回代验证唯一解与误差。

## Technical Notes

- 正确的 Godot `-basis.z` 世界方向候选公式为 `(-2*(x*z+w*y), -2*(y*z-w*x), -(1-2*(x*x+y*y)))`。该公式是待开发 agent 通过 Godot basis/四元数约定和单元测试最终确认的修复候选，不应仅凭 CSV 直接替换。
- identity quaternion 的预期 forward 为 `(0, 0, -1)`，以 north=`-Z`、east=`+X` 计算时 heading 应为 `0 deg`；这只修正轴选择，不自动修正 RTK source frame。
- 纯 Y-up yaw 的测试必须明确 Godot 正负旋转和 heading 顺/逆时针约定，验证 heading 与 body yaw 的符号关系，而不只检查 `[0, 360)` 范围。
- 详细证据、影响范围和复现数据见 `research/findings.md` 与 `research/cross-repo-pose-parity.md`；分析工具见 `research/analyze_csv.py`。

## Acceptance Criteria

- [x] 从 CSV 得出 QML RTK heading 首尾净变化为 `+15.86 deg`，body yaw 净变化为 `-15.86 deg`。
- [x] 证明工作装置 pitch 编解码链路保持一致，并记录包含 body pitch 标定的 QML `Sensor2Ang` 首末姿态结果。
- [x] 区分底盘 heading、上车 slew 和世界系 link Euler，解释 yaw/roll 直接对比为何会产生假差异。
- [x] 对实录 5770 帧证明 `_replay` 主 PC001 路径保持 CAN ID、DLC 和 payload。
- [x] 将 `basis_forward_from_quat()` 选错轴记录为确定的方向合同违例。
- [x] 将 RTK source 取 chassis 与参考 GNSS 回转标定合同的冲突记录为强根因证据。
- [x] 用户确认以 QML 3D guidance frame 为 pose parity 边界，并以 QML 为唯一金标准；不要求扩展 QML 表达下车/上车两个独立 yaw。
- [ ] 修复后 identity quaternion 返回 forward `(0, 0, -1)`，heading 为 `0 deg`。
- [ ] 修复后纯 Y-up yaw 的 heading 与项目坐标/旋转约定一致，且不再存在无意的固定 `+90 deg` 偏差。
- [ ] RTK 主位置、heading、ENU velocity 和副天线位置使用已确认的 source/mount contract，相关测试全部通过。
- [ ] body IMU 使用 upper frame，并在斜坡+slew 场景中使 QML 恢复的 body roll/pitch 与目标 Exca 一致。
- [ ] 对绑定的 QML calibration snapshot，QML `slewingCenterENU = Exca*GO+GNSSA` 恢复 Godot upper/slew origin。
- [ ] 有效 RTK status 被 QML 识别为稳定定向，失效状态仍按合同触发告警。
- [ ] 标准帧保持 11-bit；所有 29-bit 帧以 `CAN_EFF_FLAG | (id & CAN_EFF_MASK)` 送入 PC001/SocketCAN，真实 QML parser 能命中对应分支。
- [ ] boom/arm/bucket 的 neutral、单关节正负运动和组合动作经真实 `Sensor2Ang` 后恢复目标 QML joint pose；bucket 数值逆解前向误差在量化容差内。
- [ ] 同序号 Godot/QML pose trace 在所选 frame 边界与容差内一致。
- [ ] 瑞芬姿态契约和 `Sensor2Ang` 既有测试无回归。
- [ ] 目标平台 gateway 构建及相关端到端验证通过。

## Out Of Scope

- 不修改 QML `Sensor2Ang` 四连杆算法或其标定参数。
- 不用过滤或角度钳制掩盖 bucket 的 Euler/gimbal 表现。
- 不把 slew angle 或 boom/arm/bucket 世界 yaw 改作底盘 heading。
- 本任务默认不修改参考工程中 2D slew raw-count bug，也不修改 `_replay` 的方向/时间/channel 语义；若这些要一起修复，应单独纳入范围并验证。
- 不修改 QML/GuideSystem 的 parser、`Sensor2Ang`、标定加载规则、3D/2D 模式选择或渲染矩阵；它们是本任务的兼容目标和测试 oracle。
- 本规划阶段不修改产品代码、不构建发布产物、不启动任务实现。

## Deferred Items

- 是否需要同步 Linux gateway 取决于当前发布目标；若 Linux 仍受支持，应视为发布前必做项。
- 副天线物理 baseline 的准确长度、左右轴和符号尚未在参考仓中找到显式合同；不能保留当前“沿 forward 前后 1 m”的无依据假设。
- 现场部署态 `database/calibration.toml` 尚未纳入本仓；首个自动化 oracle 使用 reference ground-truth fixture 的 calibration snapshot，现场复测前须导入/核对实际 snapshot。
- CSV 只能证明当前样本中的固定关系；最终根因必须由 source-frame/方向契约单元测试和双端运行时 pose trace 闭环。

## Notes

- `prd.md`、`design.md`、`implement.md`、research artifacts 与 implement/check context manifests 已完成并通过任务验证。
- 当前任务保持 `planning`；只有用户在审阅本版规划摘要后明确批准，才运行 `task.py start`。
