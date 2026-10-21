# Gateway Web CAN Console Redesign — Technical Design

## 1. Architecture Summary

保留现有单进程 Gateway 与 owner-loop authority，不增加第二个 WebSocket、第二套发送核心或客户端定时发送器。新控制台由四个后端能力和一个前端投影组成：

```text
Godot telemetry ─┐
                 ├─ per-ID authority gate ─┐
Custom scheduler ┘                         ├─ shared append/send core ── TCP / can0
Timed CAN（旁路，不参与三态）───────────────┘                 │
                                                               └─ egress tracker
                                                                    │
HTTP atomic snapshot + existing WebSocket coalesced deltas ─────────┘
```

- `tools/can_gateway/can_console.py`（新增）负责统一消息描述、native adapter、authority/custom draft、schema migration、导入/导出验证和 standalone/session 生命周期。
- `tools/can_gateway/gateway.py` 继续是唯一 owner loop，原子执行 authority、payload、频率、arm/import mutation，并在提交帧前应用 authority gate。
- `tools/can_gateway/gateway_runtime.py` 继续拥有线程安全 immutable publication、revision/request-id、event ring；新增每消息 egress projection。
- `tools/can_gateway/pc001_sink.py` 仅扩充 pending metadata 与成功回调，不改变 PC001 greeting、batch bytes、队列上限或 sendall wire seam。
- `tools/can_gateway/web` 消费统一 typed snapshot/event contract，展示行表、Dialog 编辑器和 capability-aware 控件。

## 2. Canonical Message Identity And Catalog

### 2.1 Identity

消息身份使用 `(is_extended, arbitration_id)`，显示为既有 uppercase hex。内部 raw arbitration ID 不预先 OR `CAN_EFF_FLAG`；EFF 仍只由 sink packing 负责。稳定 API key 建议为：

```text
eff:18FF3A00
sff:00000256
```

这样不会把数值相同的 SFF/EFF 消息误合并，也不会把 DBC source path 当作运行身份。

### 2.2 Unified Descriptors

控制台 catalog 是以下定义的并集，按 canonical identity 去重并保留 provenance：

- 所有 operator DBC catalog 消息；现有 DBC codec 继续拥有 signal、mux、physical/payload round-trip。
- native `slew` adapter：复用 `encoders/dxg_slew.py` 的 `encode_slew_frame()` / `decode_slew()`，字段为角度和状态。
- native `travel` adapter：复用 `encoders/travel_pilot.py` 的 `encode_travel_frame()` / `decode_travel()`，字段为左右先导压力。

native adapter 暴露与 DBC 相同的最小 UI contract（name、unit、range、encode、decode、exact DLC），但不伪造 DBC file/hash。它们使用版本化 adapter fingerprint，确保以后语义变化时旧配置不会静默套用。

timed CAN `0x18FFF100` 不注册为 console descriptor，也不经过 authority gate。

### 2.3 Simulation Capability

只有真正由 `emit_frames()` 生成的 RTK、IMU、slew、travel ID 标记 `simulation_capable=true`。随包 DBC 中没有 Godot producer 的其它消息仍显示并可用于 standalone custom，但在 Godot-managed 中默认 `off`，`simulation` 挡位禁用。所有可仿真 ID 在 Godot-managed 启动时默认 `simulation`。

## 3. Authority And Scheduling

### 3.1 State

每条消息维护：

```text
selected_authority: off | custom | simulation
custom_payload: exact-DLC bytes
custom_frequency_hz: integer 1..100
simulation_capable: bool
persistent: bool（standalone true，godot-managed false）
```

状态转换由一个 owner-loop reducer/manager 统一处理，不在 Web handler、React component 或 sink 中重复判断。

### 3.2 Mode Rules

| Runtime | Startup | Allowed row states | Custom activation | Persistence |
|---|---|---|---|---|
| standalone | restore saved off/custom; global disarmed | off/custom；simulation disabled | explicit global Start | atomic config |
| godot-managed | simulation-capable → simulation；others → off | off/custom/simulation by capability | selecting custom is immediately live | session-only |

Godot-managed Web 不再使用“所有 mutation 403”的粗粒度 gate；改为 capability allowlist：允许 row preview、row content/frequency update 和 authority update，继续拒绝 transport mutation、DBC reload、standalone arm、import/export。

### 3.3 Single Authority Enforcement

