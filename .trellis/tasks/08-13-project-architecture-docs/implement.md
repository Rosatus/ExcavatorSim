# 架构文档执行计划

## 顺序清单

1. [x] 冻结事实索引：复核 Python、Godot、协议、资产、测试、MCP 的关键 file:line；登记当前/legacy/planned/deferred 标签。
2. [x] 完成子任务 `08-13-conceptual-architecture` 的 PRD/design/implement，进入实现前再审阅状态图例。
3. [x] 实现 `docs/architecture/conceptual.md`：业务摘要、Mermaid 主图、HTML 对照图、纯 Markdown 降级、目标硬件虚线层。
4. [x] 检查概念图：节点/箭头/状态与 PRD 一致，非技术读者可独立读懂。
5. [x] 完成子任务 `08-13-engineering-architecture` 的 PRD/design/implement，进入实现前再审阅其接口和时序范围。
6. [x] 实现 `docs/architecture/engineering.md`：组件图、profile 矩阵、调用链、时序、authority、坐标/资产、接口、验证和差距视图。
7. [x] 父任务整合：在 `README.md` 的 repository map/阅读顺序中增加两个架构文档入口；必要时给早期冲突文档增加最小 scope 注记。
8. [x] 做文档质量检查：仓库内链接与路径、Mermaid fenced block、HTML 降级、术语和状态图例一致性；确认无运行时代码变化。
9. [x] 运行 Trellis quality check；检查工作树时保留用户已有未归属改动。
10. [ ] 用户确认最终文档内容后，按子任务顺序提交并归档子任务，最后归档父任务并记录 journal。

## 验证命令

- `rg -n "\]\([^)]*\)" docs/architecture README.md`，人工核对相对链接。
- `rg -n "Current|Legacy|Planned|Derived|Dev-only|未来规划|未接入" docs/architecture`，核对状态标签覆盖。
- `rg -n "```mermaid|<svg|<table|<div" docs/architecture`，核对双版本图和降级文本。
- `git diff --check -- docs/architecture README.md .trellis/tasks/08-13-*`。
- 运行 `trellis-check` 对文档事实、spec 引用、cross-layer 一致性做最终检查；不需要启动 Godot/Python 服务。

## 风险与回滚点

- Mermaid/HTML 渲染器支持未知：保留等价表格/文本，不让图成为唯一交付。
- legacy 文档措辞可能继续漂移：在架构入口明确 scope，并链接专项契约；必要时只改文档标题/注记。
- 目标硬件信息可能被误解为已实现：统一 Planned 图例、虚线和表格状态列，审核时逐项搜索 CAN/中控/座舱。
- 工作树有大量用户未提交改动：只添加本任务文档及 README/必要 scope 注记，不清理或回退其他路径。
