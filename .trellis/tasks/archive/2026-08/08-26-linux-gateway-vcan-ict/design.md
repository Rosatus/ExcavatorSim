# Design — 08-26-linux-gateway-vcan-ict

## 1. 总体决策

| 决策 | 结论 | 理由 |
|---|---|---|
| 代码组织 | 单代码库 + FrameSink 抽象，**不 fork** | gateway 是零第三方依赖纯标准库；平台差异只在输出端 |
| SocketCAN 实现 | 抄 dev_arch `vcan_client.py::VcanClient`（AF_CAN CAN_RAW + 16B can_frame） | 用户钦定参考；纯标准库；已被实采验证 |
| vcan 设置 | 移植 `vcan_setup.py::ensure_vcan_interface`（含 sudo 探测/并发容错） | 同上 |
| 平台检测 | CTNK flags bit1=platform_linux | 心跳已有 flags+reserved 结构，加一位零成本；Godot 无需额外协议 |
| WSL 角色 | 仅构建产物（PyInstaller onefile ELF） | WSL2 默认内核无 CONFIG_CAN/VCAN，运行时验证放真实 Linux |

## 2. Python 侧

### 2.1 FrameSink 抽象（新文件 `tools/can_gateway/sinks.py`）

```python
class FrameSink(Protocol):
    def append(self, can_id: int, payload: bytes) -> None: ...
    def close(self) -> None: ...

class CsvFrameSink:            # 包 CanapeCsvWriter，暴露 row_count/path
class SocketCanSink:           # AF_CAN；构造参数 (interface, setup_check=True)
```

- `SocketCanSink.__init__`：`socket(AF_CAN, SOCK_RAW, CAN_RAW)` → 失败抛 `RuntimeError`（文案抄 VcanClient：AF_CAN 不可用=vcan 不支持）；`bind((interface,))` 失败给 setup 指引。
- can_frame 打包：`struct.pack("<IBBBB8s", can_id, dlc, 0, 0, 0, data.ljust(8, b"\x00"))` —— 与 pc001_server.CAN_FRAME_STRUCT 对齐（小端平台验证过的格式）。
- 发送失败策略：`send` 异常向上抛 → gateway 主循环打印并继续（不 crash，与 CSV 容错一致）。

### 2.2 vcan_setup 移植（新文件 `tools/can_gateway/vcan_setup.py`）

- 从 dev_arch 原样移植 `ensure_vcan_interface` / `VcanSetupError` / `_interface_status` / `_sudo_prefix`，去掉 uv 包装层。
- runner 注入签名保留（测试直接抄 dev_arch 的注入写法：假 geteuid/which/runner）。

### 2.3 gateway.py 改动

- CLI 增加：`--sink {csv,vcan}` 默认 csv；`--interface vcan0`；`--setup-vcan`（执行 ensure 后退出）。
- ICT 与录制解耦：
  - `writer`（CSV）仍由 RECORD_START/STOP 门控
  - 新增 `vcan_sink: SocketCanSink | None` 由 ICT_START/ICT_STOP 门控
  - emit_frames 遍历 active sinks：`sinks = [s for s in (csv_sink, vcan_sink) if s]`
- CSV 路径下 CanapeCsvWriter.append 签名不变；emit_frames 参数从 `writer: CanapeCsvWriter` 泛化为 sink 列表。

### 2.4 控制协议（control_protocol.py）

- 新命令字：`CMD_ICT_START = 4`、`CMD_ICT_STOP = 5`
- 心跳 flags：`HEARTBEAT_FLAG_PLATFORM_LINUX = 0x02`；`build_heartbeat(tick_ms, recording, platform_linux=False)`（默认 False 保持旧调用兼容）
- parse_heartbeat 返回三元组或新增辅助函数——选**新增 `parse_heartbeat_flags(data) -> (recording, platform_linux, tick_ms)`**，原函数保留。

## 3. Godot 侧

### 3.1 can_telemetry_bridge.gd

