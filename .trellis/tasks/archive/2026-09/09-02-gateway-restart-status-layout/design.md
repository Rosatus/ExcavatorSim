# Gateway 重启语义与 Web 状态布局修复 — Design

## 1. 状态模型

界面只展示可观测真值，不再使用 “ICT” 聚合多个概念：

```text
Godot UI
  Gateway lifecycle: IDLE / STARTING / STOPPING / FAILED
  Gateway online: owned PID + fresh Gateway heartbeat
  PC001: heartbeat 投影的 who/PC001 handshake

Gateway Web
  Transport: sink readiness
  Godot: recent valid CTN1 telemetry / stale / N/A
  PC001: TCP client handshake
```

`ict_active` 继续作为旧 CTNC lifecycle 的内部兼容字段，但退出产品 UI。删除它会扩大到
control protocol、timed/custom reset 和旧测试迁移，本任务不承担该风险。

## 2. Godot 启动/重启按钮

`GatewayRestartButton` 是 momentary button。handler 顺序固定为：

```text
read edits
  -> bridge.set_tcp_endpoint(host, port)
  -> invalid: retain last valid endpoint/config, show error, stop
  -> persist validated endpoint
  -> bridge.respawn_gateway()
  -> lifecycle-driven disabled/text state
  -> fresh heartbeat: online
```

Bridge 暴露只读 lifecycle（以及是否是 restart transition，如展示所需），不把私有 PID
控制权交给 UI。现有 `_begin_gateway_restart()`、shutdown timeout、owned-PID force kill 和
spawn 流程保持权威。按钮不发送 ICT_START/STOP，不扫描端口，不关闭外部进程。

为避免保存无效输入，endpoint 的 `text_changed -> save` 改成验证成功后保存。持久化文件
格式和默认值不变。

## 3. Gateway 对 Godot 活跃的投影

Gateway owner loop 增加：

```text
GODOT_ACTIVITY_TIMEOUT_S = 2.5
last_godot_telemetry_monotonic_s: float | None
godot_connected: bool | None
```

仅在 `parse_packet(data)` 返回合法 telemetry 后以 `time.monotonic()` 更新时间。不要在
control packet、bad packet、CAN egress 或 PC001 handshake 上更新。

managed 模式按每次 owner-loop/service tick 计算是否仍在窗口内，并只在布尔值改变时
publish，避免 50 Hz revision/event 噪声。standalone 从初始化起保持 `None`。

`GatewayStatus.to_dict()`、`_runtime_status_projection()` 和 TypeScript decoder 同步增加
nullable 字段。React summary 采用：

- managed `true`：`Godot · 已连接`（green）
- managed `false`：`Godot · 未连接`（amber/red，按现有卡片体系）
- standalone `null`：`Godot · 不适用`（muted）

这里的“连接”是近期合法 telemetry 活跃，不是身份认证；Gateway 默认只绑定 loopback，
本任务不升级控制协议认证。

## 4. 固定 CAN 表格

表格继续 `min-width:1260px`、wrapper `overflow-x:auto`，新增 `table-layout:fixed` 和九列
`colgroup`。宽度总和至少覆盖现有最小表宽，优先保证 payload、authority 和 ID 可读；
频率和新鲜度列固定为可容纳最大格式的宽度。

最后两列 cell 使用 `font-mono tabular-nums whitespace-nowrap`。ID/payload 保持不换行或
截断策略；detail row 仍为首个空 cell + `colSpan=8`，不会破坏列结构。

Vitest/jsdom 只验证 DOM/CSS contract 与 freshness 边界，像素宽度由一次人工浏览器验收
验证，因为 jsdom 不执行真实 table layout。

## 5. 兼容与失败行为

- endpoint bind 失败：新 Gateway 退出；bridge 保持 FAILED/离线并给出可操作诊断，未知
  占用者不被终止。
- restart 中重复点击：按钮禁用；`respawn_gateway()` 本身继续合并 STOPPING 请求。
- PC001 在重启时必然断线，handshake 立即清除，客户端自行重连。
- Godot telemetry 暂停超过 2.5 秒只改变 Web 状态，不自动重启、不改变 authority、不停止
  transport。
- 回滚只需恢复 UI toggle、移除 nullable status 字段并恢复 auto table；CAN/protocol 字节
  不发生迁移。

## 6. 验证设计

- Python：status schema/projection nullable 字段；合法/非法/control telemetry 的 2.5 秒
  transition；不依赖 sink/handshake。
- React：三种 Godot 状态、WS delta、删除 ICT 文案；table/colgroup class contract；
  freshness boundary 文本/颜色。
- Godot：momentary button、有效/无效 endpoint、lifecycle 文案、owned restart；复用现有
  endpoint/PID/fresh-heartbeat E2E，不新增视觉自动化。
- 人工：真实浏览器观察新鲜度跨边界不抖动，窄屏只在表内滚动；Godot 按钮完整执行一次
  restart 并观察等待 PC001/握手状态。
