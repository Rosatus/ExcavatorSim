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

# 冒烟（无需游戏，自注入合成包）
python tools/can_gateway/gateway.py --smoke --max-rows 40

# 测试
python -m unittest discover -s tools/can_gateway/tests   # 协议/编码器金样本
Godot: tests/can_gateway_e2e_test.gd                     # 进程监督+录制全链路
```

参数：`--port` `--imu-hz/--slew-hz/--rtk-hz/--travel-hz`、
`--rtk-byteorder {big,little}`、`--sink {csv,vcan}`（默认 csv）、
`--interface vcan0`、`--setup-vcan`。

## Linux / SocketCAN（vcan 直发）

`--sink vcan` 将编码帧经 `AF_CAN CAN_RAW` 实时写入 vcan 网卡
（供 CANape/ICT 测试台消费），与 CSV 录制相互独立。

```bash
# WSL 出包（产物 ELF → dist/can_gateway_linux/gateway）
cd tools/can_gateway && ./dist_linux.sh        # 优先 uv，缺 uv 时回退 venv+pip

# 目标机：准备 vcan 并直发（需 root 或 sudo）
./gateway --setup-vcan --interface vcan0
./gateway --sink vcan --interface vcan0        # + 游戏内 [连接 ICT]
```

注意：WSL2 默认内核可能无 CONFIG_CAN/VCAN（报 "AF_CAN unavailable"），
需自编译内核或用真实 Linux。构建机 glibc 需不高于目标机。

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
- **CGI610 全族小端**（含速度帧 ve/vn/vu/v；2026-08-25 按产品决策由大端
  统一为小端）。金样本测试断言默认编码器可逐字节复现实采帧。
  注意：parser 的 `parseCgi610CarV` 代码结构是大端（`(data[0]<<8)+data[1]`，
  全族唯一交叉），与 DBC/实采矛盾且两份实采均为零速帧无法仲裁——
  **若真车回放发现速度异常，优先核查 parser 此函数**。
  （`docs/can_spin_test_fixed.csv` 与本 gateway 无字节序冲突；
  判定端序唯一可靠的准则是"移位量是否等于字节地址偏移"。）
- 瑞芬 IMU：slot=count×0.01−180°；count 三连零 = 无效标记 → 编码器钳位 ≥1。
  parser 安装重映射 roll=s1/pitch=−s0/yaw=s2，在 `conventions.MachineState.
  sensor_slots` 反演。
- 行走压力 0x256：无符号 u16 先导压力（kg，合法域 0~50），≥8 判移动 →
  行走发 +9（幅值恒正，**本帧不表达方向**），静止发 0。
- 轴系/安装标定集中在 `conventions.py`（ORIGIN_*、MOUNTING 相关纯数据），
  实机校准改表不动码。

## 文件

- `gateway.py` — 收包循环 + 帧率调度 + 冒烟模式 + sink 分派（CSV/vcan）
- `conventions.py` — 包解析 / 四元数→ZYX 欧拉 / ENU→大地坐标 / 行走语义
- `csv_writer.py` — CANape CSV 方言（UTF-8-sig，被对方 read_can_csv 消费）
- `sinks.py` — FrameSink 抽象：CsvFrameSink / SocketCanSink（AF_CAN 直发）
- `pc001_sink.py` — PC001 TCP 服务端 sink（Windows ICT，字节兼容 dev_arch 桥）
- `vcan_setup.py` — vcan 接口检测/自动创建（移植自 dev_arch can_replay）
- `dist_linux.sh` — WSL/Linux 打包脚本（uv 优先）→ dist/can_gateway_linux/gateway
- `encoders/` — ruifen_imu / dxg_slew / sinan_rtk / travel_pilot
- `tests/` — 金样本往返（实采 24 行×15 ID）+ 合成扫描 + 语义断言 +
  对方解析器兼容冒烟；`extract_golden.py` 一键重建夹具
