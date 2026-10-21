# Technical Design

## 1. Architecture Boundary

本任务保持一条发送主线：

```text
Godot telemetry values ─┐
Web custom values/raw ──┼─> per-ID authority ─> canonical occurrence ─> CSV / TCP / SocketCAN
Timed 18FFF100 event ───┘
```

`canonical occurrence` 至少包含 canonical CAN identity、raw payload、source/family/generation、EFF 属性和逻辑 `channel`。编码与发送解耦：DBC/native adapter 只产生 raw payload，sink 只负责自己的 wire/文件投影。

## 2. DBC Asset and Codec Binding

- 将批准的新 CAN3/CAN4 原始 bytes 复制到 `tools/can_gateway/resources/dbc/`，更新固定 SHA 与 `assets/provenance.json`。
- protocol codec 仍 hash-bound、fail-closed；预期 message count 从 27 更新为 30。
- 给 DBC file/message descriptor 增加受验证的 logical channel。先用批准文件 identity 与 `channel=can3/can4` comment 识别 DBC source family，再通过显式映射 `can3 -> ch3`、`can4 -> ch2` 产生输出标签；comment 中的 `can4` 是来源族名，不等同于输出 `ch4`。显式第三方 DBC 缺失或存在相互冲突的 source-family 证据时标记不可发送或给稳定 notice，不能猜测。
- `0x18FFF000` 从 native row 删除，改为 CAN3 DBC row。Godot projection 提交 `ROTATE=state.slew_degrees()` 给 strict codec，得到正式 DLC=8 payload。
- 删除生产路径对 `encode_slew_frame` 的调用；若兼容 decoder 仅被迁移代码使用，限定为 migration adapter，否则一并移除。
- A800 默认和 compatibility profile 都以批准 DBC 小端为最终 payload authority；QML compatibility mapper 仍负责物理量投影，但不再拥有相反的字节序。同步修订 `can-qml-compatibility`、reference parser oracle 和 `test_qml_compat.py` 等 big-endian 断言，使 LE 成为唯一可验收 wire contract。

## 3. Channel Through the Send Core

- 引入窄类型 logical channel（`ch0|ch2|ch3`，避免自由字符串扩散），并以 `FrameOccurrence(identity, payload, channel, source, family, generation)` 或等价 immutable DTO 贯通生产者与 sink。
- `CanConsoleEntry`、`CanConsoleMessage`/runtime DTO 输出 `channel`；portable/internal descriptor fingerprint 纳入 channel，schema 版本前进。
- 所有 producer 在提交 occurrence 时携带 channel：DBC 从 descriptor 获取；native `0x18FFF100`/`0x256` 分别固定为 `ch3`/`ch0`。
- CSV writer 写 logical label；Web 直接显示相同字段。
- `append_frame`、`FrameSink`、`CsvFrameSink` 与 `CanapeCsvWriter` 改为消费 occurrence/显式 channel；TCP/PC001 sink 将 `ch0/ch2/ch3` 显式映射为 i32 LE `0/2/3`，SocketCAN 忽略 channel。该映射来自同一窄类型/函数，禁止 CSV、Web、PC001 各自维护映射表。
- PC001 仍按 `[u16 count] + count × [16-byte can_frame + i32 LE channel]` 封装；只改变最后 4 字节的值，16-byte CAN frame、握手、batch count、DLC、payload 与 EFF packing均不变。

## 4. Transport Selection and Capabilities

