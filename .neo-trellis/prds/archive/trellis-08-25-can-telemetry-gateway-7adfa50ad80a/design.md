# Design: CAN telemetry gateway

## Architecture（v2：独立 Python 进程 + 游内面板控制，用户裁定）

```
ExcavatorSim (Godot)                            Python gateway
┌────────────────────────────────┐  UDP :29764  ┌──────────────────────────┐
│ CanTelemetryBridge (autoload)  │ ─遥测流─────► │ gateway.py               │
│  · 启动时 create_process 拉起    │              │  · 编码器+CSV 写入         │
│    python tools/can_gateway     │  UDP :29765  │  · RECORD_START/STOP 分段  │
│  · 心跳监听 → 状态机             │ ◄─心跳/回执── │  · Ctrl-C/SHUTDOWN 退出    │
│  · set_recording() 发控制包      │  控制包       └──────────────────────────┘
│ OperatorUI: [CAN 输出]按钮+状态   │
└────────────────────────────────┘
降级：spawn 失败或心跳超时(>2.5s) → 面板显示"离线"，点击开始时提示并可重试拉起。
```

### 控制协议（新）
- 控制包 bridge→gateway，`<IBBHI` LE 12B：magic `0x43544E43`("CTNC") | ver=1 | cmd(1=START,2=STOP,3=SHUTDOWN) | reserved u16 | seq u32
- 心跳 gateway→bridge，`<IBBHQ` LE 16B：magic `0x43544E4B`("CTNK") | ver=1 | flags(bit0=recording) | reserved u16 | tick_ms u64；周期 0.5s
- 状态机（bridge）：OFFLINE(pid 无效或 >2.5s 无心跳) / ONLINE / RECORDING(flags.bit0)

### 面板接线（接受侵入的既有文件清单）
- `main.tscn`：Tools 行加 Button `CANOutputToggle`（文本"CAN 输出"）；AdvancedPanel 加 Label `CANStatus`
- `operator_ui.gd`：@onready 两引用 + pressed→`bridge.set_recording(toggle)` + 周期刷新状态文案（在线/离线/录制中/文件名）

## Architecture

```
ExcavatorSim (Godot)                      Python gateway (tools/can_gateway/)
┌──────────────────────────┐   UDP    ┌─────────────────────────────────┐
│ CanTelemetryBridge       │ ───────► │ gateway.py  (recv loop, 50Hz)   │
│ (autoload, 新文件)        │ localhost│   ├─ conventions.py  quat→RPY、  │
│  读 MotionPresentation    │ :29764   │   │  ENU→大地坐标、安装重映射表     │
│  帧节点 + TrackedChassis- │          │   ├─ encoders/ruifen_imu.py     │
│  Controller 履带状态      │          │   ├─ encoders/sinan_rtk.py(大端) │
│ process_physics_priority  │          │   ├─ encoders/dxg_slew.py       │
│ =110（晚于 TruthPublisher │          │   ├─ encoders/travel_pilot.py   │
│ 的 100，保证读到本 tick） │          │   └─ csv_writer.py (CANape 方言) │
└──────────────────────────┘          └─────────────────────────────────┘
                                              │ CSV append
                                              ▼
                              output/can_telemetry_<stamp>.csv
                              （可被 dev_arch2.0 read_can_csv 消费→vcan0 回放）
```

## Godot 侧契约（R1/R2）

- **零侵入**：新文件 `godot/client/scripts/can_telemetry_bridge.gd`；仅 `project.godot` 增加 autoload 行。不挂场景节点、不改任何现有脚本的信号/字段。
- 数据获取（与 `simulation_truth_publisher.gd:148-158` 同源逻辑，但独立实现）：
  - `_presentation.get_frame_node(<frame>)` 取 base_link / upper_structure_link / boom_link / arm_link / bucket_link 的 `global_transform` → 四元数 basis.get_rotation_quaternion() + origin
  - `TrackedChassisController`（ChassisMotionRoot）读 left/right command 与 speed_m_s
  - swing 关节角：upper 相对 chassis 的相对 yaw（或 presentation 暴露的 joint position；实现期二选一，优先前者避免新增依赖）
- **UDP 包格式**（小端定长，版本化，总长 176 字节）：
  ```
  magic u32 = 0x43544E31 ("CTN1") | version u8 | flags u8 | reserved u16
  tick_ms u64
  body[5]: quat 4×f32 + origin 3×f32        # chassis, upper, boom, arm, bucket 固定顺序
  swing_rad f32 | track_cmd_l f32 | track_cmd_r f32 | track_spd_l f32 | track_spd_r f32
  ```
  共 16 + 5×28 + 20 = 176 字节。
