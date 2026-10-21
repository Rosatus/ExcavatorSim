# 建立项目架构文档

## Goal

建立一套面向不同读者、可长期维护的项目架构文档：非技术读者能从一张简洁概念图理解“人如何操作、系统如何计算、画面如何呈现”；工程人员能准确追踪硬件/输入、Python/Pinocchio、Godot、协议、状态权威、信号时序、资产、测试与部署边界，并能从总图进入现有专项契约。

## Background and Confirmed Facts

- 参考图采用“外围实体设备 + 中央虚拟主机 + 显示与信号箭头”的简洁构图；本项目借鉴其信息层级，并把仓库尚未实现的 CAN、中控、座舱触屏等设备纳入目标拓扑，但统一标为未来规划/未接入。
- 当前产品主路径是 Windows Godot 4.7 Forward+ 桌面客户端连接本机 Python/aiohttp 服务，默认运动端点为 `ws://127.0.0.1:8765/ws`。
- Python/Pinocchio 是四关节运动、FK frame、输入安全和生命周期权威；固定仿真目标为 100 Hz，Godot 输入发送与显示目标为 30 Hz。
- Godot 消费 `godot-pinocchio-v3` WebSocket 状态，并在单一协议边界把 Python Z-up frame 转为 Godot Y-up；Godot 不向 Python 回写视觉变换。
- Godot-first/motion-only 路径中，Godot 的 `TerrainState`、`BucketSoilState` 和相关 generation/revision 是本地地形与斗土逻辑状态；TerrainRenderer、Terrain3D、Jolt 查询、粒子与碰撞均为派生消费者或表现层。
- legacy profile 仍保留 Python terrain/recording/replay/RRD 能力用于兼容与回归，但回放已由用户明确排除出当前产品需求。
- 当前输入实现是键盘与通用游戏手柄，经 Godot 生成 `input_snapshot`；仓库中没有 CAN、串口、USB HID、中控或真实座舱硬件接入实现。
- Godot MCP/godot_ai 是编辑器开发工具；导出时 helper 会被剥离，不是产品运行时依赖。
- 用户已确认视觉目标“尽量拟真”，但生产级液压、刚体动力学、接触标定和颗粒土仍是延后模型工作。
- 现有文档存在 profile scope/历史措辞混淆：部分早期文档把 terrain/recording/replay 泛化为 Python 全局权威，而当前 Godot-first 路径已经把本地 terrain/bucket 交给 Godot。新架构文档必须显式区分 current Godot-first、legacy compatibility 与 future/deferred。

## Requirements

### R1 — 非技术概念架构

- 以简体中文编写，控制为一张主图配少量图例和一句话说明。
- 主图至少呈现：操作人员/输入设备、Python 运动与安全核心、Godot 拟真场景、挖掘机与施工地形、显示输出，以及双向控制/状态闭环。
- 使用业务语言解释“Python 负责算得对且安全，Godot 负责看得见、可交互且拟真”，避免暴露类名、线程名或完整协议字段。
- 对“已实现 / legacy 兼容 / 未来或未接入”使用明确且一致的视觉状态，不让非技术读者误认为 CAN/真实中控已经完成。
- 为同一概念信息制作 Mermaid 与 Markdown 内嵌 HTML 两个视觉版本，便于比较；两版语义必须一致，即使渲染器不支持其中一种也有邻近文本摘要。

### R2 — 工程详细架构

- 用一份工程架构 Markdown 作为长期维护入口，内部包含多张目的单一的图和配套表格，不做一张无法阅读的“巨图”。
- 至少包含以下视图：
  1. 系统上下文与运行/开发期边界；
  2. current Godot-first 与 legacy profile 的组件/能力矩阵；
  3. Python 后端组件与固定频率仿真调用链；
  4. Godot 主场景、运动表现、地形/斗土、视觉/UI 组件图；
  5. 输入命令与 `view_state` 的端到端时序图；
  6. 状态权威、派生状态、generation/epoch/revision 失效关系；
  7. 坐标系与 GLB/URDF/manifest/fixture 资产关系；
  8. HTTP/WebSocket 接口、端口、方向、频率、主要消息/端点和验证责任表；
  9. 测试、MCP 开发工具、构建/运行与发布验证拓扑；
  10. 已实现、legacy、deferred、无仓库证据的差距清单。
