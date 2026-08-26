# 08-26-linux-gateway-vcan-ict

## Goal

为挖掘机遥测网关提供 Linux 分发与 SocketCAN 直发能力：同一份 `tools/can_gateway` 代码在 Linux 下可将 CAN 帧实时写入 vcan 网卡（供 CANape/ICT 测试台消费），Godot 游戏内新增"连接 ICT"按钮，仅在检测到 Linux gateway 时可用。WSL 仅承担出包职责，vcan 实测不在 WSL 内进行。

## Background

- 现有 gateway（08-25 任务）在 Windows 上以 PyInstaller 打包为 `gateway.exe`，输出 CANape 方言 CSV。
- 参考实现：`E:\projects\dev_arch2.0_36b5586c\tools\can_replay`：
  - `vcan_setup.py::ensure_vcan_interface` — 检测/自动创建 vcanN（sudo 探测、modprobe vcan、ip link add、并发容错）
  - `vcan_client.py::VcanClient` — `socket(AF_CAN, SOCK_RAW, CAN_RAW)` + `bind((interface,))`，发送 16 字节 can_frame（`can_id, dlc, 0,0,0, data[8]`），纯标准库、无 python-can
  - `setup_vcan.sh` — uv/python 入口包装
- 已知约束：WSL2 默认内核无 CONFIG_CAN/VCAN，WSL 只用于构建产物；SocketCAN 运行验证在真实 Linux 上完成。

## Requirements

### R1 跨平台 gateway（单代码库，不 fork）
- 抽象 FrameSink 协议（`append(can_id, payload)` / `close()`）；现有 CSV 写入包一层 CsvFrameSink，行为不变。
- 新增 SocketCanSink（仅 Linux）：参照 VcanClient 的 AF_CAN 实现与 can_frame 打包格式；构造时校验接口存在（复用移植版 vcan_setup 逻辑）。
- gateway 主循环 emit_frames 改为面向 sink；CSV 录制与 vcan 发送相互独立、可同时开启。
- CLI：`--sink {csv,vcan}`（默认 csv，保持向后兼容）、`--interface vcan0`、`--setup-vcan` 子命令式入口（等价 ensure_vcan_interface）。

### R2 平台上报协议
- 心跳 CTNK flags 新增 bit1=platform（0=Windows, 1=Linux），reserved 字段不动；Godot 桥解析并暴露平台状态。
- Godot CanTelemetryBridge：探测链按 OS 区分（Windows 找 gateway.exe/gateway.py；Linux 找 can_gateway/gateway 或 gateway），新增 `is_linux_gateway()`。

### R3 Godot ICT 按钮
- main.tscn Tools 行加 ICTConnectToggle 按钮，风格同 CANOutputToggle。
- 仅当 bridge 在线且 `is_linux_gateway()` 时 enabled；否则 disabled（tooltip 说明原因）。
- 点击 = 向 gateway 发 CTNC cmd=ICT_START（新命令字）；再点 = ICT_STOP 停止 vcan 发送。文案状态机：不可用/连接 ICT/断开 ICT。

### R4 WSL 分发脚本
- `tools/can_gateway/dist_linux.sh`：WSL 内执行——检测/创建 venv → pip install pyinstaller → pyinstaller --onefile → 产物拷贝到 `dist/can_gateway_linux/gateway`（ELF）。
- Windows 侧 build_exe.py 不回归；发布结构文档更新（exe + gateway 并列）。

## Acceptance Criteria

- [ ] Python 单测全绿：FrameSink 分派、SocketCanSink（mock socket）、心跳 platform 位编解码、CTNC 新命令字、vcan_setup 移植逻辑（runner 注入模式，抄 dev_arch 测试写法）
- [ ] Windows 回归：gateway --sink csv 行为与 08-25 版本逐字节一致（金样本测试不回归）；e2e spawn→录制→停止 全链路绿
- [ ] Linux 冒烟（WSL 出包后）：`./gateway --smoke --sink vcan --interface vcan0` 在支持 vcan 的环境可运行；WSL 内至少验证到 AF_CAN 报错路径清晰（内核无 vcan 时给出可操作提示而非崩溃）
- [ ] Godot：Windows 下 ICT 按钮 disabled 且 tooltip 正确；模拟 linux 心跳位时按钮激活、点击发送 ICT_START（单测覆盖桥状态机）
- [ ] dist_linux.sh 在 WSL Ubuntu 成功产出 dist/can_gateway_linux/gateway，文件类型为 ELF
- [ ] 矩阵测试（排除已知坏 terrain_collider_chunk）全绿

## Non-goals

- WSL 内实测 vcan 收发（需自编译内核，明确排除）
- 真实 CAN 硬件（can0 等）适配——仅 vcanN 自动创建
- python-can 引入（坚持零第三方依赖）
