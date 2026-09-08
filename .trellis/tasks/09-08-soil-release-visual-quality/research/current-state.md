# 当前实现调查

调查日期：2026-09-08；基于提交 `9c1f5dd` 后的代码。以下为静态调查，未进行本轮运行画面验收。行号为调查时定位。

## 时序

- `godot/client/scripts/voxel_excavation_authority.gd:1624-1648`：surface deposit 先 paste SDF、提交材料，再发布 accepted dump event；native 路径同样先写后发（1883-1912）。
- `godot/client/scripts/excavation_world.gd:137-153`：authority step 后发 excavation_changed；`soil_effects.gd:326-396` 消费快照和事件。
- `voxel_excavation_authority.gd:1389-1409`：事件已有 release transform、landing 和 release duration。`soil_effects.gd:387-409` 将连续发射段限制为短窗口。
- 当前没有独立的飞行期间库存状态。仅提前视觉发射可能遇到尚未接受的卸土；仅延迟地面显示会引入视觉与真实表面不一致。这两条路线均不能直接当作已批准的实现。

## 空中与表面

- `godot/client/scripts/soil_effects.gd:194-225`：主颗粒为 BoxMesh，尺寸 0.046 × 0.028 × 0.061 m，纯色粗糙材质。
- 同文件 261-288：大土块也是 BoxMesh，已有池化、大小和旋转变化。
- 同文件 178-191、463-499、724-824：桶内土为封闭可复用 ArrayMesh，量化更新，材质以纯色为主。
- `godot/client/scripts/voxel_work_zone.gd:48-70,185-189`：可挖 terrain 使用 TEXTURES_NONE 和纯色 StandardMaterial3D。
- `godot/client/assets/terrain/shaders/worksite_soil_common.gdshaderinc:7-50`：已有程序化地表色彩和粗糙度噪声，可作为材质一致性参考。
- `godot/client/assets/terrain/terrain3d_demo_assets.tres:3-28`：已有 Ground037 贴图；许可位于 `godot/client/demo/assets/textures/asset_licenses.txt`。生产 Terrain3D shader 当前有意不采样这些贴图，不能将资源存在当作已接入。
- `soil_effects.gd:663-669`：voxel 模式禁用永久装饰 mound，地面堆积由真实 SDF 输出。

## 约束与验证

- 保留当前池化、颗粒质量档和桶内网格复用；材质增强优先避免提高体素密度。
- `godot/client/tests/soil_effects_visual_mound_test.gd` 有旧行为断言；上一任务已确认其 delayed-release source 断言在原基线上也失败，不能直接视为本轮引入回归。
- 自动结构测试不能代替颗粒轮廓、时序和材质的真实画面验收。
- 相关设计原文：`.trellis/tasks/archive/2026-09/09-02-voxel-dumping-soil-cycle/design.md` 和 `research/2026-09-08-visual-first-reassessment.md`。其中已承认批提交与飞行时间近似；具体方案需由本轮重新收敛。