- 接口表必须区分 motion-only 与 legacy，说明 `godot-pinocchio-v3`、loopback 默认值、hello/input/view/status 节奏，以及 legacy recording/terrain HTTP/WS 的 profile scope。
- 硬件表必须如实列出键盘/游戏手柄和桌面显示为当前实现；任何参考图硬件只能按用户最终确认的状态展示。
- 目标硬件层可以列出座舱手柄、踏板、按钮面板、中控/触屏和 CAN-to-USB，但必须与当前输入路径分离，并附“尚无仓库实现证据/需要后续协议与驱动决策”说明。
- 每个关键组件/合同都要链接到代码、schema、Trellis spec 或现有专题文档，不复制会快速漂移的完整字段定义。

### R3 — 信息架构与长期维护

- 文档放在 `docs/architecture/`，概念文档与工程文档职责分离。
- 从仓库 `README.md` 增加清晰入口，阅读顺序为“概念架构 → 工程架构 → 专项契约”。
- 新文档包含状态图例、事实截止日期/版本、source-of-truth 索引和“何时必须更新本页”的维护触发器。
- 对发现的直接冲突做最小范围的 profile scope/历史状态修正或注记，使新入口不会同时指向互相矛盾的现状描述；不借文档任务修改产品行为。
- Mermaid/HTML 不是唯一信息载体；重要映射同时以普通 Markdown 表格或文本表达，保证纯文本可审阅。

## Acceptance Criteria

- [ ] `docs/architecture/` 中存在非技术概念架构和详细工程架构 Markdown，README 可直接导航到两者。
- [ ] 同一概念架构具有 Mermaid 与 HTML 两个可比较版本，节点、方向和状态语义一致。
- [ ] 一名不了解代码的读者能从概念图回答：谁操作、谁计算运动、谁生成画面、结果在哪里看到。
- [ ] 一名工程人员能从工程文档追踪：输入设备 → Godot input snapshot → Python 输入仲裁/100 Hz 仿真/Pinocchio FK → 30 Hz view state → Godot pose/地形/视觉呈现。
- [ ] 权威矩阵明确区分 motion-only Godot-first 与 legacy；不得把 Godot 粒子、Terrain3D/Jolt、MCP 或 GLB 视觉模型标成运动权威。
- [ ] 当前已实现硬件、软件与接口不混入未来或参考图假设；所有未实现项都有显式状态标签。
- [ ] 工程文档覆盖组件、接口、信号方向、时序/频率、坐标转换、状态失效、资产、部署与验证，并链接到相应权威来源。
- [ ] 现有直接冲突文档至少增加明确 scope/status，读者不会再把 legacy terrain API 或早期 motion 文档误解为 Godot-first 全局架构。
- [ ] Markdown 经过链接/路径检查；Mermaid 语法可解析，HTML 降级后仍保留可读文本；不依赖网络资源。
- [ ] 仅修改文档、Trellis 任务/规范与必要索引，不触碰产品运行行为，不覆盖工作区既有未归属改动。

## Out of Scope

- 实现真实 CAN、中控、触屏、踏板、专用手柄或其他硬件驱动。
- 修改 Python/Godot 运行时架构、协议版本、模型算法或 authority ownership。
- 恢复或扩展回放产品需求。
- 设计生产级液压、刚体动力学、碰撞标定或颗粒土模型。
- 为文档引入站点生成器、外部图床或新的运行时依赖。

## Resolved Scope Decision

- 正式架构包含参考图里的真实座舱硬件/CAN 目标拓扑；这些节点和链路只作为“未来规划/未接入”虚线层，与当前键盘/游戏手柄主路径完全分开，不得写入“已实现”组件矩阵或当前验收链路。

## Child Deliverables

- `08-13-conceptual-architecture`：交付 `docs/architecture/conceptual.md`，负责非技术概念图、Mermaid/HTML 对照、状态图例和面向业务的权责说明。
- `08-13-engineering-architecture`：交付 `docs/architecture/engineering.md`，负责工程组件、接口、时序、状态、资产、测试、部署和差距图表。
- 父任务集成工作：补充 `README.md` 架构入口，统一两个子文档的术语/图例/事实截止时间，检查链接和 cross-document consistency，并在归档前完成整体验收。
