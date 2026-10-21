# Gateway 新版 DBC 与跨平台 TCP 统一

## Goal

将 Python Gateway 升级到 GuideSystem 的新版 CAN3/CAN4 DBC，让除 `0x18FFF100`、`0x256` 外的受支持帧统一由 DBC 编解码；同时将 Windows/Linux 默认传输统一为 TCP Server，并在 Web 后台完整呈现 channel、新版帧、批量三态控制和 `0x18FFF100` 的可控发送。

用户价值是减少平台分支与手写编码分歧，让同一份 DBC、发送权威和 Web 配置在 Windows/Linux 上得到一致结果。Linux 直接 SocketCAN 仅作为显式低延时兼容模式保留。

## Background and Confirmed Facts

- 批准的输入文件是：
  - `E:/projects/temp/GuideSystem/GuideSystem/services/can/dbc/can3.sy135c.dbc`
  - `E:/projects/temp/GuideSystem/GuideSystem/services/can/dbc/can4.sy135c.dbc`
- 新 CAN3 相比当前 bundle 新增 `0x18FFF000`、`0x18FF3E00`、`0x18FF3F00`；新 CAN4 仅补充 A800 小端注释。完整差异见 `research/dbc-delta.md`。
- 新 DBC 将 `0x18FFF000` 定义为 DLC=8、`ROTATE` 位于 byte 0..1、小端、比例 `360/65536`。正式 `BO_` 定义优先于“旧协议 DLC=2”的历史注释。
- `0x18FFF100`、`0x256` 不在两份 DBC，因此继续作为仅有的专用帧 contract。
- 当前 CSV channel 被硬编码为 `ch3`，PC001 wire 的 i32 channel 历史上恒为 `0`；本任务将二者统一改为同一权威映射。
- 当前 Linux 默认 SocketCAN、Windows 默认 TCP；Godot bridge 也按平台注入不同 sink。

## Requirements

### R1 — DBC 资产与共享编码

- Gateway 内嵌资源、相邻外部副本、固定 hash、provenance 和发行包必须统一替换为批准的新版 DBC，默认 roots 不得同时残留旧版内容。
- DBC catalog 加载新版合计 30 帧；内容完全相同的内嵌/相邻副本继续静默折叠。
- `0x18FFF000` 的 Godot 仿真、Web values/payload 双向编辑与 custom 发送全部改走共享严格 DBC codec；移除生产路径中的专用 slew encoder/native catalog 覆盖。
- 除 `0x18FFF100`、`0x256` 外，不得新增或保留手写 payload encoder。
- A800 四个速度信号在默认与 `--compat-profile` 等所有 Gateway 发送路径中都以新版 DBC 的小端定义为唯一 wire authority；过时的 QML big-endian Gateway 约束、reference-parser oracle、测试和说明必须同步修订，不保留 profile 例外。

### R2 — Channel 元数据

- 每个 catalog/console row 和发送 occurrence 都携带逻辑 channel。
- 映射固定为：CAN3 DBC=`ch3`、CAN4 DBC=`ch2`、`0x18FFF100`=`ch3`、`0x256`=`ch0`。
- CSV `CAN通道` 使用上述 `chN` 文本；Web 表格新增 channel 列。
- PC001 既有 batch framing、handshake 与 EFF packing 保持不变；每帧 i32 channel 改为逻辑标签的数值部分：CAN3/`0x18FFF100`=`3`、CAN4=`2`、`0x256`=`0`。

### R3 — 跨平台默认 TCP 与低延时兼容模式

- Windows/Linux 在 standalone 和 Godot-managed 下的默认 sink 都是 TCP Server，沿用 `who`/`PC001` 握手和现有 batch wire 协议。
- 默认 Linux 启动不得探测、配置或打开 `can0`，不得调用 can0 helper。
- 原 `--sink socketcan --interface can0` 路径保留，统一标注为“低延时模式（暂时停止维护）”，只有显式参数才能进入；既有 nonblocking、coalescing、fairness、拥塞和终端错误语义不得改变。
- Web transport capability 按实际 active sink 判断，而不是按操作系统判断：默认两平台显示 TCP 控制；只有显式低延时模式才显示/允许 can0 restart。
- Godot bridge 的参数、状态投影和用户文案同步为两平台默认 TCP；真实 PC001 handshake 与 forwarding intent 继续分离。