- CLI 默认 sink 统一为 `tcp`，不再读取 host OS 选择默认值；`--sink socketcan --interface can0` 是显式 low-latency opt-in。
- can0 readiness/helper 仅在 active sink 为 SocketCAN 时构造/调用；默认 TCP 的 import/startup 不触碰任何 privileged dependency。
- Web transport endpoints 改为 capability-driven：active TCP 提供 rebind；active SocketCAN 才提供 confirmed can0 restart。错误返回描述 active capability，而不是“Windows/Linux 不允许”。
- Godot `CanTelemetryBridge` 两平台默认构造同一 TCP argv。Linux heartbeat platform bit仍表示 host platform；handshake bit仍表示真实 PC001 socket，UI 不再把 Linux 固定渲染为 can0 N/A。
- TCP 默认模式下的 ICT_START/STOP 只控制 TCP forwarding/listener 既有生命周期，不再暴露 can0 missing/helper/setup 的 Linux 默认错误；这些 CTNR 结果码与超时文案只在显式 SocketCAN 低延时 capability 下适用。
- README、帮助文案、installer 说明明确低延时模式暂时停止维护，但 Linux 包继续携带 helper 与安装脚本以保证显式兼容路径可用。

## 5. Authority State Machine

### Ordinary rows

- `off`：拒绝 simulation/custom producer。
- `custom`：只允许 shared custom scheduler。
- `simulation`：只允许 Godot producer；无 producer row 不允许单行选择。

### `0x18FFF100`

- 使用 native descriptor：EFF、DLC=8、channel=`ch3`、默认 payload 与频率仍为既有常量。
- custom 弹窗只提供 exact-DLC raw payload 与 frequency；物理值区域展示“该专用帧没有物理量定义”。没有协议证据时不得添加 byte0..byte7 或虚构角度、状态等语义。
- `off`：立即 disarm timed generation 并移除 custom schedule。
- `custom`：disarm timed，使用 editable payload/frequency 的普通 custom schedule。
- `simulation`：移除 custom schedule；CTNC command 6 才能 arm 原 `TimedCanBurst`。处于非 simulation 时收到 command 6 返回稳定的 ignored/rejected diagnostic，不产生帧。
- authority 切换清理 SocketCAN pending ID/generation 和 egress rate samples，保留 last payload display 规则。

## 6. Atomic Batch Mutation

- 新增一个 batch authority REST endpoint 和一个 owner command，body 至少含 `authority`、`expected_revision`、`request_id`。
- owner 在候选副本中一次计算所有 row 的目标状态，校验后原子应用；一次 scheduler rebuild/purge、一次 persistence、一次 revision increment、一次 snapshot event。
- `all simulation` 仅 godot-managed 可用：Godot telemetry producers以及 CTNC-timed producer `0x18FFF100` -> simulation，unsupported rows -> off；响应返回 `forced_off_keys`，其中不得包含 `eff:18FFF100`。standalone 返回 capability error，前端按钮保持可见但 disabled 并有说明。
- 失败时零部分变更。WebSocket 使用 snapshot-class event；runtime delta contract 不需要逐行广播 authority。

## 7. Persistence Migration

- console internal schema 固定 `3 -> 4`，portable schema 固定 `1 -> 2`。legacy internal schema 3 是唯一自动迁移输入；portable schema 1 只允许通过显式 import 迁移。
- 新 fingerprint 包含 channel 与 descriptor/DBC identity。
- migration 先按 canonical key 对齐，再比较 DLC、EFF、信号布局/scale/endian 和 native descriptor version。完全兼容才迁移 canonical payload、frequency、off/custom authority；输出聚合 `migrated/reset/added/removed` 计数与 reset key 清单，写入 snapshot notice/event，但不逐 row 刷日志。
- `0x18FFF000` native -> DBC 不自动迁移旧 payload，因为 descriptor authority 改变；使用 DBC 默认并记录一次 aggregated reset notice。
- 新 `0x18FFF100` 使用安全默认：standalone off、Godot-managed simulation；新增/不兼容 DBC rows同样回退模式默认。
- 写入仍原子 replace；candidate 全量验证成功后才替换 live state。
- 旧 operator DBC `dbc-config.json` 保持 schema 2；其 key 含旧 DBC SHA，替换 bundle 后自然无法匹配并使用生成默认值，沿用既有 restore notice，不参与 console schema 迁移。

