# CAN Telemetry Gateway

把 ExcavatorSim 的机器物理量编码为 SY135C CAN 帧 CSV，供 dev_arch2.0_36b5586c
引导系统经 `tools/can_replay` 回放消费。

```
ExcavatorSim (CanTelemetryBridge autoload)          Python gateway（独立进程）
  游戏面板 [CAN 输出] 按钮 ──控制包 CTNC──►          RECORD_START/STOP 分段写 CSV
  遥测流(50Hz, UDP :29764) ───────────────────►      编码器 → output/can_gateway/*.csv
  心跳监听(:29765) ◄────────心跳 CTNK─────────       flags.bit0=recording
游戏启动时自动 spawn python；失败/心跳超时 → 面板显示 offline。
headless（测试/CI）不自动 spawn，测试显式调 spawn_gateway()。
```

## 用法

```powershell
# 游戏 + 面板按钮即完整流程：点 [CAN 输出] 开始录制，再点停止。
# CSV 落在 <仓库根>/output/can_gateway/can_telemetry_<时间戳>.csv

# 单独手动运行 gateway（调试）
python tools/can_gateway/gateway.py --out output/can_gateway

# 按 QML 只读代码语义投影 SY135 CAN（产品默认配置）
python tools/can_gateway/gateway.py --model sy135 `
  --compat-profile builtin:qml-sy135-ground-truth `
  --out output/can_gateway

# 冒烟（无需游戏，自注入合成包）
python tools/can_gateway/gateway.py --smoke --max-rows 40

# 测试
python -m unittest discover -s tools/can_gateway/tests   # 协议/编码器金样本
Godot: tests/can_gateway_e2e_test.gd                     # 进程监督+录制全链路
```

参数：`--port` `--imu-hz/--slew-hz/--rtk-hz/--travel-hz`、
`--rtk-byteorder {big,little}`、`--compat-profile PATH|builtin:qml-sy135-ground-truth`、
`--qml-calibration PATH`、`--sink {csv,socketcan,vcan,tcp}`（默认 csv）、
`--interface can0`。`vcan` / `--setup-vcan` 仅保留为开发兼容入口。

## Linux / SocketCAN（物理 can0 直发）

Linux 游戏启动参数自动选择 `--sink socketcan --interface can0`。点击
**连接 ICT** 后，Gateway 检查物理 `can0`：已满足 250 kbit/s、
`restart-ms=100`、`txqueuelen=1000` 且状态可用时直接绑定；否则通过受限
helper 自动配置并复核。CAN 帧构造和 CSV 录制不受此流程影响。

```bash
# WSL/Linux 出包（gateway + 固定 can0 helper + 安装脚本）
cd tools/can_gateway && ./dist_linux.sh        # 优先 uv，缺 uv 时回退 venv+pip

# 目标机安装阶段：管理员只执行一次；默认授权给 sudo 的原始调用用户
cd dist/can_gateway_linux
sudo ./install_can0_helper.sh                   # 也可显式追加运行游戏的用户名

# 正常运行无需 root 或手工 setup；游戏内点击 [连接 ICT]
# 卸载授权（不 down/delete can0，不卸载驱动）
sudo ./uninstall_can0_helper.sh
```

目标机必须已连接 USB-CAN，并由驱动创建 `can0`；helper 不创建设备也不安装
驱动。运行时只调用固定命令
`sudo -n /usr/local/libexec/excavatorsim/can0-setup-helper`，不会在后台等待密码。
缺设备、缺 helper/授权、配置、bind 或 send 失败会回传到游戏 UI。

WSL2 通常没有真实 `can0`，只能用于构建和无硬件测试。构建机 glibc 需不高于目标机。

## Windows / PC001 TCP（ICT 直连）

Windows 无 SocketCAN，改用 can_replay 的 PC001 TCP transport：
gateway 作 **TCP 服务端**（默认 `0.0.0.0:5678`），ICT 侧运行现成的
`socket_client_to_vcan.sh` 桥接到 vcan——**对端零改动**。

```
ExcavatorSim gateway.exe (--sink tcp)          ICT 侧 (LinuxPC)
  TCP :5678 服务端                               socket_bridge.py 客户端
  ── "who" ────────────────────────────────►     回 "PC001"
  ◄─ [u16 count] + count×[can_frame16B+i32 channel] ──► 写入 vcan0
```

- 游戏 AdvancedPanel 的 **ICT IP / ICT 端口** 输入框配置监听地址
  （持久化 user://ict_config.cfg，spawn 时经 argv 注入）；
  [连接 ICT] 在 Windows/Linux 网关下均可用。
- 手动运行：`gateway.exe --sink tcp --tcp-host 0.0.0.0 --tcp-port 5678`
- 对端：`python3 -m tools.can_replay bridge --host <本机IP> --port 5678 --interface vcan0`
- 无客户端接入时帧静默丢弃；断线自动重等连接，未发出的帧重新排队。
- 批帧 ≤100 帧（MAX_BATCH_FRAMES），握手超时 10s，语义与参考实现一致。

