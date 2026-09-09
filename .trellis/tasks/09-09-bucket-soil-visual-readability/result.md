# 实施结果

代码与五项聚焦测试完成。2026-09-09 用户反馈“做的很好”，认可当前成果并明确要求提交、推送和归档。

## 改动

- 两个 source-hash-bound 视觉轮廓匹配实际导入斗腔；SY135 向 cavity -Y、SY205 向 +Y 生长。
- 填料从内衬低点产生薄层，随装载量扩展并堆高；替换固定矩形底面/直立裙边，加入固定起伏、平滑法线、细微色差。共享纹理与局部三平面坐标保持。
- 修正首次少量土、无效合同恢复和模型切换时的缓存；保留 ArrayMesh、10 Hz、5% 门限及既有库存/物理边界。
- SY135 每实例复制深色钢材质，修正近黑且偏光滑的原始斗壳；SY205 atlas 不变。缩小/减弱 SSAO，保留全局曝光与日光策略。

## Agent automated

Godot `4.7.2.stable.custom_build.ed1daf0bf`，实际路径 `E:/applications/godot_voxel/godot.windows.editor.x86_64.exe`。

| 检查 | 结果 |
|---|---|
| `bucket_fill_surface_test.gd` | PASS：两模型 GLB hash / cavity 证据、导入三角面独立求交、闭合/绕序/法线、0.5% 到 100% 单调增长、确定性、重置/无效恢复及资源隔离 |
| `soil_effects_visual_mound_test.gd` | PASS：5% / 10 Hz 门限、ArrayMesh 复用、变换跟随和既有 VFX 行为 |
| `soil_release_visual_quality_test.gd` | PASS：材质共享、局部映射、VFX 与稳定土壤交易边界 |
| `visual_pass_test.gd` | PASS：档位切换、SSAO 与曝光、既有场景合同 |
| `model_switch_test.gd` | PASS：真实 SY135 → SY205 → SY135 激活、材质修正恢复和原始资源不变 |
| `git diff --check` | PASS（另有既有 CRLF 规范化提示，无空白错误） |

`visual_pass_test` 退出码 0，但场景清理记录 Terrain3D 弃用调用、10 个 ObjectDB 实例和 3 个资源仍在使用的日志。这些路径未由本任务修改，尚未单独复现基线；不能把这项测试称为无告警。

旧 `soil_effects_visual_mound_test` 原先仍断言历史 24 cm 出口偏移。本次确认 HEAD 的产品代码早已是 5 cm，修正断言为 1.95 m（源点 2 m），未改变卸料实现。

两份独立只读复核完成：几何/权威边界未发现违规；补齐无效状态后的重建及真实模型切换材质检查后，受影响测试再次通过。

## Human manual

用户已认可当前成果并批准收尾；未单独记录以下逐项人工检查的执行过程。implement.md 的最小步骤：balanced 下两机型空/半/满斗，少量装土、连续增长、抬升收斗翻转、卸空；low/high 切换与重置。重点观察内壁接触处是否有细缝、土面是否自然、背光内腔是否可读、车身/地面是否保持正常亮度。

未启动交互式游戏或生成游戏截图，未跑全测试矩阵/导出/性能 soak。离线截面图仅用于几何校准，不代替视觉验收。

## 本任务文件

- `godot/client/scripts/bucket_fill_surface.gd`、`bucket_visual_materials.gd`（新）
- `godot/client/scripts/soil_effects.gd`、`motion_presentation.gd`、`visual_environment.gd`
- `godot/client/resources/visual/{sy135,sy205}_bucket_fill_profile.json`（新）
- `godot/client/tests/bucket_fill_surface_test.gd`（新）、`model_switch_test.gd`、`soil_effects_visual_mound_test.gd`、`visual_pass_test.gd`
- `.trellis/spec/frontend/soil-release-visuals.md` 与本任务文档/测量脚本。

其他任务的配置、插件和场景工作均未纳入本任务改动。
