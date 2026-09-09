# 实施结果

已完成开发；用户于2026-09-09明确要求提交、推送并归档。

## 改动
- SY135 前倾初值 6°，向 cavity -Z（刃口）推进。网格、法线和体积反解共享 relief；实测内衬不变，留出斗口余量。
- 满斗视觉体积从约 0.2694 变为 0.2338 m³（少约 13.2%），来自防越界高度余量；库存/声明容量不变。SY205 形态与约 0.4006 m³ 视觉体积不变。
- 填料挂到真实 cavity frame，使用与 proxy 采样共享的局部变换；绑定姿态不再依赖 30 Hz 快照。
- model_replacing 在资产替换前回收填料，包括候选合同失败；reset、旧机型快照和两种销毁顺序有保护。

## Agent automated
Godot 4.7.2 custom build，五项均退出 0，无 SCRIPT ERROR：
- bucket_fill_surface_test：前部增量、rim、导入内衬接触、闭合绕序/法线、单调和确定性。
- bucket_fill_follow_test：SY135 → SY205 → SY135；无新快照连续移动旋转；旧 world/model 快照；恒定重建计数/网格复用；空斗/reset/失败恢复；effects-first/model-first 清理。
- soil_effects_visual_mound_test：更新预算/复用及 VFX 回归。
- soil_release_visual_quality_test：稳定卸土视觉合同。
- model_switch_test：模型切换、帧变换与材质回归。
独立几何复核无功能问题；挂载复核指出失败切换回收时机，已改为替换前 signal 并补测试通过。

## Human manual — 用户批准收尾，逐项观感检查未单独报告
SY135 balanced 下观察半斗/满斗向刃口推进幅度；连续横移、急停、回转应随斗壳一致；换 SY205 检查跟随与外观。6° 是可调初值，自动测试不宣称观感通过。
未启动交互游戏、导出或性能 soak；无关任务/插件/配置保持原样。
