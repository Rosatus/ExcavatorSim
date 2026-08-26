# Implement — 08-26-gateway-pc001-tcp-ict

## Phase 1: Python TCP sink
- [ ] 1.1 pc001_sink.py：TcpPc001Sink（listen/who-PC001 握手/批帧/断线容错/后台线程）
- [ ] 1.2 tests/test_pc001_sink.py：握手、批帧字节、拒绝、分批、重连、幂等 close
- [ ] 1.3 gateway CLI：--sink tcp + --tcp-host/--tcp-port；ICT 门控接线

## Phase 2: Godot 面板与桥
- [ ] 2.1 main.tscn：ICTHost/ICTPort 输入框
- [ ] 2.2 operator_ui.gd：持久化 user://ict_config.cfg；按钮解除 linux-only；tooltip 按 transport
- [ ] 2.3 can_telemetry_bridge.gd：tcp_host/tcp_port 属性 + Windows spawn argv 注入 --sink tcp

## Phase 3: e2e 与文档
- [ ] 3.1 本机 e2e 冒烟脚本（最小客户端握手收帧）
- [ ] 3.2 README tcp 用法 + 协议字节图
- [ ] 3.3 全量回归（Python 单测 + 矩阵）

## Phase 4: 收尾
- [ ] 4.1 trellis-check → spec 更新 → commit → finish-work
