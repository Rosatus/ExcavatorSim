# CAN telemetry gateway: sim physics to SY135C CAN frames

## Goal

让 ExcavatorSim（Godot client）以最低耦合、低侵入、高开销可控的方式，把整机主要物理量（车体/上部结构/动臂/小臂/铲斗的世界姿态 + 回转角 + 履带行进指令）持续发出；一个独立的 Python gateway 接收这些量，按 dev_arch2.0_36b5586c 项目**运行时解析器的逆向逻辑**编码成 SY135C 的 CAN 输入帧，输出为与 `docs/can_spin_test_fixed.csv` 同方言的 CSV，可直接被 dev_arch2.0 的 `tools/can_replay/csv_parser.read_can_csv()` 消费并回放进 vcan0。

价值：为 dev_arch2.0 引导系统提供物理一致、可复现的"虚拟挖机"传感器输入，替代实机采集，支撑其算法/UI 回归测试。

## Confirmed Facts (repository evidence)

### dev_arch2.0 运行时真源 = 手写 ProtocolParser（非 DBC）
- 解码入口 `GuideSystem/services/can/protocolparser.cpp` `parseFrame()`；ID 常量集中在 `protocolparser.h`
- 生成代码 `services/can/generated/{can3,can4}.sy135c.{c,h}` 编译但**无任何调用方**（全仓库零 include）
- **DBC 与 parser 存在字节序分歧**：can4.sy135c.dbc 为全小端声明；parser 实际为**混合端序**（经/纬/高/航向/GPS 时间/gpsAge 小端，仅速度帧大端）——已由 parser 代码、旧协议文档公式、实采 CSV、对方 ground-truth e2e 夹具四方互证 → RTK 帧按 parser 混合端序手写编码，不信任 cantools 打包
- 瑞芬 IMU RPY 扩展帧（18FF3A00 车体 / 3B00 动臂 / 3C00 小臂 / 3D00 铲斗）：每轴 LE u16 count，值 = count×0.01 − 180（范围 [-180,180]）；count 全零 = 无效帧标记（`parseRuifenBody` 判 -180/-180/-180 后 `setImuInvalid`）
- 车体帧有安装重映射：`roll=rpy[1]; pitch=-rpy[0]; yaw=rpy[2]`（左侧安装）；各连杆重映射表实现期从 `parseRuifen*` 系列逐一抄录
- 鼎兴回转 0x18FFF000：Byte0-1 LE u16 角度计数（65536↔360°），Byte2 STA 状态字（bit0 超速/bit1 磁场异常/bit2 电源异常；STA==0 才有效），Byte3-7 预留
- 行走先导压力 0x00000256（标准帧）：Byte4-5 LE 左压力、Byte6-7 LE 右压力（int16 LE）；`>= kTravelPilotPressureMovingThresholdKg(=8)` 判定 bodyMoving，`> kTravelPilotPressureMaxKg(=50)` 整帧无效 → 用户方案"行进赋 ±9、停止赋 0"语义正确
- 右手柄 0x0CFDD8F9 已确认无人消费（断头路），排除在范围外
- CSV 方言：UTF-8(-sig) + mojibake 恢复；必需列 序号/系统时间/时间标识/CAN通道/ID号/帧格式/长度/数据；数据列形如 `x| C7 FF 00 ...`；样例见 `docs/can_spin_test_fixed.csv`（123424 行真实采集）

### ExcavatorSim 数据源已存在
- `simulation_truth_publisher.gd` 每 physics tick 已聚合完整快照：bodies(chassis/upper/boom/arm/bucket 世界 transform)、joints(swing/boom/arm/bucket position_rad)、tracks(left/right command 与 speed_m_s)；jolt-authoritative 与 kinematic 两条路径都覆盖
- 帧节点可经 `MotionPresentation.get_frame_node("base_link"/"upper_structure_link"/"boom_link"/"arm_link"/"bucket_link")` 直接读取
- `SimulationTruthPublisher.process_physics_priority = 100`

## Requirements

1. **R1 Godot 遥测桥**：新增独立脚本 `can_telemetry_bridge.gd`（autoload），以固定频率（默认 50Hz，可配）把物理量打包为带版本头的小端二进制 UDP 包发往 localhost；gateway 不在线时静默丢弃。除 `project.godot` autoload 注册行外**不修改任何现有脚本**。
2. **R2 物理量集**：五个刚体的世界姿态（四元数+原点）、swing 关节角、左右履带 command/speed、tick 时间戳。
3. **R3 Python gateway**（`tools/can_gateway/`）：接收 UDP → 坐标/角度约定转换 → 编码以下帧：
   - 瑞芬 IMU RPY ×4（18FF3A00/3B00/3C00/3D00）
   - 鼎兴回转 0x18FFF000
   - 司南 RTK A000/A100/A200/A300/A400/A500/A600/A700/A800/A900（世界坐标经配置原点反算经纬高；副天线由航向推算）
   - 行走压力 0x256（|command|>阈值 → ±9，否则 0）
4. **R4 权威规则**：所有帧编码以 ProtocolParser 解码公式为唯一权威（CGI610 混合端序：geo/heading/time 小端、velocity 大端）；DBC 仅用于交叉校验信号名/比例因子；RTK 帧手写编码。
5. **R5 CSV 输出**：与 can_replay 方言完全一致，可被 `read_can_csv()` 无错加载；帧速率默认对齐实采（IMU≈100Hz/回转≈100Hz/RTK≈10Hz/行走≈10Hz，可配）。
6. **R6 金样本测试**：用 dev_arch2.0 实采 CSV 抽样做夹具——"参考解码→重编码→逐字节相等"，覆盖全部在范围内的 ID；另含合成角度扫描往返测试与行走压力语义测试（±9 → bodyMoving=true）。
7. **R7 不破坏现状**：ExcavatorSim 测试矩阵保持全绿。

## Acceptance Criteria

- [ ] 启动游戏 + gateway，产出的 CSV 被 dev_arch2.0 `read_can_csv()` 加载零格式错误（冒烟脚本验证）
- [ ] 金样本夹具：每个目标 ID 至少 20 行真实采样的 decode→re-encode 字节级还原通过
- [ ] 合成扫描：RPY ∈ [-179.99,179.99]、回转 ∈ [0,360) 全域采样往返误差 ≤ 0.01°（瑞芬）/ ≤ 360/65536°（回转）
- [ ] 行走语义：command 前进 → 左右压力 = 9 且参考解码 bodyMoving==true；静止 → 压力 0 且 bodyMoving==false
- [ ] `git diff` 证明除 `project.godot` 外无现有脚本被修改
- [ ] ExcavatorSim standalone matrix 24/24 通过

## Out of Scope

- 右手柄 0x0CFDD8F9 帧
- 司南 IMU 标准帧 0x585~0x588（BCD 备选源；瑞芬扩展帧为主源）
- vcan0 实时注入（CSV 文件交付即可；回放由 dev_arch2.0 既有工具完成）
- 对 dev_arch2.0 仓库的任何改动

## Open Questions (blocking)

（无）

## Risks / Deferred

- **轴系/安装约定的语义标定**：Godot 四元数→传感器 RPY 的安装重映射表初版按 parser 代码推断，最终需用户对照实机安装方向校准——已隔离到 `conventions.py` 配置表，不影响字节层正确性
- RTK 时间帧 A000 的 GPS 周/秒直接取仿真墙钟换算；A100 状态字段填固定"有效定位"合成值（具体位段实现期从 `parseSinanStatus` 抄录）
