# 实施计划

状态：用户批准后已运行 `task.py start`。代码与自动验证完成，待人工视觉验收；未归档。

## 顺序

- [x] 实施前读取 trellis-before-dev、frontend boundary、soil-release-visuals、validation-budget；记录本任务工作区范围。
- [x] 检查两机型实际斗底/内壁坐标、材质与法线；通过 raw GLB 和 headless 导入做结构测量。
- [x] 建立表现轮廓及聚焦 fixture；修复低填充贴底/侧壁并校准中满斗增长。
- [x] 改善稳定起伏、平滑法线和细微色差，保留共享纹理/尺度、资源复用及更新门限。
- [x] 修正 SY135 材质与 SSAO，验证实例隔离及画质切换恢复。
- [x] 完成五项聚焦自动验证与两份独立只读复核，结果见 result.md。
- [ ] 用户视觉反馈后收敛 R1–R5，更新文档并按 Trellis 收尾。

## Agent automated

候选入口，只运行最终改动涉及的行为：

```powershell
& $GodotExe --headless --path godot/client --script res://tests/soil_effects_visual_mound_test.gd
& $GodotExe --headless --path godot/client --script res://tests/soil_release_visual_quality_test.gd
& $GodotExe --headless --path godot/client --script res://tests/visual_pass_test.gd
```

`$GodotExe` 实施时解析工作区配置，不猜路径。只有改动资产加载/映射才追加机型资产合同测试。规划阶段不启动测试。

聚焦断言覆盖两机型底部/侧壁包络、空斗隐藏、5/25/50/75/100% 单调增长、不穿底、同输入确定、变换跟随、重置/换机型缓存清理、mesh/material 复用及更新上限。照明/材质修改需验证实例隔离、配置生效和重复切换恢复。权威边界通过代码审查和受影响回归确认，不把材质参数存在当作视觉验收。

## Human manual

状态 `pending human review`；用户启动正常产品场景，以 balanced 档分别检查 SY135/SY205：

1. 空斗从可见内腔角度看底板和两侧壁，转动上车/铲斗对比迎光与背光。
2. 连续挖土，观察少量、四分之一、半斗、四分之三及满斗的贴底增长、贴壁、颗粒与起伏。
3. 抬升、收斗、翻转，检查无悬浮底面/矩形侧边；卸料后填料随库存减少，空斗无残留。
4. low/high 再回 balanced，检查斗内可读、阴影深度与外壳/地面不过曝。
5. 重置与换模型，检查无填料残留或材质污染。

不默认启动游戏、截图矩阵、导出或性能 soak。按 validation-budget，视觉判断由用户完成；若用户明确要求 Agent 驱动运行，再按其范围执行。

## 收尾与回退

分别记录几何、材质、环境配置的变动，只审查本任务文件/hunk。保持 GLB、物理合同及库存路径；若必须扩展这些边界，先更新设计。headless 通过不能替代视觉验收。
