# Fix Godot-Managed Offline Custom Authority — Technical Design

## 1. Root Cause And Design Principle

当前代码使用同一个 `transport_ready()` 判断两件不同的事：

1. 当前是否可能成功 egress；
2. managed row authority 是否应继续存在。

对于 TCP，`pc001_handshake=false` 只回答第一个问题，不代表 Gateway owner、listener 或 session authority 失效。正确边界为：

```text
row authority (session state) ──> custom scheduler ──> TcpPc001Sink
          │                              │                 │
          └─ 不随 handshake 改变          └─ 周期继续         ├─ client: sendall + egress
                                                           └─ no client: drop + counter
```

TCP sink 自己拥有无客户端丢弃和断连清队列语义；authority manager 不再借助全局回退清理 TCP backlog。

## 2. Runtime State Transitions

### 2.1 Initial No-Client State

- managed row 从 `simulation/off` 切到 `custom` 后，`CanConsoleRuntime._update_schedule()` 继续立即 arm custom scheduler。
- `send_operator_frame()` 对 managed `TcpPc001Sink` 不以 handshake false 为 reset 条件，而是将 occurrence 交给既有 sink。
- sink 无客户端时立即计入 `dropped_no_client`，不加入 pending replay 队列；egress tracker不更新。

### 2.2 Connected → Disconnected

- `refresh_runtime_status()` 仍发布 `pc001_disconnected` 和更新 handshake/status。
- managed 模式不调用 `reset_managed_overrides()`，不改变 scheduler/authority/revision。
- standalone 保留当前 disconnect disarm 行为。
- `TcpPc001Sink` 保留清理 pending batch 和 `dropped_disconnect` 统计，因此重连不会回放旧帧。

### 2.3 Reconnection

- 握手成功只更新 transport status/event，不修改 authority。
- 已保持 armed 的 managed custom scheduler 在下一到期 slot 发送新 occurrence；skip-missed-slot 规则保证不会补发断连期间所有 cadence。
- egress tracker仅在新 `sendall()` 成功后恢复 payload、actual Hz 和 freshness。

### 2.4 Terminal And Explicit Reset

- 保留 `CanConsoleRuntime.reset_managed_overrides()`，供 Gateway shutdown/session replacement、SocketCAN terminal retirement或其它明确终端边界调用。
- 不改变 `retire_failed_socketcan()`；本任务只移除 TCP handshake absence/disconnect 对 managed authority 的隐式 reset。
- standalone `CanConsoleRuntime.start(transport_ready=...)` 继续要求 ready，避免改变重启即发或离线 arm 的产品安全边界。

## 3. Code Boundaries

- `tools/can_gateway/gateway.py`
  - 分开“standalone arm readiness”和“managed TCP occurrence delivery”判断。
  - 修改 `send_operator_frame()` 的 no-handshake 分支，使 managed TCP 交由 sink drop，而不重置 console。
  - 修改 handshake transition 处理：managed disconnect 只更新 status/event；standalone仍 stop/disarm。
- `tools/can_gateway/can_console.py`
  - 预计无需改变 authority/scheduler 模型；`reset_managed_overrides()` 仍保留并只由真正 reset boundary 调用。
- `tools/can_gateway/pc001_sink.py`
  - 预计无需产品代码修改；现有 no-client drop 和 disconnect purge 是本设计依赖的 transport contract。
- React
  - 预计无需产品代码修改；补 regression test 锁定 no-handshake 状态下 custom radio 可用。若测试暴露 `busy` 卡死等独立问题，回到规划而不是顺带扩 scope。

## 4. Observability

- 离线 custom occurrence 继续反映在 `pc001_dropped_frames`，与 Godot simulation 当前离线统计一致。
- `can_console_authority_updated` 只由用户 mutation 产生；handshake disconnect 不伪造 authority event或 revision bump。
- `actual_frequency_hz`、last successful payload 和 freshness只由成功 transport egress更新，离线丢弃不能刷新。
- 不新增逐帧日志、事件类型或 WebSocket 通道。

## 5. Compatibility And Rollback

- PC001 wire、queue capacity、batch service、no-replay、CAN codec与所有平台参数保持原样。
- 最窄回滚点集中在 `gateway.py` 两个状态分支；若 managed reconnect 回归，可恢复这两个分支而不触碰 encoder/sink。
- spec 中旧的“managed transport disconnect 强制回退”表述需收窄为 terminal/explicit reset，避免未来再次恢复本缺陷。

## 6. Risks

- 若绕过 handshake 判断时错误地直接标记成功，会污染实际频率/新鲜度；必须通过 `TcpPc001Sink.submit()` 的既有 drop seam，而不能调用 egress observer。
- 若 managed 和 standalone 共用同一修改分支，可能破坏 standalone 的显式 arm 安全；测试必须分别覆盖两种 mode。
- 重连瞬间可能有一个新周期帧很快到达，但不得有断连期间 backlog；no-replay 由 sink 单测和进程 canary共同验证。

