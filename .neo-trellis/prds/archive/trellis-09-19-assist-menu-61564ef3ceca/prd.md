# 辅助控制选择菜单（单热键）

## Context

平地辅助 (G) 与修坡辅助 (T) 各占一个热键。辅助功能会继续增加，改为单热键
T 弹出选择菜单，用户在菜单中挑选要启用/关闭的辅助。

## Confirmed Decisions

- **T = 唯一辅助热键**，G 退役（`operator_level_assist` 移除）。
- **菜单打开期间冻结整机**（履带 + 工作装置输入归零），与修坡预览同语义。
- **键盘导航**：W/S（arm 通道边沿）上下选择，Enter(ui_accept) 确认，
  Esc(ui_cancel) 或再按 T 关闭；数字键 1..n 直达可选。
- **预览态内 T 仍 = 确认**（模态快速路径，不绕菜单）；Esc 取消不变。
- 菜单行 = 各辅助的 advance/toggle 语义（修坡行内部已是
  off→preview→active→off 状态机）。互斥由 pipeline
  `terminal_surface` 组自动处理。
- UI 按钮（LevelAssist/SlopeAssist）保留为并行入口。

## Design

- `tracked_chassis_controller`：`TOGGLE_ACTIONS` 只留
  `operator_assist=[KEY_T]`；新增 `_assist_menu_open`/`_assist_menu_index`
  状态；菜单打开时输入冻结（与 preview 同一拦截点）；W/S 通道
  (equipment_axes.z) 边沿导航；`activate_assist_entry(i)` 按 id 分发；
  status 增加 `assist_menu` {open,index,entries:[{id,label,state}]}。
- `product_session`：`open_assist_menu/close_assist_menu/
  activate_assist_entry` + status 镜像。
- `operator_ui`：代码构建的居中 `PanelContainer`（不进 tscn，避开
  menu-theme churn），行 Button 显示 `名称 · 状态`，选中行高亮；
  status 轮询同步。LevelAssist tooltip 更新措辞（去 G）。
- `operator_ui_strings`：GUIDE_KEYBOARD 改为 T 菜单说明。

## Acceptance Criteria

- [ ] T 开菜单 → W/S 导航 → Enter 选平地 = level assist 开关。
- [ ] 菜单选修坡 = advance_slope_mode（off→preview→active→off）。
- [ ] 菜单/预览期间机器不动；Esc/T 关闭菜单。
- [ ] G 键不再触发任何辅助。
- [ ] `slope_grade_assist_test` / `bucket_level_assist_test` 等回归 PASS。
- [ ] 手感验收：菜单可读性、导航节奏、选中态。