- 在 `emit_frames()` 已完成现有编码、准备调用 `append_frame()` 前按 CAN identity 查询 authority；`simulation` 才提交，`off/custom` 跳过。
- custom scheduler 只包含 authority=`custom` 的 entries；它复用现有 monotonic、per-message、skip-missed-slot scheduler，不复制第二套 cadence 实现。
- authority 更新、scheduler entry 更新和 published snapshot 在同一个 owner command 内完成；不会出现一帧同时由 simulation/custom 获权。
- SocketCAN pending coalescing 仍是拥塞机制，不承担 authority 仲裁。
- CSV/PC001/SocketCAN 看到相同的 authority 结果；CSV 仍完整记录所有实际提交给 active sink 的帧，不受 SocketCAN congestion drop 影响。

### 3.4 Arm, Fault And Recovery

- standalone 保存 selected authority，但 `custom_armed` 永不持久化；restart/reload/reconfigure/disconnect/terminal fault 继续 disarm，用户必须再次点击 Start。
- Godot-managed 的 simulation producer 沿现有生命周期运行。切到 custom 时该 ID 立即进入 scheduler；切回 simulation/off 时必须 purge 对应尚未发送的 SocketCAN custom slot。
- 当 managed custom 因 transport disconnect/terminal fault 被强制停止时，相关 session override 回退到 `simulation`（若 capable）或 `off`，避免 UI 仍显示 custom 但实际上不发送，也避免重连后自动恢复旧 custom。
- timed generation 的 purge/deadline/retrigger 语义保持独立且不变。

## 4. Payload Editing

- DBC 描述使用当前 `preview_message()` / `update_message()` 语义：exact DLC、物理范围、mux、未建模 bit 保留、canonical uppercase payload。
- native adapter 通过相同 preview command boundary 完成 values ↔ payload。`slew` 与 `travel` 的 encoder/decoder 是唯一转换实现；UI 不复制公式。
- Preview 继续无 revision mutation、无 persistence、无 scheduler/event side effect；Save 才提交。
- Godot-managed custom draft 只存在当前进程内。首次进入 custom 使用该 session 的 canonical default draft；保存后仅更新 session snapshot。
- Edit Dialog 只在 authority=`custom` 时可编辑。standalone 可先选择 custom、编辑，再显式 Start；managed 选择 custom 后立即使用当前 draft 发送。

## 5. Egress Metrics And Realtime Contract

### 5.1 Truth Boundary

“实际发送”统一命名为 transport egress：

- SocketCAN：非阻塞 `sock.send()` 成功，现有 `SocketCanDelta(outcome="sent")` 是写入点。
- TCP：`sendall(batch)` 成功，需让 pending item 保留 `source/family/can_id/payload` metadata 并在 service thread 成功后回调。
- CSV、submit、queued、coalesced 和 aggregate inference 不更新 egress freshness。
- 这不是物理总线 ACK；API/UI help text 必须明确。

### 5.2 Per-Message Tracker

线程安全 tracker 按 canonical identity 保存：

- last successful payload/source/authority；
- `deque[float](maxlen=10)` successful monotonic timestamps；
- sample count、last timestamp；
- dirty generation for coalesced publication。

实际频率由 server 计算：样本少于 2 个为 `null`，否则 `(n - 1) / (last - first)`；authority 改变时清空频率样本，避免混合 simulation/custom cadence。最后 payload 可保留为“上一次真实 egress”，直到新 authority 成功发送；freshness 会继续增长。

TCP 一个 batch 内的帧以同一次 `sendall` 完成时刻记账。这是该 transport 能提供的最精确本地 egress seam，不虚构逐帧物理发送时间。

### 5.3 Snapshot And WebSocket

新增统一原子读取（具体路径采用 `/api/v1/can-console`）：

```json
{
  "status": {},
  "console": {
    "server_monotonic_s": 123.0,
    "custom_armed": false,
    "messages": []
  }
}
```

每个 message row 含 descriptor、capabilities、selected/effective authority、custom draft、expected Hz、last egress payload/timestamp、actual Hz 和 sample count。

复用 `/api/v1/events`，新增一个 typed、批量、限频的 `can_console_runtime` event。Gateway 每 50 ms 最多发布一次所有 dirty row 的 runtime delta，不逐帧刷 WebSocket/JSONL。WebSocket event 与 HTTP snapshot 都带 `server_monotonic_s`；浏览器收到后计算基础 age，再用本地 `performance.now()` 连续递增。sequence gap、断线重连或未知 event schema 时回退到完整 HTTP snapshot。

## 6. Persistence, Import And Export