### R4 — `0x18FFF100` 三态权威

- `0x18FFF100` 作为专用 console row 显示 channel、payload、频率、实际频率和新鲜度，并支持 Web custom 编辑。
- 该帧没有 DBC signal/物理量定义；custom 弹窗只允许编辑 raw payload 和 frequency，物理值区域明确显示“无物理量定义”，不得伪造 byte 字段为物理量。
- `off` 同时禁止 timed burst 和 custom 周期发送。
- `custom` 按已保存的 payload 与整数 `1..100 Hz` 持续发送，不同时运行 timed burst。
- `simulation` 保留原 CTNC timed trigger 语义：固定默认 payload、50 Hz、10 秒、最多 500 帧；重复 trigger 替换窗口、不 catch-up、不重叠。
- CTNC command 6 是该 row 的 simulation producer，因此“全部仿真”必须把 `0x18FFF100` 置为 simulation，且不得将它列入 unsupported/forced-off。
- 三态互斥；authority 变化必须停止/清理旧 authority 的 pending scheduler/timed generation，不能播放历史帧。
- standalone 不提供 simulation authority；Godot-managed 初始将该帧置于 simulation，之后允许用户覆盖为 off/custom。

### R5 — Web 批量三态

- Web 顶栏新增“全部关闭”“全部自定义”“全部仿真”三个按钮，保留单帧三态与现有编辑弹窗。
- 批量切换必须由 owner-loop 内一个原子命令完成：一次 revision 校验、一次状态变更、一次持久化/事件发布；禁止前端循环单行 mutation。
- 全部关闭：所有 row 进入 off；全部自定义：所有 row 进入 custom。
- 全部仿真：仅在 Godot-managed 可用；有 Godot producer 的 row 进入 simulation，无 producer 的 row 进入 off，并返回/显示安全关闭的 ID 汇总，不能留下旧 custom sender。
- Godot-managed 的批量和单帧覆盖仍然只在当前会话有效；standalone 的 off/custom、payload 和频率继续持久化并支持导入/导出。

### R6 — 兼容迁移与诊断

- console 内部配置 schema 固定由 3 升到 4，便携 profile schema 固定由 1 升到 2；旧版 operator DBC `dbc-config.json` 继续保持 schema 2，因 message key 含 DBC SHA 而对新版 DBC 安全回退，不在本任务中引入第三套迁移规则。
- 仅对 canonical ID、DLC、信号布局和专用 descriptor 均兼容的旧 row 迁移 payload/frequency/authority；新增、删除或布局不兼容 row 使用安全默认值，并产生聚合诊断，不得静默套用陈旧 payload。
- 既有 Web 明暗主题、展开信号、物理值/payload 双向编辑、发送频率、预期/实际频率、新鲜度、导入/导出和 revision conflict 行为保持可用。

### R7 — 本地 PC001 TCP 测试客户端

- 提供一个独立于 Gateway 进程的本地测试客户端，主动连接 Gateway TCP Server，严格完成 `who` → `PC001` 握手。
- 客户端必须正确处理 TCP 分段并解析 `[u16 LE count] + count × [16-byte can_frame + i32 LE channel]`，显示 canonical CAN ID、EFF/SFF、DLC、payload 和 channel。
- 采用 Python 3.12 + PySide6 Qt Widgets；协议核心不得依赖 Qt，GUI 使用 `QTableView + QAbstractTableModel`，后台接收通过 queued signal/主线程批量应用更新。
- 提供连接/断开、目标 host/port（默认 `127.0.0.1:5678`）、接收计数、最近接收时间及协议/连接错误诊断；断开重连后不得把上一连接的残留 buffer 解释为新会话数据。
- 主表按 `(CAN ID, channel)` 聚合而非无限追加日志，显示 CAN ID、EFF/SFF、channel、DLC、最近 payload、累计次数、实际频率和新鲜度；支持暂停界面刷新、清空、CAN ID/channel 过滤和排序。暂停只冻结显示，不阻塞 socket 消费。
- 高频收包可持续解析，但 GUI 更新合并到约 20 Hz；不得逐帧跨线程修改 Qt model 或产生无界内存增长。
- 默认用于人工本地测试，不改变 Gateway server、PC001 wire、发送权威、CAN 编码或正式产品运行路径。
- 生成独立 Windows `onedir + zip` 测试工具包；源码可直接运行。测试客户端不进入 Gateway/Godot 正式发行包，也不增加正式运行依赖。

