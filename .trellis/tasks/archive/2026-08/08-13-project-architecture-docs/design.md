# 架构文档技术设计

## 1. 文档边界

本任务不建立新的运行时架构，而是建立现状架构的可读索引层。`docs/architecture/conceptual.md` 面向业务/非技术读者；`docs/architecture/engineering.md` 面向工程协作。两者共享同一套状态图例、术语和事实截止日期，但不共享一张不可维护的巨图。

专项契约仍是字段和算法的唯一细节来源：

- 运动传输：`.trellis/spec/frontend/motion-transport.md`、`protocol/godot-pinocchio-v3.schema.json`；
- profile：`.trellis/spec/backend/runtime-profiles.md`；
- Godot 边界：`docs/godot-integration.md`、`.trellis/spec/frontend/client-boundary.md`；
- legacy terrain/recording/RRD：`docs/terrain-api.md`、`docs/recording-api.md`、`docs/rrd-profile-v1.md`；
- 视觉资产：`docs/visual-model.md`、`resources/visual/sy205_visual_manifest.json`；
- 发布验证：`docs/release-candidate.md`。

架构文档只保留稳定映射、方向、状态和导航链接；当某一字段、算法或测试命令变动时，不在架构图中复制整份合同。

## 2. 共享视觉语言

状态颜色/线型固定为：

| 状态 | 视觉约定 | 含义 |
|---|---|---|
| Current | 深蓝实线、浅蓝底 | 当前 Godot-first 产品路径，仓库有运行/测试证据 |
| Legacy | 灰色点划线、浅灰底 | 兼容 profile 或历史迁移路径，仍可回归但不是主产品目标 |
| Planned | 黄色虚线、浅黄底 | 用户确认的目标方向，但当前没有实现或协议证据 |
| Derived | 绿色细线 | 从权威快照派生的渲染/接触/粒子/缓存状态 |
| Dev-only | 紫色虚线 | Godot MCP、编辑器工具和开发期辅助，不进入导出产品 |

Mermaid 与 HTML 图必须使用同一节点 ID 语义；HTML 版允许使用 `<svg>` 或带边框的 `<table>`/`<div>`，但图下必须有文本/表格降级。

## 3. 事实分层

每个架构声明先标记为 `Current`、`Legacy`、`Planned`、`Deferred` 或 `No evidence`。尤其要区分：

- 当前输入是键盘/通用手柄，未来座舱硬件/CAN 不是输入实现；
- Python 运动/FK 权威与 Godot 本地 terrain/bucket 逻辑并存；
- `Terrain3D`、Jolt、GLB、粒子是派生或视觉层，不拥有 Python 运动 authority；
- legacy Python terrain/recording/replay 继续存在，但回放不属于当前产品需求；
- MCP 是开发工具而非产品运行时。

## 4. 父子任务交付关系

1. 概念子任务先确定读者语言、状态图例和目标硬件虚线层。
2. 工程子任务复用同一图例，完成组件/接口/时序/验证视图。
3. 父任务最后整合 README 入口、链接、术语、冲突注记和全局验收。

## 5. 更新/回滚策略

文档按独立文件提交。若事实检查发现某个代码/协议链接漂移，优先修正链接或状态注记；不为让图好看而修改运行时代码。若 Mermaid/HTML 在某个渲染器不可见，保留 Markdown 表格/文本视图作为可接受降级。