- 发送：`UdpPeer.send()`（PacketPeerUDP），未连接对端时 OS 静默丢包，无重试无队列；频率 `Engine.physics_ticks_per_second` 整分频（默认每 physics tick 60Hz÷配置，输出≈50Hz）。

## Python 侧设计（R3–R5）

### 编码权威规则表（从 protocolparser.cpp 抄录，测试钉死）

| ID | 类型 | 布局 | 来源锚点 |
|---|---|---|---|
| 18FF3A00~3D00 | 扩展帧 | LE u16 count ×3 @byte0/2/4，deg=count×0.01−180；count=0 三连为无效标记，编码器禁止产出 | `parseVg325eRpyEx` |
| 18FFF000 | 扩展帧 | byte0-1 LE u16 counts（360°↔65536），byte2 STA=0，byte3-7=0 | `parseDxingSlewPDO` |
| 0CFDA000 | 扩展帧 | GPS 周 u16LE? 实现期按 `parseSinanTime` 抄录 | A000 parser |
| 0CFDA200/300/400 | 扩展帧 | int64 大端 /1e8 → 经/纬/高 | `parseCgi610Longitude` |
| 0CFDA500/600/700 | 同上 | 副天线（由主位置+航向+基线偏移合成） | 同上 |
| 0CFDA800 | 扩展帧 | ve/vn/vu/v 4×i16 大端 ×0.01 m/s | `parseCgi610CarV` |
| 0CFDA900 | 扩展帧 | heading u16 大端 ×0.01（byte0-1），余保留 | `parseCgi610CarRpy` |
| 0x256 | **标准帧** | byte4-5 LE i16 左压、byte6-7 LE i16 右压；有效域 ≤50，≥8 判移动 | `decodePilotPressure`/`parseTravelHandle` |

**明确不用 cantools 打包 RTK 帧**：DBC(can4) 为 Intel 全小端声明，与 parser 的混合端序（仅速度帧大端）不符——以 parser 为准手写 struct。瑞芬帧同样手写（公式一行，依赖更少）。DBC 仅在测试中作 sanity 参考。

### CGI610 端序结论（四方互证：parser 代码 / 旧协议文档公式 / 实采 CSV / 对方 ground-truth e2e 夹具+期望值）
- 小端：GPS 周、周内毫秒、gpsAge、经/纬 int64(1e8)、高 int32(mm)、航向 u16(1e-2°)
- 大端：速度帧 ve/vn/vu/v（唯一例外）
- 判定准则：移位量==字节地址偏移 ⇒ 小端；曾两次把 `(data[hi]<<8)|data[lo]` 形态误读为大端，教训记录在案

### conventions.py
- quat → ZYX 欧拉（yaw-pitch-roll）工具函数
- 安装重映射表 `MOUNTING_REMAP[link]`：初版按 `parseRuifen*` 系列抄录（body: roll'=rpy.pitch_slot 等）；暴露为纯数据便于实机校准时改表不动码
- ENU→WGS84：可配原点（默认湖州附近 lat=30.8675, lon=120.0933, alt=3.0）；经纬度输出 ×1e8 取整为 int64 大端

### csv_writer.py
- UTF-8-sig；列头与样例一致：序号(5位补零)、系统时间(`="HH:MM:SS.mmm"`)、时间标识(`0x`+递增 hex)、CAN通道(ch3)、传输方向(接收)、ID号(`0x%08X` 扩展 / `0x%03X` 标准)、帧类型(数据帧)、帧格式(扩展帧/标准帧)、长度(0x08)、数据(`x| ` + 16 个大写 hex 字节空格分隔)
- 时间标识列：用仿真 tick_ms 直接十六进制（保持单调即可，replay 只用它排序）

### 运行形态
- `python tools/can_gateway/gateway.py [--port 29764] [--out DIR] [--imu-hz 100 ...]`，单进程阻塞循环，Ctrl-C 落盘关闭；无第三方硬依赖（struct/csv/math 标准库；cantools 仅 tests 可选）

## Trade-offs

- **四元数而非欧拉上发送**：Godot 侧免欧拉序约定，全部角度语义收敛到 Python 单点（conventions.py），标定改动只动一处
- **手写编码器而非 cantools 运行时**：消除 DBC/parser 分歧风险与 Python 重依赖；金样本字节级测试补偿人工抄录风险
- **CSV 追加写 + 会话分段文件**：崩溃最多损一条尾行，不影响 replay（其按行解析）

## Rollback

删除 autoload 注册行 + 删除 `tools/can_gateway/` 即完全回退；无持久化副作用、无 schema 变更。
