# 编写工程详细架构文档

## Goal

为工程和开发协作维护一份以事实为准的详细架构地图，覆盖 Python/Pinocchio、Godot、协议、地形/斗土、资产、测试、MCP 与部署，并明确当前实现、legacy 兼容、未来规划和无仓库证据的边界。

## Requirements

- 交付 `docs/architecture/engineering.md`，作为专项契约文档的导航层，不复制会快速漂移的完整 schema 或算法正文。
- 至少提供这些独立视图：
  - 系统上下文和运行期/开发期边界；
  - `motion-only`（Godot-first）与 `legacy` 能力矩阵；
  - Python `input_snapshot → InputRouter → Simulator(100 Hz) → Pinocchio FK → view_state` 调用链；
  - Godot 主场景、MotionClient/MotionPresentation、TerrainState/BucketSoilState、Terrain3D/Jolt/SoilEffects/UI；
  - 输入到状态的端到端 Mermaid 时序图；
  - authority、derived state 与 simulation/recording/terrain epoch、view revision、generation 的失效关系；
  - Python Z-up、Godot/glTF Y-up 与一次性矩阵转换；URDF、GLB、manifest、fixture 的资产关系；
  - HTTP/WebSocket 接口、默认 `127.0.0.1:8765`、消息方向、100/30 Hz 目标、profile scope、验证责任表；
  - `pixi run verify`、`backend-smoke`、Godot standalone matrix、Godot MCP 的验证/开发拓扑；
  - 已实现、legacy、deferred、未来硬件/CAN、无证据差距清单。
- 关键事实必须附仓库相对文件链接和行锚点或稳定标题；优先引用源代码/schema/spec，专项文档只作契约入口。
- 目标座舱手柄/踏板/按钮/中控/CAN-to-USB 只能作为虚线目标层，并说明当前没有 `pyserial`/`python-can`/USB/HID/ROS 等实现证据。
- 明确 Godot MCP 是编辑器开发工具，导出产品包剥离 helper；明确 Terrain3D/Jolt/粒子是 Godot 派生/展示消费者。
- 对 `motion-transport.md` 的早期全局 authority 说法、`terrain-api.md` 的 legacy scope 易误读、BabylonSim 迁移文档的历史性质增加就地状态注记或在架构入口说明；不改变协议或运行时代码。
- 页面注明事实截止日期 `2026-08-13`、source-of-truth 索引、更新触发器和 Mermaid/HTML 降级策略。

## Acceptance Criteria

- [ ] 工程人员可沿图和表追踪输入、运动计算、状态发布、Godot 消费、地形/斗土派生与显示。
- [ ] current/legacy/future 三类状态在所有视图中使用同一图例；legacy 不被描述为当前 Godot-first 产品目标。
- [ ] 接口表涵盖 hello、input_snapshot、command、view_state、status，以及 legacy recording/terrain HTTP/WS 的边界。
- [ ] 组件图涵盖代码入口、目录职责、Godot 场景节点、资产/协议/schema、测试和开发工具。
- [ ] 坐标转换、四关节/五命名 frame、GLB visual-only 与 URDF motion authority 的关系清楚且不引入第二次转换。
- [ ] 失效/重置路径能解释 epoch/revision/generation 如何清理 pose、terrain、bucket、粒子等派生状态。
- [ ] 目标硬件明确标为未来规划/未接入；没有把它们写成当前实现或验收前置条件。
- [ ] 所有关键链接有效；文档不依赖外部服务或运行时资源；纯 Markdown 阅读仍保留关键映射。

## Out of Scope

- 修改产品代码、schema、协议版本、runtime profile 或 authority ownership。
- 实现真实硬件/CAN、生产级液压/刚体/接触/颗粒土和回放产品功能。
- 将完整 JSON Schema、所有函数签名或所有测试断言复制进架构文档。