## 关键约定

- **编码权威 = dev_arch2.0 `GuideSystem/services/can/protocolparser.cpp`**
  （DBC 与运行时解析存在分歧处一律跟随 parser）。
- legacy 无 profile 模式维持 **CGI610 全族小端**，金样本测试断言默认编码器可
  逐字节复现实采帧。`qml-guidance-3d` compatibility profile 单独把 A800
  ve/vn/vu/v 编成大端，因为只读 QML `ProtocolParser` 对这四个 i16 使用网络序；
  其余 RTK 帧仍遵循 profile 的小端合同。
  注意：parser 的 `parseCgi610CarV` 代码结构是大端（`(data[0]<<8)+data[1]`，
  全族唯一交叉），与 DBC/实采矛盾且两份实采均为零速帧无法仲裁——
  **若真车回放发现速度异常，优先核查 parser 此函数**。
  （`docs/can_spin_test_fixed.csv` 与本 gateway 无字节序冲突；
  判定端序唯一可靠的准则是"移位量是否等于字节地址偏移"。）
- 瑞芬 IMU：slot=count×0.01−180°；count 三连零 = 无效标记 → 编码器钳位 ≥1。
  parser 安装重映射 roll=s1/pitch=−s0/yaw=s2，在 `conventions.MachineState.
  sensor_slots` 反演。
- **姿态轴系（Y-up）**：Godot 世界 Y-up，姿态按 Ry(yaw)·Rx(pitch)·Rz(roll) 分解
  （先航向、后段仰角、后横滚）。符号契约：解析 pitch = −(臂杆段方向绝对仰角)，
  抬高为负（真机金样本语义，下游按 pitch 差分重建关节角）。
  旧 Z-up ZYX 分解已废弃（曾把抬臂错送 roll 通道、回转 ±90° 万向节奇异）。
- **IMU 零位安装角补偿**：仿真 link frame ≠ 臂杆钢面 IMU。`conventions.
  IMU_MOUNT_COMPENSATION_DEG` 按模型补偿：
  - sy205：rest 帧单位阵，段几何烘焙——boom −47.65 / arm +101.79（下游极角
    约定，肘部偏离伸直 30.58°）/ bucket 待实测定
    （出处：pivot_contract 铰点 C/F/Q）
  - sy135：段几何全水平，rest_transforms 含 X 轴旋转（+35/−55/−75）→
    boom +35 / arm −55 / bucket −75
  该表与下游 calibration.toml 现值（pitch_error_IMU_Boom=0.4713 等）**成套**；
  下游零改动即可渲染正确 rest 形状（Sensor2Ang 复刻测试锁定）。模型经
  `--model`/bridge spawn argv 选择，默认 sy135。
  这张表仅属于 legacy 无 profile 路径；QML compatibility profile 使用实际
  相邻 link 中性旋转（swing 0 / boom +35 / arm -90 / bucket -50）并反演完整
  `ProtocolParser → GuidancePeriodicService → lib_kin` 调用链，不能混用两套零位。
- 行走压力 0x256：无符号 u16 先导压力（kg，合法域 0~50），≥8 判移动 →
  行走发 +9（幅值恒正，**本帧不表达方向**），静止发 0。
- 轴系/安装标定集中在 `conventions.py`（ORIGIN_*、MOUNTING 相关纯数据），
  实机校准改表不动码。

## 文件

- `gateway.py` — 收包循环 + 帧率调度 + 冒烟模式 + sink 分派（CSV/SocketCAN/TCP）
- `conventions.py` — 包解析 / 四元数→ZYX 欧拉 / ENU→大地坐标 / 行走语义
- `qml_profile.py` / `qml_compat.py` — 严格 profile/标定加载与 QML 数学逆投影
- `resources/` — SHA-256 绑定的 QML profile 与 ground-truth calibration
- `csv_writer.py` — CANape CSV 方言（UTF-8-sig，被对方 read_can_csv 消费）
- `sinks.py` — FrameSink 抽象：CsvFrameSink / SocketCanSink（AF_CAN 直发）
- `can0_setup.py` / `can0_setup_helper.py` — 固定 can0 就绪检查与受限配置事务
- `pc001_sink.py` — PC001 TCP 服务端 sink（Windows ICT，字节兼容 dev_arch 桥）
- `vcan_setup.py` — 仅开发兼容的 vcan 接口检测/自动创建
- `dist_linux.sh` — 打包 Gateway、固定 helper 与安装/卸载脚本
- `encoders/` — ruifen_imu / dxg_slew / sinan_rtk / travel_pilot
- `tests/` — 金样本往返（实采 24 行×15 ID）+ 合成扫描 + 语义断言 +
  对方解析器兼容冒烟；`extract_golden.py` 一键重建夹具
