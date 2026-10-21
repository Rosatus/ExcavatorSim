# Gateway 重启语义与 Web 状态布局修复

## Goal

消除 Godot 与 Gateway Web 中混淆 Gateway 进程、Godot 遥测链路、TCP listener
和 PC001 对端握手的 “ICT 已连接” 表述，并修复 CAN 实时表因新鲜度字符串变化产生的
列宽抖动。操作员应能安全地启动或重启本 Godot 实例托管的 Gateway，并从两端看到
各层真实、可区分的运行状态。

## Background

- Godot 当前的 `ICTConnectToggle` 会验证 endpoint、发送 `CMD_ICT_START/STOP`，但
  Godot-managed Gateway 在进程启动时已经创建 TCP listener，且 TCP egress 不以
  `ict_active` 为 gate。因此它不等同于连接或断开 PC001，会产生安慰剂式体验。
- `CanTelemetryBridge.respawn_gateway()` 已拥有 graceful shutdown、bounded force-kill、
  respawn 和 fresh-heartbeat readiness；强制终止仅针对该 bridge 由
  `OS.create_process` 获得并仍持有的 PID。
- Web 运行摘要将 `ict_active` 显示成 “ICT 已连接/未连接”，但该字段既不代表 Godot
  遥测活跃，也不代表 PC001 handshake。
- CAN 表格使用浏览器默认的 `table-layout:auto`。新鲜度虽然封顶为 `>999s`，但
  `9.999 ms`、`999.999 ms`、`1.000 s` 等字符串宽度仍不同，50 ms ticker 会持续
  触发整表列宽重新分配。

## Requirements

### R1 — Godot Gateway 操作语义

- 将 Godot 的 “连接/断开 ICT” toggle 替换为普通的 Gateway 启动/重启按钮。
- 点击时先校验当前 TCP host/port；只有校验成功才持久化 endpoint 并请求
  `respawn_gateway()`。
- 在线时显示 “重启 Gateway”；无进程或失败时显示 “启动 Gateway”/“重试启动
  Gateway”；启动、停止或重启期间显示准确进行中文案并禁用重复点击。
- 重启成功仅表示新 Gateway 子进程已通过 fresh heartbeat 就绪。PC001 是否连接必须
  继续由 `who`/`PC001` handshake 单独展示，不得在重启后宣称 “ICT 已连接”。
- 移除场景和 operator UI 中 “需 Linux 网关”“连接 ICT”“断开 ICT” 等已过时文案。

### R2 — 进程安全边界

- 继续由 `CanTelemetryBridge` 独占 Gateway 子进程 PID 与生命周期。
- 正常重启先发受控 shutdown；超时后只允许终止当前 bridge 创建并持有的精确 PID。
- 禁止按端口、进程名或模糊 argv 搜索并终止进程；未知端口占用者必须转成可操作的
  Gateway 启动失败诊断。
- 不新增跨会话 stale Gateway 自动接管、PID 文件或 control-protocol token；这些需要
  独立安全设计。

### R3 — Web 中的 Godot 连接状态

- 删除 Web 运行摘要中的 “ICT” 状态卡。
- 新增 typed `godot_connected` 状态：
  - `godot-managed` 下，Gateway 在最近 2.5 秒内收到一份合法 CTN1 Godot telemetry
    时为 `true`，尚未收到或超时时为 `false`；
  - `standalone` 下为 `null`，页面显示 “不适用（独立启动）”。
- 使用 Gateway 本地 monotonic receive time 判定活跃，不使用 Godot payload tick、
  PC001 handshake、`ict_active`、transport readiness 或 CAN egress 反推。
- 合法 telemetry 一经解析便刷新活跃时间，即使没有 PC001 客户端、没有 active sink
  或对应 CAN authority 已关闭。
- 字段必须贯通 Gateway status snapshot、实时 status projection、WebSocket typed
  decoder 和 React summary，使断连/恢复无需刷新页面即可更新。
