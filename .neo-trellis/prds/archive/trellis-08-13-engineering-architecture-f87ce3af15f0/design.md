# 工程详细架构设计

## 视图分组

- Context：Windows desktop、Godot、Python service、目标座舱硬件（Planned）、MCP（Dev-only）。
- Runtime：profile 矩阵与 Python 固定频率调用链。
- Client：Godot scene tree、motion presentation、terrain/bucket/visual/UI 派生链。
- Contracts：WebSocket/HTTP、端口、消息方向/频率、坐标/资产映射。
- Operations：测试矩阵、backend smoke、MCP smoke、发布和差距。

## 数据流原则

以 `input_snapshot` 和 `view_state` 为跨进程主轴。Python 运动 authority 只发布权威 joint/frame 状态；Godot 在协议边界一次性完成坐标转换并更新视觉层。Godot terrain/bucket 的本地语义状态只向 TerrainRenderer/Terrain3D/Jolt/SoilEffects 派生，不回写 Python。epoch/revision/generation 是跨层失效键，图中用回收/清空箭头表示。

## 兼容策略

把 legacy terrain/recording/replay 画为灰色 profile 分支，链接现有专项文档；不把早期 `motion-transport.md` 的全局 authority 句子当作当前 Godot-first 事实。目标硬件只画在 Context 的 Planned 分支。
