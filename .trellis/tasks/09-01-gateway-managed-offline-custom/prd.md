# Fix Godot-Managed Offline Custom Authority

## Goal

修复 Godot 拉起 Gateway 后，在 Windows TCP listener 已就绪但 PC001 尚未连接或暂时断开时，逐 CAN ID 的“自定义”authority 会立即回退、表现为无法选择的问题。用户应能在当前 Godot-managed 会话中离线配置并保持 `off/custom/simulation`，PC001 恢复连接后按当前 authority 自动继续发送。

## Background And Confirmed Facts

- Godot 以 `--mode godot-managed --sink tcp` 拉起 Windows Gateway；`tcp · ready` 只表示 listener 就绪，`pc001_handshake=false` 表示尚无完成 `who/PC001` 握手的客户端。
- React 三挡控件本身没有按 TCP handshake 禁用 `custom`；除不具备仿真 producer 的 `simulation` 外，仅全局短暂的 `busy` 会禁用按钮（`tools/can_gateway/web/src/components/CanConsole.tsx:239-253`）。
- managed authority API 允许逐 ID mutation，owner loop 也能成功执行 `set_authority(..., "custom")`（`tools/can_gateway/gateway_web.py:290-303`、`tools/can_gateway/gateway.py:752-775`）。
- 当前 custom scheduler 第一次发送时，`send_operator_frame()` 将“未完成 PC001 握手”当成 transport fault，并调用 `reset_managed_overrides()`（`tools/can_gateway/gateway.py:482-505`）；该函数把全部 managed 行恢复为 `simulation/off`（`tools/can_gateway/can_console.py:573-580`）。
- 当前 handshake 从 true 变 false 时还有第二条同类重置路径（`tools/can_gateway/gateway.py:571-585`）。因此 authority mutation 成功后会在下一个调度 tick 或断连检测中被回滚。
- `TcpPc001Sink` 已定义无客户端即安全丢弃、累计 `dropped_no_client`，以及断连后不重放旧帧的行为；无需用 authority reset 实现队列安全。
- 已归档 Gateway Web 任务与现行 spec 明确要求：Godot-managed 允许逐 ID session override；Gateway 在线但无 PC001 client 时控件仍可用。当前行为属于契约回归。

## Requirements

### R1. Preserve Managed Row Authority Across TCP Unavailability

- 在同一个 Godot-managed Gateway 进程内，PC001 尚未握手、暂时断连或随后重连均不得修改任何 CAN ID 已选择的 `off/custom/simulation` authority。
- 选择 `custom` 后立即保存为当前会话的权威状态；不要求 PC001 已连接，也不显示为操作失败。
- 无客户端期间，custom scheduler 可以继续产生到期 occurrence，但传输层按既有 `TcpPc001Sink` 规则安全丢弃；不得为恢复连接缓存或回放历史帧。
- PC001 重新完成握手后，无需用户再次选择 `custom` 或重新保存，当前 custom 行应从其后续周期自然恢复发送。
- Godot-managed override 仍为 session-only；Gateway/Godot 进程重启后继续恢复既有默认 `simulation/off`。

### R2. Preserve Transport And Authority Boundaries

- 将 TCP handshake/readiness 与 per-ID authority 生命周期解耦，但保持 listener、`who/PC001` 协议、batch wire bytes、队列上限及 drop 统计不变。
- 无 PC001 时不得伪造成功 egress：最近 payload、实际频率和 freshness 仍只由成功 `sendall()` 更新；drop counter 继续增长。
- standalone 的全局 Start 仍要求 transport ready，断连后仍按既有安全规则 disarm；本任务不改变其显式 arm 合约。
- Linux SocketCAN terminal error、Gateway shutdown、明确 managed session reset 和 timed CAN 的既有处理保持不变；不得把本次 TCP 临时断连规则扩展为忽略真实终端故障。
- 不改变 CAN ID、DLC、payload、编码、字节序、缩放、EFF packing、CSV、Godot telemetry 或 timed CAN `0x18FFF100` 定义。

### R3. Diagnostics And UI Consistency

- `tcp · ready / PC001 等待客户端` 时逐行 `off/custom` 控件保持可操作；`simulation` 仍只按 `simulation_available` 决定是否可选。
- 页面继续通过现有状态和 drop counter 表达离线；不增加新的 WebSocket endpoint，也不把暂时离线误报为 authority mutation 错误。
- authority 变化继续产生现有 revision、snapshot 与 `can_console_authority_updated` 事件；TCP 断连不得产生虚假的 authority 变化。
- 更新 Gateway 文档/spec，明确“TCP 暂时不可达不重置 managed row override；terminal transport fault 与进程重启仍可重置”的边界。

## Acceptance Criteria

- [x] AC1: Godot-managed + TCP listener ready + `pc001_handshake=false` 时，任意支持 custom 的行切到 `custom` 后，在多个发送周期后仍保持 custom。
- [x] AC2: 上述离线期间 `pc001_dropped_frames` 增长，但该行没有成功 egress、实际频率不被伪造，且不缓存待重放帧。
- [x] AC3: PC001 随后完成握手时，无需再次 mutation，该 custom 行自动发送后续帧并开始产生真实 egress 指标。
- [x] AC4: 已握手 PC001 断开后，managed custom/off overrides 保持；重新连接后仅发送重连后的周期帧，不播放断连期间历史帧。
- [x] AC5: standalone 无客户端 Start 拒绝/断连 disarm、managed 进程重启默认值、SocketCAN terminal retirement、timed CAN 和 CAN wire bytes均无回归。
- [x] AC6: React 快速测试证明 `pc001_handshake=false` 且 drop counter 非零时，逐行 custom radio 仍可点击并发出正确 authority 请求。
- [x] AC7: focused Python/Vitest 测试和一次真实 Gateway 进程 canary 通过；不要求启动 Godot、浏览器视觉测试、soak 或发行包构建。

## Out Of Scope

- 改变 standalone 的显式全局 arm/disarm 模型。
- 为离线帧增加可靠投递、磁盘队列、重放或 PC001 ACK 协议。
- 修改 PC001 drop counter 的现有累计定义或拆分新的前端统计字段。
- 修改 Linux can0/SocketCAN terminal fault recovery。
- 修改 Web 布局、主题、编辑 modal、DBC 内容或 CAN 编码。
- 构建或复制 Windows/Linux/Godot 发行包。