- `PC001` 卡继续单独表示客户端 handshake；`传输` 卡继续表示 TCP/SocketCAN
  readiness。旧 `ict_active` 可保留在内部协议/API 以兼容既有流程，但不再作为 Web
  或 Godot 用户界面的连接真值。

### R4 — CAN 表格布局稳定性

- 保持一个共享 50 ms freshness ticker，不通过降低刷新率掩盖布局问题。
- 表格采用固定布局，并以九列 `colgroup`（或等价单一权威）明确展开、CAN ID、
  channel、payload、编辑、发送权威、预期频率、实际频率和新鲜度宽度。
- 新鲜度与频率使用不换行、等宽/表格数字；`999.999 ms`、`999.000 s` 和 `>999s`
  的切换不得改变表格或相邻列宽。
- 保留最小表宽和表格区域横向滚动；窄窗口不得改为列换行、隐藏关键值或让整个页面
  随 ticker 横向跳动。

### R5 — 兼容与范围约束

- 不修改 PC001 wire framing、CAN ID/DLC/payload/channel、DBC 编码、authority、
  TCP listener 常驻和 offline-drop/no-replay 语义。
- 不改变 standalone Web transport 配置，也不恢复 Linux SocketCAN 为默认路径。
- 显式 SocketCAN/can0 低延时模式继续保持当前独立入口；Godot 默认托管按钮只负责
  Gateway 进程，不伪装成 can0 操作。
- 更新 Gateway control spec，使旧 ICT toggle/host-OS transport 条款不再与当前
  TCP-default、active-transport 能力契约冲突。

## Acceptance Criteria

- [ ] AC1：Godot UI 中不存在可见的 “连接 ICT/断开 ICT” toggle；在线、离线、启动、
  重启、失败状态分别给出符合实际的 Gateway 按钮文案与 enable 状态。
- [ ] AC2：有效 endpoint 点击后保存并启动/重启；无效 endpoint 不写配置、不更改
  desired endpoint、不重启进程，并显示稳定诊断。
- [ ] AC3：重启从 graceful shutdown 开始，必要的 force kill 仅以 bridge-owned PID
  为目标；代码不存在按端口/名称杀进程的新路径。
- [ ] AC4：重启完成后必须收到新 heartbeat，PID 已替换且旧 handshake 投影被清除；
  页面仍显示 PC001 “等待客户端”，直至真实 handshake。
- [ ] AC5：managed Gateway 收到合法 telemetry 后 `godot_connected=true`，停止收到
  2.5 秒后变为 false，再收到后恢复；非法包和单独 control command 不得保活。
- [ ] AC6：standalone status 为 `godot_connected=null`，Web 显示中性“不适用”；
  managed Web 的 Godot 状态能通过实时 delta 在断连/恢复时更新，无需 HTTP 刷新。
- [ ] AC7：Web 运行摘要不再显示 `ICT` 卡；PC001 handshake 与 transport readiness
  仍保持各自独立、含义不变。
- [ ] AC8：CAN 表具有九列固定布局；新鲜度跨越毫秒位数、ms/s 和 `>999s` 边界时，
  表格及新鲜度/实际频率列宽不变化。
- [ ] AC9：桌面宽度可直接阅读，窄窗口只在表格容器内横向滚动；展开详情仍正确跨越
  其余八列。
- [ ] AC10：focused Python、React、Godot lifecycle/UI 测试通过；最终只执行一次相关
  Gateway/Godot headless E2E。实际像素级无抖动与窄屏滚动由人工浏览器验收。

## Out of Scope

- 自动查找、接管或杀死占用目标端口的未知进程。
- 为残留 Gateway 引入跨进程 owner record、instance token 或控制协议认证升级。
- 让 Gateway 主动建立 PC001 TCP 连接；它继续作为服务端等待客户端。
- 修改 CAN 数据、Web 报文编辑器、发送频率、authority 或发布包内容。
