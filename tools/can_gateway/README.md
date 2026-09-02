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

# Web 后台默认仅监听本机 127.0.0.1:29777；独立启动时可自动打开浏览器
python tools/can_gateway/gateway.py --open-browser

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

参数：`--port`、`--mode {standalone,godot-managed}`、`--web-port`、
`--open-browser`、`--imu-hz/--slew-hz/--rtk-hz/--travel-hz`、
`--rtk-byteorder little`、`--dbc-dir DIR`（可重复）、
`--compat-profile PATH|builtin:qml-sy135-ground-truth`、
`--qml-calibration PATH`、`--sink {csv,socketcan,vcan,tcp}`（两平台默认 tcp）、
`--interface can0`。`vcan` / `--setup-vcan` 仅保留为开发兼容入口。

## Web CAN 后台

Gateway 启动后访问 `http://127.0.0.1:29777`。Web 服务固定只绑定本机；
Godot 以 `--mode godot-managed` 拉起时，持续遥测 ID 默认使用“仿真”权威；用户可在
当前会话逐 ID 临时切换为“关闭”或“自定义”，重启后恢复默认仿真。即使 TCP listener
已就绪但 PC001 尚未握手或暂时断连，逐 ID authority 仍保持可编辑；离线帧由 TCP sink
丢弃且不在重连后重放。托管模式仍拒绝
传输重配、DBC reload、全局 arm 和配置导入/导出。独立启动（默认 `standalone`）时，
Windows 与 Linux 页面都可重配当前 PC001 TCP 服务端；只有显式 SocketCAN
低延时模式才提供二次确认后的 `can0` 重启。

主表按 CAN ID 展示最近一次成功 transport-egress payload、目标频率、最近 10 次成功
egress 平均得到的实际频率和实时新鲜度；这里的 egress 是本地 SocketCAN `send()` 或
TCP `sendall()` 成功，不表示物理 CAN ACK。展开行显示该真实 payload 对应的物理量。
编辑窗口支持物理值与 exact-DLC payload 双向预览，`1..100 Hz` 整数频率和显式保存。
DBC 报文继续使用 strict codec；回转 `0x18FFF000` 由新版 CAN3 DBC 编码。
仅行走 `0x256` 和 timed CAN `0x18FFF100` 位于 DBC 外。timed row 进入同一三态控制：
仿真权威下仍由原 CTNC 命令触发固定 50 Hz、10 秒 burst，自定义权威下则按页面
保存的 payload 与整数频率连续发送。

独立模式保存逐 ID 的关闭/自定义选择、payload 和频率到 `can-console.json`，但全局
“开始自定义发送”永不持久化，进程重启不会自动发包。页面可导入/导出完整、带 catalog
fingerprint 的 `excavatorsim-can-console` JSON；它不包含 TCP endpoint、can0、主题、arm
状态或实时统计。主题偏好只保存在浏览器 `localStorage`。页面估算总线负载率并在负载
较高时告警，但不会阻止发送。

默认扫描随包 `resources/dbc` 与可执行文件相邻的 `dbc/`，额外目录可重复传入
`--dbc-dir DIR`。随包包含获批的 `can3.sy135c.dbc` 和 `can4.sy135c.dbc`。
内嵌与外置文件内容完全一致时会静默合并为一份 DBC，但保留全部来源路径；
文件优先按 UTF-8（含 BOM）严格解码，仅在失败时用 CP1252 兼容解码并显示提示。

## Linux / SocketCAN 低延时模式（显式启用、暂时停止维护）

Linux 默认与 Windows 一样启动 PC001 TCP Server，不会检查、配置或打开 `can0`。
只有显式运行 `--sink socketcan --interface can0` 时，点击 **连接 ICT** 后，
Gateway 才检查物理 `can0`：已满足 250 kbit/s、
`restart-ms=100`、`txqueuelen=10` 且状态可用时直接绑定；否则通过受限
helper 自动配置并复核。CAN 帧构造和 CSV 录制不受此流程影响。

物理发送采用非阻塞、按 CAN ID 合并的有界 latest-value 队列。USB-CAN
拥塞时允许丢弃已过时的物理遥测帧并保持 ICT 在线；CSV 仍记录全部逻辑帧。
Web 状态页会显示 submitted、sent、拥塞丢弃、合并与终端错误统计。

root helper 使用 `/run/excavatorsim/can0.lock` 串行化完整配置事务。父级 `/run`
必须是 root 所有的真实目录，但兼容目标机的 group/other 可写模式；专属
`/run/excavatorsim` 目录仍必须是 `root:root 0700`，锁文件仍必须是
`root:root 0600` 的单链接普通文件。不安全的既有专属目录、文件或符号链接会在
任何 `ip link set` 前以稳定的 `CAN0_SETUP_FAILED` 拒绝，不会被 helper 自动删除、
改权或接管。若目标机 `/run` 可由普通用户写入且无 sticky-bit 保护，普通用户仍可能
通过反复预占条目造成拒绝服务，但不能借此重定向 helper 的 root 操作。