## 8. Compatibility and Rollback

- 回滚单位 1：DBC bytes/hash/provenance/codec 与 `0x18FFF000` 迁移必须同提交，避免新资产配旧 encoder。
- 回滚单位 2：transport default、Godot argv、capability API/文案必须同提交，避免 Linux UI 与实际 sink 分裂。
- 回滚单位 3：channel occurrence、CSV/Web DTO 和 PC001 i32 映射必须同提交，避免同一帧在不同出口显示不同 channel；React build assets随后与 backend API 同步提交。
- 低延时代码不删除；若默认 TCP 上线异常，可显式 `--sink socketcan --interface can0` 临时运行，而无需回滚 helper。

## 9. Diagnostics

- 启动聚合记录 DBC names/hashes/message counts、选定 sink、低延时 maintenance 状态和迁移结果计数。
- batch authority 记录一次目标、changed count、forced-off count；不逐帧/逐 row 刷日志。
- timed trigger 被 authority 抑制时返回稳定诊断，不能伪装成功。

## 10. PC001 Local Test Client

### Placement and dependency boundary

- 新工具位于 `tools/pc001_test_client/`，避免把 PySide6 引入 `tools/can_gateway` 的运行依赖。
- `protocol.py` 是纯 Python 协议核心，只依赖标准库；它拥有 exact-read、握手、batch framing、CAN frame/channel 解码和稳定异常类型。
- `client.py` 管理 socket 生命周期及后台接收，不引用 Gateway 私有运行对象；协议常量与 Gateway wire contract 必须由 byte-exact differential tests 锁定，避免测试客户端和服务端同时引用同一实现而形成同源假阳性。
- `app.py`/`models.py` 承担 PySide6 UI；构建脚本与依赖锁定只作用于测试工具自身。正式 Gateway、Godot 和 release manifest 不包含该目录产物。

### Receive and thread model

```text
socket worker thread -> decoded FrameBatch queue -> queued Qt signal
                    -> GUI-thread accumulator -> QAbstractTableModel delta (~20 Hz)
```

- worker 对 2-byte batch header 和 `count * 20` body 始终 exact-read；EOF、timeout、非法 count/DLC/channel 产生有类型的 session error。
- 一次连接拥有独立 generation 和 receive buffer；disconnect/reconnect 会停止并 join 旧 worker，旧 generation 的迟到 signal 被丢弃。
- worker 不操作 Qt model。GUI 定时器每约 50 ms drain 有界 pending map，并以 `(canonical ID, channel)` 合并最新 payload，同时累计 count/timestamps。
- 暂停显示时仍 drain socket 与更新内部聚合，只停止表格可见 delta；恢复时一次刷新最新状态，不回放历史帧。

### Table and diagnostics

- 一行对应 `(canonical CAN ID, channel)`；列为 CAN ID、格式、channel、DLC、payload、count、actual Hz、freshness。
- actual Hz 使用最近 10 次同 key 接收间隔平均值；少于 2 个样本显示 `—`。freshness 使用 monotonic time，并沿用 Gateway Web 的 ms/s 可读格式与绿/黄/红阈值。
- `QSortFilterProxyModel` 提供 CAN ID 文本和 channel 过滤；clear 清聚合状态但不改变连接。
- 状态栏显示 disconnected/connecting/handshaking/connected/error、总 batch/frame、最后错误。协议错误关闭当前连接，用户可以重新连接。

### Packaging

- 提供 Windows PyInstaller `onedir` 构建脚本，再生成 zip；默认不使用 onefile，避免每次启动解压 Qt runtime 和插件诊断困难。
- 构建产物写入独立 `dist/pc001_test_client/`，不复制到 `godot/dist`。
- manifest 记录源码 commit/dirty、Python/PySide6/PyInstaller 版本及文件 SHA-256；exe 启动和真实 Gateway handshake/接收作为打包冒烟。