### 6.1 Internal Store

将 `DbcConfigStore` 演进为 versioned console store（保留旧 schema migration）：

- schema 1 values → existing canonical payload migration；
- schema 2 enabled/payload/frequency → `enabled=true` 映射 custom、false 映射 off；
- schema 3 保存 canonical identity、descriptor fingerprint、authority、payload、frequency。

继续采用 candidate clone → validate → temp UTF-8/LF file → flush/fsync → replace → in-memory publish。失败不改变内存、scheduler 或 revision。TCP endpoint 继续留在既有 `config.json`，不与 CAN profile 建立跨文件伪事务。

### 6.2 Portable JSON

导出由 server 从 canonical store/snapshot 生成，例如：

```json
{
  "format": "excavatorsim-can-console",
  "schema_version": 1,
  "catalog_fingerprint": "...",
  "messages": []
}
```

- 只含 CAN console settings；不含 Windows TCP endpoint、can0、theme、armed、runtime metrics 或 Godot session override。
- Import 是 full-profile replace，要求 format/schema/catalog/message fingerprints 完整匹配；未知、重复、缺失、错误 DLC、范围、频率或 authority 全部拒绝。
- Import 沿现有 64 KiB strict JSON、finite-number、allowlist 和 revision/request-id boundary；成功只写一次、revision bump 一次、发一个 summary event。
- Godot-managed export/import server-side 403。

## 7. React UI Design

### 7.1 Layout

保留 header/transport summary/logs，但将 CAN console 提升为主内容。宽表列为：

```text
▸ | CAN ID + name | latest egress payload | Edit | Off / Custom / Simulation |
expected Hz | actual Hz | freshness
```

展开行显示 decoded latest egress physical values、单位和 source；没有 egress 时显示中性“尚未发送”。搜索按 ID/name/signal。窄屏使用最小宽度 + 横向滚动，避免把列堆成难读卡片。

### 7.2 Components And State

- 拆分 `CanConsoleTable`、`CanMessageRow`、`AuthorityControl`、`MessageEditDialog`、`FreshnessCell`、`ImportExportControls`。
- 加入 shadcn/Radix Dialog primitive；三挡采用可键盘操作的 radio group/segmented control，而不是三个不相关按钮。
- 复用并抽出当前 payload validator、debounced preview generation/AbortController 和 stale edit protection。
- Event reducer/decoder 是 runtime delta 的唯一解释入口；组件不直接 cast `event.detail`。
- Theme provider 在 `<html>` 切换 class；light/dark token 都定义于 CSS。优先已保存偏好，其次 `prefers-color-scheme`，主题只存 localStorage。

### 7.3 Freshness Rendering

前端用一个共享 50 ms ticker 更新所有可见 freshness，不为每行建立 timer。格式：

- `< 1000 ms`：`${ms.toFixed(3)} ms`；
- `1..999 s`：`${seconds.toFixed(3)} s`；
- `> 999 s`：`>999s`；
- never：`—`。

颜色边界精确为 `[0,100)` green、`[100,1000)` yellow、`[1000,999000]` red，never neutral。

## 8. Compatibility And Rollback

- 不修改 Godot GDScript telemetry packet、Gateway CLI mode enum、CAN encoders、timed CAN、EFF packing、SocketCAN congestion behavior或 PC001 wire bytes。
- API 新增统一 console endpoints；现有 `/api/v1/dbc` 可以保留兼容，待新 UI 完全迁移后再决定是否废弃，不在本任务删除。
- schema migration 先有 focused fixtures，再写新 schema；保留旧 config 的只读迁移路径。
- 各阶段均可按模块回滚：UI 可退回旧 `/dbc` 页面；metrics callback 可移除而不改变 wire；authority gate 可在未启用新 API 时保持现有 simulation/operator behavior。

## 9. Important Risks

- TCP batch completion只能表示本地 stream write 完成，不是 PC001/CAN 总线 ACK；命名和说明必须一致。
- managed 权限从全只读改为细粒度 allowlist，最易出现越权 endpoint；每个 mutation 路由都要有 mode/capability matrix regression。
- DBC、native adapter 和 simulation producer 的 identity 若不统一，会产生同 ID 双发；必须用 canonical identity 作为唯一 join key。
- 高频逐帧 WebSocket 会造成日志/浏览器负担；必须使用 server tracker + dirty batch event，而非推送每帧。
- standalone config restore 与 arm 必须分离；任何 migration/import 不得使 Gateway 启动即发包。
