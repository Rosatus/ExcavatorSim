# Gateway Web CAN Console Redesign

## Goal

将 Gateway Web 后台改造成 Windows/Linux 一致的逐 CAN 报文实时控制台：在一个紧凑的可展开表格中查看最近传输 payload、物理量、目标/实际频率和新鲜度，并通过明确的“关闭 / 自定义 / 仿真”三态选择每个 CAN ID 的唯一发送权威。独立启动时允许持久化与导入/导出自定义设置；Godot 拉起时默认使用仿真值但允许逐 ID 临时覆盖。

## Background And Confirmed Facts

- 技术栈保持 React 18、Tailwind 和现有 shadcn 风格组件；页面继续由 Gateway 内嵌并仅监听 `127.0.0.1:29777`。
- 现有 `GET /api/v1/dbc`、revision-aware owner-loop mutation、payload/physical-value 双向 preview/save、1..100 Hz 单报文整数频率和 `/api/v1/events` WebSocket 可复用。
- 现有 WebSocket 是有界事件回放/推送通道，足以扩展实时行状态；无需仅为本需求增加第二个 WebSocket endpoint。
- 现有每秒 transmission aggregate 不能精确产生“最近 10 次发送平均间隔”与 freshness；需在真实 transport-egress seam 保存每 ID 的有界 monotonic 时间序列，并通过初始快照 + WebSocket 增量发布。
- “实际发送”只能表示 Gateway transport egress：SocketCAN 为本地非阻塞 `send()` 成功，TCP 为 `sendall()` 完成；两者都不能声称获得物理 CAN 总线 ACK。
- Godot telemetry 和 Web 自定义值已经共享 Gateway 发送核心及部分严格 DBC codec，但当前是独立 source/schedule，重叠 ID 没有稳定仲裁；本任务必须建立同一 CAN ID 的单一 authority，而不能依赖 SocketCAN coalescing 的 last-writer 行为。
- 随包 DBC 覆盖 Godot RTK `0x0CFDA000..0x0CFDA900` 和 IMU `0x18FF3A00..0x18FF3D00`；Godot 还发送非 DBC operator-catalog 的回转 `0x18FFF000` 与行走 `0x256`。已批准将这四类持续遥测都纳入控制台及三态 authority；timed CAN `0x18FFF100` 保持独立命令触发，不进入三态仲裁。
- 当前 persisted DBC draft 已原子保存 canonical payload、enabled 和 frequency；armed 状态不持久化。当前 Godot-managed Web mutation 全部 403，本需求将有意修改其中逐报文 authority/custom 编辑边界，但仍不开放 transport mutation。
- 附图仅用于说明宽表、行控制和留白比例，不作为未明示字段、颜色或交互的额外规范。

## Requirements

### R1. Row Console Layout

- 主内容使用逐 CAN 报文的宽表/列表，至少包含：展开控件、CAN ID、最近一次 transport-egress payload、编辑按钮、三态 authority 控件、预期发送频率、实际发送频率、新鲜度。
- 点击行首三角展开/收起该报文的物理量明细；展开状态属于浏览器展示状态，不改变 Gateway 配置。
- 编辑按钮打开 modal；上半区为当前物理值输入，下半区为 raw payload 输入及该报文频率，右下角保存。
- 保留现有 value → payload 与 payload → value 双向 preview、exact-DLC 校验、DBC 边界校验、未建模 bit 保留和显式保存语义。
- 支持亮/暗主题切换；主题偏好在本机浏览器持久化，并在首次访问时采用系统偏好。
- 表格需在窄屏时保持可用，可横向滚动或压缩非关键列，但不得丢失 CAN ID、authority 和 freshness。

### R2. Three-State Per-ID Authority

- 每个纳入控制台的 CAN ID 恰有一个状态：`off`（不提交该 ID）、`custom`（使用保存的 payload/频率周期发送）、`simulation`（使用 Godot telemetry producer）。同一 ID 不允许 simulation/custom 交错发送。
- Godot-managed 启动时，所有可仿真的 ID 默认 `simulation`；用户可在该会话内逐 ID切换 `off` 或 `custom`，且 custom 时可编辑并保存到当前会话。
- Godot-managed 仍只提供平台对应 transport，不开放 TCP 重配、can0 restart、DBC reload/import/export 或其他全局 transport mutation。
- Standalone 不存在 Godot telemetry 输入，因此 `simulation` 挡位保持可见但禁用并解释原因；只允许 `off/custom`，不可显示一个实际无 producer 的仿真状态。
- authority mutation 必须走 Gateway owner loop、revision/request-id 合约，并原子 gate simulation producer 与 custom scheduler。
- DBC 覆盖的 RTK/IMU 使用共享严格 DBC codec 完成物理量与 payload 双向转换；回转/行走复用现有专用 encoder/decoder adapter 暴露物理量编辑，不改变其 CAN ID、DLC、payload、端序、缩放或 EFF packing。
- timed CAN `0x18FFF100` 不出现在三态控制行中，继续由既有显式命令独立触发。
- Standalone 保留一个 session-level“开始/停止自定义发送”控制。重启时恢复各行 `off/custom` 选择和编辑值，但保持全局 disarmed；只有显式点击开始后 custom 行才周期发送。
- Godot-managed 不使用 standalone 的全局 arm：simulation 行按既有遥测生命周期发送，某行显式切到 custom 后在当前会话立即由 custom scheduler 接管该 ID。

