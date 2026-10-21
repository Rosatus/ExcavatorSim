# Implementation Plan

## Phase A — DBC Assets, Provenance, and Shared Encoding

- [ ] 复制批准的新 CAN3/CAN4 bytes，更新固定 SHA、message count、provenance 和 DBC bundle tests。
- [ ] 扩展 DBC descriptor/catalog channel 元数据及严格验证；更新 duplicate/fallback fixtures。
- [ ] 将 `0x18FFF000` Godot/Web 路径迁入 shared DBC codec，删除 native row/专用 encoder 生产引用。
- [ ] 将默认与 compat-profile 的 A800 wire expectation 全部改为 DBC 小端，更新 QML spec、reference-parser oracle、`test_qml_compat.py` 及相关测试，保留 ID/DLC/EFF 和物理投影 contract。
- [ ] 增加 cantools differential tests：`0x18FFF000`、新增 CAN3 signals、A800、全部 Godot-mapped DBC rows。

Rollback point: DBC bytes + hashes + codec migration 单独成组；未通过严格 hash/catalog/differential tests 不进入后续阶段。

## Phase B — Channel Metadata and Sink Projection

- [ ] 定义窄 logical channel 与 immutable `FrameOccurrence`（或等价 DTO），字段覆盖 identity/payload/channel/source/family/generation，并贯通 DBC/native descriptor、console DTO 与 producer。
- [ ] 更新 `append_frame`、`FrameSink`、`CsvFrameSink`、`CanapeCsvWriter`；CSV 按 occurrence 写 `ch0/ch2/ch3`，Web API row 输出 channel。
- [ ] PC001 将 occurrence 的 `ch0/ch2/ch3` 映射为 i32 LE `0/2/3`；保持 16-byte CAN frame、batch framing、握手和 SocketCAN 行为不变。
- [ ] 增加 source-to-channel、CSV row、Web DTO、PC001 逐族 byte-exact、混合 channel batch、EFF/SFF 与 DLC 回归，明确 CAN3/`0x18FFF100`=3、CAN4=2、`0x256`=0。

Rollback point: 公共 occurrence signature 与全部 sink adapters 同组提交，禁止中间态遗漏 metadata。

## Phase C — Cross-platform TCP Default

- [ ] CLI 在两平台默认选择 TCP；显式 SocketCAN 作为 low-latency opt-in，更新 `--help`。
- [ ] 将 transport Web capability 从 OS gate 改为 active-sink gate。
- [ ] Godot bridge 两平台默认构造 TCP argv，更新 Linux 状态/握手投影和 operator 文案。
- [ ] 改写 Linux 默认 ICT/CTNR/UI error taxonomy：TCP 只呈现 listener/handshake/forwarding；can0 missing/helper/setup 仅显式低延时模式适用。
- [ ] 保留 can0 helper/readiness/SocketCAN 实现及显式路径测试；默认 Linux process-level 测试 spy `_open_can0`、`prepare_can0`、`restart_can0` 与 helper subprocess 全部零调用，同时断言 TCP listener 实际 bind。
- [ ] 更新 README、安装/运行说明及 `can-gateway-control` 旧平台默认契约。

Rollback point: CLI default、Godot argv、Web capability 与文档同组；不改 can0 internals。

## Phase D — `0x18FFF100` Authority and Persistence

- [ ] 将 timed frame 注册为 channel `ch3` 的专用 console row，提供 payload/frequency 编辑。
- [ ] 实现 off/custom/simulation 互斥及 timed trigger authority gate，保持 exact 50 Hz/10 s/500/no-catch-up/retrigger contract。
- [ ] authority 变化原子 disarm/arm、purge pending generation/ID、reset rate samples。
- [ ] 固定升级 console internal 3->4、portable 1->2，实施兼容 descriptor migration 与 `migrated/reset/added/removed` 聚合 notice；旧 operator DBC schema 2 保持不变并按 SHA key 安全回退。
- [ ] 覆盖 standalone restore/disarmed、managed session-only、schema-3 internal 自动迁移、schema-1 portable 显式 import、partial-compatible row 迁移和不兼容回退。

Rollback point: timed authority 与 schema migration 同组；旧 timed regression 全绿后才接 UI。

## Phase E — Atomic Batch API and React UI