```bash
# WSL/Linux 出包（gateway + 固定 can0 helper + 安装脚本）
cd tools/can_gateway && ./dist_linux.sh        # 优先 uv，缺 uv 时回退 venv+pip

# 目标机安装阶段：管理员只执行一次；默认授权给 sudo 的原始调用用户
cd dist/can_gateway_linux
sudo ./install_can0_helper.sh                   # 也可显式追加运行游戏的用户名

# 仅显式低延时模式需要安装 helper；默认 TCP 模式不需要 sudo
# 卸载授权（不 down/delete can0，不卸载驱动）
sudo ./uninstall_can0_helper.sh
```

目标机必须已连接 USB-CAN，并由驱动创建 `can0`；helper 不创建设备也不安装
驱动。运行时只调用固定命令
`sudo -n /usr/local/libexec/excavatorsim/can0-setup-helper`，不会在后台等待密码。
缺设备、缺 helper/授权、配置、bind 或 send 失败会回传到游戏 UI。

WSL2 通常没有真实 `can0`，只能用于构建和无硬件测试。构建机 glibc 需不高于目标机。

## 正式发布构建

从仓库根目录运行统一构建器，可重建 Windows/Linux Gateway、导出两个 Godot
平台、把 Gateway 同步到可执行文件旁，并补齐许可证与构建来源清单：

```powershell
.\tools\build_release_dist.ps1
```

最终平台包位于 `godot/dist/windows` 与 `godot/dist/linux`。每个平台包和根目录
下的独立 Gateway 包都包含 `build-manifest.json`；清单记录 Git commit、构建时
工作树是否有未提交内容、软件版本，以及包内每个文件的大小和原始字节 SHA-256。
Linux 正式交付请使用 `godot/dist/ExcavatorSim-linux-x86_64.tar.gz`，该归档显式
保留游戏、Gateway、can0 helper 与安装脚本的 POSIX 执行权限。构建器若发现
旧包目录中的运行日志，会将其移到 `output/release-build-residue`，不会发布或删除。
正式发布前应先提交计划纳入发布的源码，使 `git_tree_dirty` 为 `false`。

## Windows / Linux PC001 TCP（默认 ICT 传输）

两平台默认均使用 can_replay 的 PC001 TCP transport：
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
- 手动运行：`gateway[.exe] --sink tcp --tcp-host 0.0.0.0 --tcp-port 5678`
- 对端：`python3 -m tools.can_replay bridge --host <本机IP> --port 5678 --interface vcan0`

本机开发测试可使用仓库内独立的 PySide6 监视器，无需安装正式 PC001 对端：

```powershell
cd tools/pc001_test_client
uv run --python 3.12 python -m pc001_test_client
```

它默认连接 `127.0.0.1:5678`，显示每帧 CAN ID、EFF/SFF、DLC、payload、
channel、实际接收频率和新鲜度。该工具只接收，不参与 Gateway/Godot 正式发行。
- 未完成 PC001 握手、队列已满或断线时帧会被丢弃并计数；断线自动重等连接，
  旧会话帧不会重放给新客户端。
- 批帧 ≤100 帧（MAX_BATCH_FRAMES），握手超时 10s，语义与参考实现一致。
- CSV 的 `CAN通道` 与 PC001 frame 尾部 i32 使用同一映射：CAN3 DBC 和
  `0x18FFF100` 为 `ch3`/3，CAN4 DBC 为 `ch2`/2，`0x256` 为 `ch0`/0。

## 关键约定

- **随包 CAN3/CAN4 的全部 30 个报文（含 `0x18FFF000`）编码权威 = 批准 DBC**。
  Godot 遥测与 Web 编辑值都调用同一个 hash 绑定的 strict `cantools` codec；
  per-ID authority gate 保证同一 ID 不会交错使用仿真和自定义来源。
- A800 的 `VelE/VelN/VelU/Vel` 现在和 DBC 一致，固定为小端；QML profile
  不再保留历史的大端例外。其余 RTK/IMU 帧经 differential tests 保持原字节。
- Web operator catalog 在启动或显式 reload 时扫描随包 `resources/dbc`、
  gateway 可执行文件相邻 `dbc/` 及 `--dbc-dir` 的直属 `.dbc` 文件。reload
  会重建 Web 统一控制台并保持自定义发送未启动；不会替换 Godot 使用的 hash
  绑定 protocol catalog。回转状态与左右行走压力是整数字段，输入小数会被拒绝，
  不会静默截断。
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