- `_resolve_gateway_command()`：按 `OS.get_name()` 分支 —— Windows 保持现有链；Linux 找 `exe_dir/can_gateway/gateway` → `gateway`（PATH 兜底走脚本链不变）。
- 心跳解析处读取 platform 位 → `var _gateway_is_linux := false` + `func is_linux_gateway() -> bool`。
- 状态机扩展：OFFLINE/ONLINE/RECORDING 不变；新增 ICT 子状态 `var _ict_active := false`（独立于 recording，可并存）。
- 控制发送：复用 CTNC 编码路径，cmd 4/5。
- headless 保护/惰性 socket 等既有机制不动。

### 3.2 operator_ui.gd + main.tscn

- Tools 行加 `ICTConnectToggle`（Button），StatusPanel 样式同 CANOutputToggle。
- 文案状态机：
  - bridge offline 或非 linux：`连接 ICT（需 Linux 网关）` disabled=true
  - linux 在线未激活：`连接 ICT` enabled
  - 已激活：`断开 ICT`
- tooltip 动态说明（Windows 下："当前网关为 Windows 版，仅输出 CSV；Linux 版支持 vcan 直发"）。

## 4. 打包

### 4.1 dist_linux.sh（新文件 tools/can_gateway/dist_linux.sh）

```
用法: wsl bash -c "cd /mnt/e/projects/ExcavatorSim/tools/can_gateway && ./dist_linux.sh"
步骤:
1. python3 --version ≥ 3.10 校验
2. python3 -m venv .venv-linux（幂等）
3. .venv-linux/bin/pip install pyinstaller
4. .venv-linux/bin/pyinstaller --onefile --name gateway --distpath ../../dist/can_gateway_linux --workpath build/linux --specpath . gateway_entry.py（入口同 Windows 版打包用的包装脚本）
5. file 校验 ELF → chmod +x
6. 失败时清理 .venv-linux 提示重试
```

### 4.2 发布结构

```
<game>/
  ExcavatorSim.exe (+pck)
  output/can_gateway/
    gateway.exe          # Windows: CSV 输出
    gateway              # Linux:   vcan 直发 (--sink csv 也可)
```

## 5. 测试计划

| 层 | 用例 |
|---|---|
| sinks 单测 | CsvFrameSink 包装行为；SocketCanSink mock socket：构造失败文案/bind 失败指引/append 帧 16B 格式/close 幂等 |
| control_protocol | cmd 4/5 往返；心跳 platform 位编解码；旧版心跳兼容解析 |
| vcan_setup | 抄 dev_arch runner 注入模式：接口已存在 UP/存在 DOWN/不存在创建/非 vcanN 拒绝/无 sudo 报错 |
| gateway 主循环 | ICT_START 开 sink→帧双写（mock sink 计数）/ICT_STOP 关闭/ICT 与 RECORDING 并存 |
| Godot e2e | can_gateway_e2e_test 扩展：模拟 linux 平台位 → is_linux_gateway()==true；Windows 下按钮态单测（operator_ui 层） |
| 金样本回归 | golden_capture 断言不变（--sink csv 默认路径零改动证明） |
| 冒烟 | WSL 内 `./gateway --smoke --help` 可执行；`--setup-vcan` 在无 vcan 内核给出清晰错误 |

已知不测：WSL 内真实 vcan 收发（内核限制，Non-goal）。

## 6. 风险

| 风险 | 缓解 |
|---|---|
| WSL 内核无 vcan → 出的包无法本机自测 | 冒烟只验证进程启动/--help/AF_CAN 错误路径；真机验收 |
| PyInstaller onefile 在 glibc 新发行版打的包老机器跑不起来 | dist_linux.sh README 注明"建议在与目标机同代发行版构建"；后续可加 docker ubuntu:20.04 选项 |
| emit_frames 泛化改动触碰金样本路径 | 金样本测试是守门员，先跑后改再跑 |
