# 2026-09-12 用户抓取诊断与修复

## 输入与结论

用户提供的 `capture-2026-09-12T21-01-19-31382681.json` 是 Windows / Forward+ / SY135 / balanced / 1920×1080 实际游戏录制，CPU Ryzen 7 9700X、GPU RX 9070 XT，轻量计时开启、完整诊断关闭。记录中的 cutter/authority SHA-256 与本轮修改前源码相同。另两份 `21-02-20-2670417`、`21-02-20-3069267` 均为 headless，仅3帧/0帧且无已提交挖掘，不作为用户操作证据。

分析命令：`python tools/analyze_performance_capture.py <capture> --output output/digging-performance/user-capture.analysis.md --json-output output/digging-performance/user-capture.analysis.json`。

- 有效驾驶1026帧，平均44.2 FPS；P50 16.656 ms，P95 37.784 ms，P99 208.130 ms，最大238.599 ms。排除首帧及失焦区间，不能把失焦期间的25秒长间隔算作挖掘卡顿。
- 58帧超过33.33 ms，31帧超过100 ms；后者26帧累计8个physics step，存在CPU耗时与物理追赶相互放大的表现。
- 36.364s和39.011s两个人工卡顿标记附近，最慢帧238.599/228.081 ms，土体总计166.268/161.415 ms，其中提案129.290/130.215 ms（都是整帧累积，不是单次调用）。最慢帧GPU 1.277 ms、渲染CPU 0.691 ms。
- 主视口GPU P95 1.516 ms，CPU P95 0.826 ms；当前证据优先支持同步土体/物理CPU瓶颈。调低分辨率或阴影缺少针对性，不用改画质掩盖CPU计算。
- 待就绪和土体队列的4Hz采样峰值均1。没有观察到长队列堆积，但低频采样无法排除瞬间mesh/collision成本；没有把所有非土体耗时归给单一原因。

## 实施

1. `VoxelBucketCutter.build_proposal` 增加可选的纯接触采样回调。SY135提斗残土扫描使用它；齿尖准入仍使用带梯度的原采样器，其他调用者省略参数时行为保持原样。
2. `VoxelExcavationAuthority._sample_contact_sdf_world` 保留原世界坐标变换、舍入及3×3×3可编辑邻域检查，只读取中心SDF。重复坐标仅在一次build_proposal内部缓存；退出即丢弃，因此下一次编辑、tick、generation不复用旧土体。
3. `VoxelCutProposal._compute_hash` 以深复制的源值快照进行内容比较，源值相同时复用原规范化SHA-256。源值变化时重新按原格式计算，未改变哈希格式、几何、账本或校验策略。嵌套字典、packed数组、身份字段修改以及伪造input_hash仍被拒绝。避免同一大提案创建、cutter校验、authority校验、commit校验时反复格式化路径点。
4. 新回归加入已有 `run_voxel_cutting_tests.ps1`；未执行该聚合完整矩阵，仅运行与这次变更直接相关的脚本。

## Agent automated

锁定Godot 4.7.2 / Voxel Tools 1.7，headless。以下均exit 0且本轮stderr为空：

- `voxel_cut_proposal_hash_test.gd`：身份、嵌套几何、packed点/半径、components修改、伪造哈希、修改后恢复、独立复制；新缓存返回值与原未缓存规范化算法完全一致。
- `voxel_lift_contact_performance_test.gd`：0.125/0.20m，实地SDF、固体/清空/重新加入残土、无效点、逐提案结果与身份/几何等价。421帧既有真实铲斗轨迹中292个提案接受，前后结果全部一致。
- `voxel_bucket_cutter_test.gd`：切割与旋转扫掠覆盖；1425个内部点和27个旋转顶层点无遗漏。
- `voxel_continuous_lift_test.gd`：提交后的暂停、连续提斗、旋转提斗与退出；历史覆盖115/120点均无残留，账本与外侧地面正确。
- `voxel_live_residual_test.gd`：421帧真实轨迹，已知残土目标全部清除，292次准入，161次revision；外侧地面及质量守恒通过。
- `voxel_cutting_performance_test.gd`：两种分辨率覆盖等价、真实事务SDF与账本、完整诊断/轻量计时/关闭等价、队列和重复信用保持正确。其PAIRED_COMMITS比较的是前一轮coverage优化，不能当成本轮两处优化的收益。
- `voxel_cut_queue_order_test.gd`：固定输入顺序保持。
- scoped `git diff --check`通过；runner只增加已单独通过的两个测试名。

性能配对每组同进程交替顺序；不把headless数据称为实际FPS：

| 同负载测量 | 原方式 | 优化后 |
| --- | ---: | ---: |
| 0.125m残土接触扫描中位数，7次/版本 | 4.342 ms | 2.318 ms |
| 上述原生SDF读取 | 12,621 | 521 |
| 0.20m接触扫描中位数，7次/版本 | 1.340 ms | 0.688 ms |
| 292份真实提案重复哈希P50 | 1.744 ms | 0.020 ms |
| 同组哈希P95 | 2.439 ms | 0.039 ms |

最终轨迹配对的提案P95为10.392→7.203 ms、P50为3.606→3.184 ms：**该配对的两侧都已启用哈希缓存，只隔离采样优化的收益**。先前仅采样优化的中间测量为11.520→8.730 ms（P95），不能把不同运行结果拼成严格的两项总收益。

日志：`output/digging-performance/proposal-hash.{stdout,stderr}.log`，其余为 `output/digging-performance/<test-name>.final.{stdout,stderr}.log`。中间采样-only日志 `lift-contact.{stdout,stderr}.log` 保留。工作区已有其他任务修改，未回退/提交。

## Human manual / 仍待确认

重启游戏加载新脚本；保持原SY135、地图、balanced画质，F9录制，执行原来的入土→装满→提斗→卸土→再次挖掘，卡顿时F10标记，F9保存。应比较两个标记附近的帧间隔、每帧physics_steps与soil_automatic_ms，而不只看平均FPS。用户操作的这份录制没有逐帧铲斗姿态，既有421帧轨迹是另一份此前保存的真实运动，不能称为本次卡顿的精确回放。

原生编辑、coverage、其他physics和状态发布仍有剩余成本。本轮修复了复现支持的重复计算，不承诺所有卡顿已消失或已经稳定60FPS。感知验收仍pending；任务保持in_progress。

## 最终验收补记

2026-09-12用户后续实机确认卡顿已修复，授权提交、推送并归档。本文此前的pending为当时状态，现已完成。
