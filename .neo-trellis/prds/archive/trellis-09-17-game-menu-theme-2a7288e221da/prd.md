# Game menu theme + centered layout

## Goal

菜单内可切换的双 UI 主题：**调试**（现状视觉，默认）与**工业**（新游戏化主题）。共用行为：菜单打开时左上 HardwareDock 隐藏、作业菜单视口居中。工业主题下额外做全套游戏化改造。

## Requirements

### 共用（两主题一致）
- 菜单打开 → HardwareDock 隐藏；`StatusPanel` 以视口中心居中（1280×720 / 1920×1080 / 2560×1080 不出界）。
- 菜单内"设备与设置"页新增主题选择器（调试 / 工业），选择持久化到 `user://operator_ui.cfg`，切换即时生效（菜单不关闭）。

### 调试主题（默认）
- 保持现状视觉与结构：`GameSkin.create()` 现有扁平主题、HardwareDock 驾驶时常驻左上、菜单组合不变。
- 唯一变化即上述共用行为（菜单开时 dock 隐藏 + 居中）。

### 工业主题
- HardwareDock 不再出现（驾驶态也无）；驾驶时只留右下操作提示 HUD + 左下菜单按钮 + 录制徽标。
- 菜单面板头部右侧嵌入精简 PC001 连接灯（复用现有灯+文字，忽略鼠标）；CAN 录制 / Gateway 重启按钮迁入"高级工具"页并恢复可聚焦。
- `GameSkin` 扩展工业风样式：深色半透明面板（描边+投影）、按钮全态、琥珀 focus 光环、TabBar 选中态、滚动条/LineEdit/PopupMenu/Tooltip/确认对话框全覆盖；CheckButton 开关与下拉箭头用代码生成纹理（无二进制资源、默认字体栈保 CJK）。
- 菜单头部：大标题 + 琥珀装饰条 + 状态灯；"继续驾驶"为琥珀主 CTA；可加程序化警示条纹/角框。
- 打开动画加轻微 scale-in；`menu_atmosphere.gdshader` 加暗角/细扫描线（可用 uniform 控制强度，调试主题保持现有输出）。
- `control_input_hud.gd` 按主题变体换肤（工业：琥珀高亮按键块；调试：现状）。几何布局不变。

### 实现要点
- `GameSkin.create(variant)` / `MenuLayout.build(ui, variant)` 带变体参数；变体决定组合差异（dock、头部灯、CAN 按钮归属、装饰）。
- 运行时切换 = 拆除已组合 UI（MenuRoot、dock、PanelToggle、GuidePanel、Confirmation 旧实例）→ 重新实例化 `operator_menu_controls.tscn` → 重绑定 + 重连信号 + 重建。需把 `operator_ui.gd` 中 @onready 绑定、信号连接、建后接线（resume/tabs/map_selector）抽成可重入方法。
- `_set_panel_collapsed`：dock 仅在调试主题且驾驶态可见；菜单打开动画对两变体一致。

### 契约同步
- `operator_ui_test.gd`：按变体断言——调试：驾驶时 dock 可见、菜单开时隐藏且居中；工业：菜单头部灯可见、高级页 CAN 控件可达、驾驶时无 dock。
- `.neo-trellis/modules/godot-client/game-menu-hud.md`：重写布局契约段。

### 非目标
- 不改输入/焦点/暂停/生命周期/确认框契约；不改 `get_control_for_test` 语义键；不改玩法与 CAN 监督逻辑；不引入字体文件。

## Acceptance Criteria

- [x] `control_input_hud_test.gd`、`ict_status_indicator_test.gd`、`gateway_restart_ui_test.gd`、`camera_workflow_test.gd` headless 实跑通过；`operator_ui_test.gd`（已更新断言）仅剩本机既有基线失败 "did not publish soil timing"（上个任务已记录为环境基线问题，与 UI 无关）。
- [x] 两主题下三档视口面板均在界内且水平居中（测试断言）；菜单内切换主题即时生效（运行时重建）且写入 `user://operator_ui.cfg`。
- [x] 截图实测（`tests/ui_theme_shot.gd` → `output/ui_theme/*.png`）：调试主题驾驶时 dock 常驻、菜单开时隐藏且居中；工业主题驾驶时无 dock、菜单头部灯显示"未连接"、CAN 控件在高级工具页可达。
- [ ] 视觉与手感人工验收（spec 约定归人工）。

## Implementation Plan

- M1 布局+双主题骨架：`MenuLayout.build(ui, variant)` 变体化、`operator_ui.gd` 绑定/连接/重建重构、主题选择器+持久化、测试与 spec 更新。
- M2 工业主题表现：`game_ui_theme.gd` 扩展 + 生成图标纹理 + 菜单装饰 + HUD 换肤 + shader/动画增强。

## Files

- `godot/client/scripts/game_ui_theme.gd`、`game_menu_layout.gd`、`operator_ui.gd`、`control_input_hud.gd`
- `godot/client/shaders/menu_atmosphere.gdshader`
- `godot/client/tests/operator_ui_test.gd`
- `.neo-trellis/modules/godot-client/game-menu-hud.md`
