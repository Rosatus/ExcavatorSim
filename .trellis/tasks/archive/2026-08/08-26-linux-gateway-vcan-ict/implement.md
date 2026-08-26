# Implement — 08-26-linux-gateway-vcan-ict

## Phase 1: 协议与 Python 基础（可独立验证）
- [ ] 1.1 control_protocol.py：CMD_ICT_START=4 / CMD_ICT_STOP=5；HEARTBEAT_FLAG_PLATFORM_LINUX=0x02；build_heartbeat 加 platform_linux 参数（默认 False）；新增 parse_heartbeat_flags
- [ ] 1.2 vcan_setup.py 移植（ensure_vcan_interface + VcanSetupError，保留 runner 注入）
- [ ] 1.3 sinks.py：FrameSink Protocol / CsvFrameSink / SocketCanSink（AF_CAN + can_frame 打包）
- [ ] 1.4 tests/test_vcan_setup.py（runner 注入模式）+ test_sinks.py（mock socket）
- [ ] 1.5 control_protocol 测试补 cmd4/5 与 platform 位用例

## Phase 2: gateway 主循环接入
- [ ] 2.1 CLI：--sink/--interface/--setup-vcan
- [ ] 2.2 emit_frames 泛化为 sinks 列表；ICT 门控 vcan_sink；与 CSV 录制并存
- [ ] 2.3 金样本回归测试跑通（--sink csv 默认路径零变化）
- [ ] 2.4 gateway 主循环单测：ICT 开关/双 sink 并发计数/AF_CAN 错误路径清晰提示

## Phase 3: Godot 桥与 UI
- [ ] 3.1 can_telemetry_bridge.gd：Linux 探测链、心跳 platform 位解析、is_linux_gateway()、_ict_active 状态、cmd4/5 发送
- [ ] 3.2 main.tscn：ICTConnectToggle 按钮
- [ ] 3.3 operator_ui.gd：按钮状态机文案 + disabled 逻辑 + tooltip
- [ ] 3.4 单测：桥平台位解析、e2e 扩展（模拟 linux 心跳）；operator_ui 按钮态

## Phase 4: 打包与收尾
- [ ] 4.1 dist_linux.sh（venv+pyinstaller→dist/can_gateway_linux/gateway，ELF 校验）
- [ ] 4.2 WSL 内执行出包并冒烟（--help/--smoke 进程启动/setup-vcan 错误路径）
- [ ] 4.3 README 更新：发布结构（exe+gateway）、WSL 构建用法、glibc 提示
- [ ] 4.4 全量回归：Python 22+N 用例绿；Godot 矩阵（跳 terrain_collider_chunk）绿
- [ ] 4.5 trellis-check → spec 更新 → commit → finish-work