## Acceptance Criteria

- [ ] AC1：新版 bundle hash、30 帧 catalog、内嵌/相邻 exact duplicate 静默折叠及 provenance 均通过自动测试。
- [ ] AC2：`0x18FFF000` 的 Godot 与 Web 编码都由 DBC codec 产生 DLC=8 小端 payload，且仓库中没有生产路径调用其专用 encoder。
- [ ] AC3：DBC 编码覆盖除 `0x18FFF100`、`0x256` 外的全部受支持帧；A800 小端回归通过。
- [ ] AC4：CAN3/CAN4/`0x18FFF100`/`0x256` 从 catalog 到 CSV/Web 的 channel 分别为 `ch3/ch2/ch3/ch0`，PC001 i32 channel 分别为 `3/2/3/0`；CAN frame bytes 和 batch framing保持不变。
- [ ] AC5：Windows/Linux 无特殊参数以及 Godot 默认拉起都进入 TCP Server，不调用 can0 readiness/helper；显式 SocketCAN 参数仍进入原低延时路径。
- [ ] AC6：`0x18FFF100` 在 Web 可见可编辑，off/custom/simulation 互斥；simulation 的 ID、DLC、payload、50 Hz、10 秒和 500 帧上限不变。
- [ ] AC7：三个批量按钮执行原子状态转换；全部仿真安全关闭 unsupported row 并给出汇总；Godot-managed 单帧覆盖仍可用。
- [ ] AC7a：全部仿真将 `0x18FFF100` 设为 simulation，随后 CTNC command 6 能触发原 timed burst；该 ID 不出现在 forced-off 清单。
- [ ] AC8：standalone 配置和导入/导出按新版 schema 持久化；兼容 row 可迁移，不兼容 row 安全回退并有聚合诊断。
- [ ] AC9：Gateway Python、React 和一个定点 Godot headless E2E 通过；视觉与真实 Windows/Linux/USB-CAN 行为按 `implement.md` 由人工最终验收一次。
- [ ] AC10：Windows/Linux Gateway 发行布局包含新版内嵌及相邻 DBC、Web assets、低延时 helper/scripts 和更新后的 manifest/provenance。
- [ ] AC11：本地 PC001 客户端可连接默认或自定义 endpoint，完成握手并持续解析真实 Gateway batch；对 CAN3/CAN4/`0x18FFF100`/`0x256` 分别显示 channel 3/2/3/0，且连接关闭、短读和非法 batch 都给出稳定诊断。
- [ ] AC12：GUI 按 `(CAN ID, channel)` 有界聚合，排序/过滤/暂停/清空有效；持续接收时约 20 Hz 增量刷新且界面保持可操作，独立 Windows 测试工具包可在无 Python 环境启动。

## Out of Scope

- 修改 PC001 batch framing、handshake 或外部接收端；本任务只升级既有 i32 channel 的值。
- 优化、扩展或重写 Linux SocketCAN 低延时模式。
- 修改 CAN 接收、PC001 001、CAN ID、EFF packing 或 `0x256` payload contract。
- 为没有 Godot producer 的 DBC row 伪造仿真物理值。
- 新增拥塞限流、总线负载阻断或长时间自动 soak。
- 让测试客户端修改 Gateway Web 配置、发送 CAN、模拟 Godot telemetry 或替代正式 PC001/GuideSystem 对端。
- 将测试客户端加入正式 Gateway/Godot release manifest 或 Linux 发行包。