- [ ] 新增 owner-loop batch authority command/REST endpoint、revision/request validation、单次 persistence/event。
- [ ] 实现 all-off/all-custom/all-simulation；simulation 将 `0x18FFF100` 视为 CTNC-timed capable、返回其余 forced-off IDs，standalone simulation capability fail-closed。
- [ ] React types/API/reducer 增加 channel、batch result 与 snapshot event。
- [ ] 表格新增 channel 列；顶栏增加三个 shadcn 按钮；显示 forced-off 汇总，保持主题、响应式布局、展开行和编辑弹窗。
- [ ] 实现 `0x18FFF100` custom modal 的 payload/frequency/保存及 runtime frequency/freshness；物理值区域显示无定义且不可编辑，不生成伪 values 字段。

Rollback point: backend contract tests先通过，再生成/替换 `resources/web`；禁止手工复制 build output。

## Phase F — Stable-Then-Once Verification and Release Readiness

### Agent automated

- [ ] 运行 Gateway Python focused/full tests：`python -m unittest discover -s tools/can_gateway/tests`（使用项目已配置 Python 环境）。
- [ ] 在 `tools/can_gateway/web` 运行一次 `npm test` 和 production build。
- [ ] 运行 focused Godot CAN Gateway headless E2E 一次，覆盖两平台默认 argv contract、PC001 handshake projection 和 offline custom authority；不启动视觉场景。
- [ ] 运行 `pixi run verify-provenance`、受影响的 manifest/tool tests，最后一次 `pixi run verify`。
- [ ] 构建 Windows/Linux Gateway artifacts 时验证内嵌/相邻 DBC hash、Web assets、helper/scripts 和 manifest；仅在用户要求本任务同时出包时执行完整发行构建。

### Human manual — one final acceptance round across the required environments

- [ ] Windows 无特殊参数/Godot 拉起：TCP listener、PC001 handshake、Web channel/批量按钮/`0x18FFF100`。
- [ ] 真实 Linux 无特殊参数/Godot 拉起：同一 TCP 行为且不触发 sudo/can0 helper。
- [ ] 真实 Linux 显式 `--sink socketcan --interface can0`：原低延时 helper/readiness 与物理发送仍可用。
- [ ] 浏览器明暗主题、表格可读性、弹窗双向编辑和 forced-off 提示由用户人工验收一次。

## Final Review Gates

- [ ] 搜索确认生产路径仅 `0x18FFF100`、`0x256` 使用 native/special descriptor，`0x18FFF000` 无专用 encoder 调用。
- [ ] 搜索确认内置可发送集合为 30 个 DBC identity + 2 个专用 identity，且 PC001 channel 不再存在无条件 `pack(0)`。
- [ ] 搜索确认默认 Linux 路径没有隐式 SocketCAN/can0 helper 调用或过时 UI 文案。
- [ ] 对照 PRD AC1–AC10 做一次跨层检查；此前已通过的 focused gate不重复运行。
- [ ] 更新 Trellis specs，特别是跨平台 TCP default、timed authority、channel、DBC/A800 authority 和低延时 maintenance 状态。

## Phase G — PC001 Local Test Client

- [x] 新建 `tools/pc001_test_client`，实现纯标准库 protocol DTO、typed errors、exact-read、`who`/`PC001` 握手和 byte-exact batch decoder。
- [x] 实现带 generation/cancellation 的 socket worker；连接、断开、EOF、timeout、非法 header/body 均转换为稳定状态事件。
- [x] 实现 `(CAN ID, channel)` 有界聚合器、最近 10 次间隔频率、新鲜度和约 20 Hz delta drain。
- [x] 实现 PySide6 Widgets 主窗口、`QAbstractTableModel`、`QSortFilterProxyModel`、endpoint controls、状态栏、暂停/清空、ID/channel 过滤和排序。
- [x] 增加协议 fixture/differential、TCP fragmentation/EOF/reconnect、聚合/频率及 Qt model focused tests；复用真实 Gateway process test 验证握手、channel 3/2/3/0 和持续收包。
- [x] 增加独立 Windows `onedir + zip` 构建和 manifest；执行无 Python 环境语义的 packaged exe 启动/连接冒烟，不修改正式 release whitelist。
- [x] 更新 Gateway README 的本地 PC001 测试章节和任务进度；只运行本工具 focused tests、受影响 Gateway PC001 tests及一次打包冒烟，不重复此前已通过的完整 Godot/视觉/Linux 构建。

Rollback point: 协议核心、GUI 和独立构建目录均不被正式 runtime import；删除 `tools/pc001_test_client` 与独立 dist 即可完整回滚，不影响 Gateway/Godot。
