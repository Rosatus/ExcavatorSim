# 08-26-gateway-pc001-tcp-ict

## Goal

为 Windows 版 gateway 增加与 Linux vcan 同级的 ICT 连接能力：实现 dev_arch
can_replay 的 PC001 TCP transport（gateway 作 TCP 服务端，ICT 侧用现成
socket_bridge 客户端接入），游戏面板可配置 IP/端口并持久化，使 ICT 按钮在
Windows 网关下同样生效。

## Background

- 协议（`dev_arch2.0_36b5586c/tools/can_replay/socket_bridge.py` + `pc001_server.py`）：
  - 服务端 accept 后发 `b"who"`；客户端回 `b"PC001"` 完成握手
  - 数据帧：`[u16 LE count] + count × [can_frame(16B LE) + channel(i32 LE)]`
  - 单批 ≤100 帧（MAX_BATCH_FRAMES）
  - 参考服务端 `Pc001ReplayServer` / 打包 `pack_batch` / 客户端桥 `bridge_to_vcan`
- Windows 上无 SocketCAN → TCP 是唯一 ICT 通道；Linux 端 vcan 路径保持不变。
- 配置位置决策：**Godot 面板输入框 + user:// 持久化**（spawn argv 注入 gateway），
  不用 exe 目录配置文件——与现有"bridge 是唯一监督者、参数走 argv"模型一致，
  现场人员无需找安装目录。CLI 参数仍保留且优先。

## Requirements

### R1 Python：TcpPc001Sink
- 新文件 `tools/can_gateway/pc001_sink.py`：
  - 监听 tcp_host:tcp_port（默认 0.0.0.0:5678）；握手 who/PC001；
  - `append(can_id, payload)` 攒 batch（≤100），flush 按 emit 节拍或每 tick；
  - 客户端断开后继续运行，等下一次连接（容错，不 crash）；无客户端时静默丢弃帧；
  - 实现 FrameSink 协议（append/close）；close 关闭 server+client。
- CLI：`--sink {csv,vcan,tcp}`、`--tcp-host`（默认 0.0.0.0）、`--tcp-port`（默认 5678）。
- 线程模型：后台线程跑 accept/发送（主循环保持 UDP recv 不被阻塞），或 asyncio
  loop in thread —— 以最简可靠为准。

### R2 Godot：ICT 面板配置
- AdvancedPanel 增加 ICTHost LineEdit（默认 "0.0.0.0"，占位提示）与 ICTPort
  （默认 "5678"）；持久化到 `user://ict_config.cfg`（ConfigFile），启动加载。
- ICT 按钮：Windows 与 Linux 网关均可用；tcp 分支下按钮文案不变
  （连接 ICT / 断开 ICT）；tooltip 说明当前 transport（TCP :port 或 vcan）。
- bridge spawn argv 注入 `--tcp-host/--tcp-port`（仅当 sink=tcp 时传）。
- 平台位语义调整：不再以 platform 限制按钮——改为只要网关在线即可连 ICT；
  tooltip 提示 Windows=TCP / Linux=vcan。心跳平台位继续上报用于 tooltip。

### R3 测试与文档
- pc001_sink 单测：握手成功/握手拒绝/批帧字节格式（对照 pack_batch）/断线重连容忍/
  超 100 帧分批。
- e2e 冒烟：本机起 gateway --sink tcp，用最小 TCP 客户端完成握手并断言收到帧。
- README：tcp 模式用法 + 协议字节图 + 与 socket_client_to_vcan.sh 对接说明。

## Acceptance Criteria

- [ ] Python 单测全绿（含新增 pc001_sink 用例）；金样本回归不受影响
- [ ] 本机 e2e：gateway --sink tcp ← 最小客户端握手成功并收到正确字节流帧
- [ ] Godot e2e 全 PASS；ICT 按钮在模拟 Windows 网关下 enabled
- [ ] 面板 IP/port 修改后重启游戏仍保留；spawn argv 含 --tcp-host/--tcp-port
- [ ] 矩阵（排除既有基线失败脚本）全绿

## Non-goals

- 修改 ICT 侧任何代码（复用对方 socket_bridge）
- TLS/鉴权（内网工具，明文即可）
- 多客户端并发（沿用参考实现单客户端语义：新连接顶替旧连接）