### R3. Realtime Metrics

- 每行显示该 ID 最近一次成功 transport-egress 的 payload；在尚无成功发送时显示明确的无数据状态，不得用 configured draft 冒充已发送 payload。
- 预期频率来自当前 active authority：custom 使用单报文配置频率；simulation 使用对应 Godot producer 的目标 cadence；off 为 0/关闭。
- 实际频率按该 ID 最近 10 次成功 transport-egress 的平均间隔计算；少于 2 次时显示无可用频率，不伪造 0 Hz。
- 新鲜度基于 server monotonic last-egress timestamp，客户端实时递增显示：小于 1 s 用 ms，大于等于 1 s 用 s，大于 999 s 显示 `>999s`；正常可读数值显示三位小数。
- 颜色阈值：`0 <= age < 100 ms` 绿色，`100 ms <= age < 1 s` 黄色，`1 s <= age <= 999 s` 红色；从未发送需使用中性/未知样式。
- WebSocket 断线、sequence gap 或页面重载后，HTTP 原子快照能恢复完整行状态；增量事件不得使旧 revision 覆盖新状态。

### R4. Standalone Persistence And Portable Settings

- 独立启动模式下，自定义 payload/values、单报文频率和可用 authority 选择在 Gateway 重启后恢复；实际发送/armed 状态仍不自动恢复，避免重启即发包。
- 支持导出一个具名、带 schema/version 的 UTF-8 JSON 配置，并支持导入同格式配置。
- 导入必须完整解析、严格字段/type/schema/DBC identity 校验，在候选配置上全部验证后单次原子提交；任何错误不得部分写盘、改变内存或增加 revision。
- JSON 使用 canonical uppercase payload，并包含足够的 DBC/message identity 来拒绝将配置静默套用到不兼容 DBC 布局。
- Godot-managed 的逐 ID override 是 session-only，不读取或覆写 standalone authority 配置；Gateway/Godot 重启后所有可仿真 ID 恢复 `simulation`。主题偏好仍由浏览器本地存储。
- 可移植 JSON 只包含 CAN console 的消息配置与 schema/identity，不包含机器本地的 Windows TCP endpoint 或固定 Linux can0 状态；这些 transport 配置继续使用各自既有持久化。

### R5. Compatibility And Boundaries

- 不改变 CAN ID、DLC、payload 编码、字节序、缩放、EFF packing、CSV 完整性、Windows PC001 或 Linux SocketCAN 发送语义。
- 不改变 timed CAN `0x18FFF100` 的 ID、payload、50 Hz、10 秒和显式触发定义；它也不参与逐 ID authority、持久化或导入/导出。
- 保持 Windows 仅 TCP、Linux 仅 can0 的平台传输边界。
- 现有 can0 非阻塞、latest-value/coalescing、公平调度和拥塞诊断保持不变；新增 UI 指标必须区分 transport-egress 与物理总线确认。
- Web handler 不直接操作 scheduler/sink；Gateway owner loop 仍是唯一发送和配置 authority。

## Acceptance Criteria

- [ ] AC1: Windows 与 Linux 使用同一 React 页面，明暗主题可切换并记住浏览器偏好。
- [ ] AC2: 每个纳入范围的 CAN ID 有稳定行，能展开物理量、查看最近成功 payload、打开 modal 双向编辑并显式保存。
- [ ] AC3: 三态切换保证同一 CAN ID 任一时刻只有一个 active authority；Godot-managed 的可仿真 ID 默认 simulation，逐 ID off/custom override 立即生效且不影响其他 ID；standalone 的 simulation 挡位明确禁用。
- [ ] AC4: 预期频率、最近 10 次成功 egress 平均所得实际频率、实时 freshness 的数值/单位/阈值符合 R3；从未发送与不足样本有明确中性状态。
- [ ] AC5: WebSocket 正常推送行增量；断线重连、gap 和刷新后能从原子快照恢复，不需要第二个实时 endpoint。
- [ ] AC6: Standalone 自定义设置可跨重启恢复但全局发送不会自动 armed；显式开始/停止有效；导出/导入 CAN console JSON 可无损往返，错误或不兼容文件零副作用。
- [ ] AC7: Godot-managed 允许的 mutation 仅限逐 ID off/custom/simulation 与 custom 内容/频率；transport、DBC reload、import/export 等仍由服务器 403。
- [ ] AC8: 现有 DBC value/payload round-trip、频率 `1..100`、load warning、SocketCAN/PC001/CSV/timed CAN 编码和发送合约无回归。
- [ ] AC9: Agent 自动验证限于快速确定性 Python/Vitest/单个进程 canary；真实浏览器布局、明暗主题、modal 可读性和操作手感由一次聚焦人工验收完成。

## Out Of Scope

- 物理 CAN 总线 ACK/echo 测量或外部 PC001 bridge 回执协议。
- 远程浏览器访问、多用户认证或互联网部署。
- 任意 CAN interface/transport 切换、Windows SocketCAN 或 Linux PC001。
- 修改 DBC 定义、CAN 编码、字节序、缩放、timed CAN 定义或 Godot 物理/遥测计算。
- 用客户端逐帧日志推断实际发送；实时发送真值由 Gateway server 保存与发布。
