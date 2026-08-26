# Implement: CAN telemetry gateway

## Checklist

### Phase 1 — Godot 遥测桥（R1/R2/R7）
- [x] `godot/client/scripts/can_telemetry_bridge.gd`：autoload；NodePath 注入 MotionPresentation / ChassisMotionRoot；`process_physics_priority = 110`
- [x] 184B 小端包打包（magic CTN1/v1）+ PacketPeerUDP sendto localhost:29764，分频输出
- [x] `project.godot` 注册 autoload（唯一允许的现有文件改动）
- [x] 验证：headless 跑一个本地 UDP 收包脚本收满 184B、五刚体四元数模长≈1、履带字段随输入变化

### Phase 2 — Python gateway 骨架（R3/R5）
- [x] `tools/can_gateway/gateway.py`：recv 循环 + 参数解析 + 会话分段 CSV
- [x] `tools/can_gateway/csv_writer.py`：CANape 方言列头/格式（UTF-8-sig、`="HH:MM:SS.mmm"`、`x| ` 数据）
- [x] `tools/can_gateway/conventions.py`：quat→ZYX 欧拉、MOUNTING_REMAP 表、ENU→WGS84 原点配置

### Phase 3 — 编码器（R4）
- [x] `encoders/ruifen_imu.py`：4 帧 RPY LE 编码 + 禁零计数保护（count=0 → 用 count=1 即 −179.99°）
- [x] `encoders/dxg_slew.py`：counts/STA
- [x] `encoders/sinan_rtk.py`：A000/A100/A200~A700/A800/A900 大端族（位段从 parseSinan* 抄录）
- [x] `encoders/travel_pilot.py`：0x256 标准帧 ±9 语义
- [x] 每个编码器配参考解码器（仅测试用，公式逐行对照 protocolparser.cpp）

### Phase 4 — 金样本测试（R6）
- [x] 夹具：从 dev_arch2.0 `docs` 同源实采 CSV 按 ID 各抽 ≥20 行（含 18FF3A~3D00、18FFF000）
- [x] decode→re-encode 字节级相等断言（RTK 帧若实采中存在同样纳入；不存在则以 parser 单测值合成夹具并注明）
- [x] 合成扫描往返：瑞芬 ±179.99° 全域步进 ≤0.01°；回转全域 ≤1 LSB
- [x] 行走语义：±9→bodyMoving true / 0→false（走参考解码）
- [x] 冒烟：gateway 产出的 CSV 喂 dev_arch2.0 `read_can_csv()` 零异常（测试内以路径约定引用对方仓库，缺仓则 skip）

### Phase 5 — 收尾（R7）
- [x] ExcavatorSim standalone matrix 24/24
- [x] `git diff --stat` 确认除 project.godot 与新增文件外零改动
- [x] README（tools/can_gateway/README.md）：用法、端口、原点配置、标定表说明

## Validation Commands

```powershell
# ExcavatorSim 测试矩阵
powershell -ExecutionPolicy Bypass -File godot/client/tests/run_standalone_matrix.ps1 -GodotExe "E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe"
# Python 测试（标准库 unittest，无需 uv 环境）
python -m pytest tools/can_gateway/tests -q   # 或 python -m unittest discover -s tools/can_gateway/tests
# 冒烟
python tools/can_gateway/gateway.py --smoke   # 自发自收 3 秒产出样例 CSV
```

## Risky Files / Rollback Points

- `godot/client/project.godot`：唯一被改的现有文件（+1 行 autoload）；回滚 = 删该行
- 新文件全部集中在 `scripts/can_telemetry_bridge.gd` 与 `tools/can_gateway/**`

## Follow-ups before task.py start

- 无阻塞项；RTK A000/A100 具体位段在 Phase 3 实现期从 protocolparser.cpp 现场抄录（已列入 checklist）

### Phase 6 — v2: 独立进程监督 + 面板控制（用户裁定架构）
- [x] 控制协议 control_protocol.py（CTNC 控制/CTNK 心跳）+ 单测
- [x] gateway.py 录制门控、分段 CSV、SHUTDOWN、心跳；Windows UDP ConnectionReset 修复
- [x] bridge：create_process 拉起 + 心跳状态机(OFFLINE/ONLINE/RECORDING) + set_recording
- [x] headless 禁自动 spawn（子进程继承 stdout 管道会挂死引擎退出）；惰性 _udp（无场景不发包，修退出崩溃 0xC0000005）
- [x] main.tscn 加 CANOutputToggle 按钮 + CANStatus 标签；operator_ui.gd 接线
- [x] tests/can_gateway_e2e_test.gd（spawn→心跳→录制→落盘→停止全链路）注册矩阵第 25 号
- [x] 矩阵 31 脚本通过（terrain_collider_chunk 为基线既有失败，已用 stash 对照证明）