# 最新用户抓取：21:24:37，仍卡顿的后续修复

## 证据与原因

输入：`capture-2026-09-12T21-24-37-29094258.json`，位于用户 Godot performance-captures 目录。Windows / Forward+ / SY135 / balanced / 1920x1080，轻量计时、无完整诊断。cutter和authority的源码哈希与本轮开始时文件相符，确认上一轮采样修复已加载。录制器此前不记录proposal文件哈希，本轮补入。

493个有效驾驶帧，平均42.4 FPS，P95 62.747 ms、P99 173.315 ms、最大180.529 ms。21帧超过100 ms，其中18帧包含8个physics step。5.083、5.605、6.105秒三个人工卡顿标记。最慢帧4.566秒：土体107.691 ms、提案78.718 ms、step23.774 ms、发布5.199 ms，GPU1.381 ms。队列/待就绪4Hz峰值各1。分析报告：`output/digging-performance/capture-212437.analysis.md`、同名JSON。

上一轮减少了同一对象重复校验的哈希开销，但入队复制/合并会创建新对象、重新逐点文本格式化。使用已保存的421帧真实铲斗轨迹，在当前源码上拆分submit/cutter/contact/geometry/queue/clone：292次接受提案的submit中位数8.7025 ms，queue2.1155 ms，clone1.9995 ms，contact3.039 ms；geometry仅0.6495 ms。主要剩余热点是新对象哈希构造和逐点接触回调。该轨迹来自此前残土复现，不是本次JSON的逐姿态回放，后者没有姿态数据。

## 修改

- `VoxelCutProposal`内部schema升为v2。以固定顺序的字段/数组、原生packed点和半径，通过`var_to_bytes`和SHA-256计算身份。保留深快照缓存和篡改校验；输入字典顺序不能改变身份。原生packed数组直接复制，避免逐元素重建。新哈希与历史v1文本哈希不同，但几何和账本不变；此类提案仅存在于当前generation内，不是外部持久重放协议。
- `VoxelBucketCutter`残土检测保留前8个标量探针的快速命中，其余按原逻辑生成并舍入、去重，交给批量回调。`VoxelExcavationAuthority`一次复制包含halo的有界SDF窗口，在buffer读取指定点；不可整体编辑或超过MAX_STAGED_SAMPLES则退回逐点有效性判断。buffer仅复用分配，每次重新copy，clear时释放。
- 录制metadata补充`voxel_cut_proposal.gd`源码哈希，避免以后无法核对该热点版本。
- 不改physics步数上限、挖掘频率、几何密度、容量、overflow、卸土和画质。

## Agent automated

同引擎Godot4.7.2 / VoxelTools1.7，目标headless测试8项全部exit0：proposal_hash、lift_contact_performance、bucket_cutter、continuous_lift、live_residual、cutting_performance、cut_queue_order、performance_capture。日志 `output/digging-performance/<test-name>.round2.{stdout,stderr}.log`。录制测试故意向文件下创建目录，有预期ERROR；其余stderr为空。scoped diff-check通过。

- 新哈希测试：嵌套变更、packed点/半径、身份字段、伪造hash、还原geometry、独立复制；字典反向插入顺序、普通Array转packed、六位小数以下的真实变化。
- 采样：0.125/0.20m；深度-0.01/-0.75/-2/-4.5、旋转-70/25/70，验证batch与scalar收集的完整整数探针集合完全相等；清空、重新加土、不可用窗口回退、有效点与无效点混合，读取刷新正确。
- 421帧真实轨迹，新旧scalar/batch的准入/episode/完整proposal几何和v2身份完全一致；292次准入，真实回放161次revision，已知残土点0残留、外部地面保持、质量守恒。
- 连续提斗115/120个历史覆盖点均无残留；原coverage/诊断/轻量计时几何账本与顺序回归通过。

## 性能测量和限制

本轮开始源码快照与profile数据保存在`output/digging-performance/baseline-212437/`。临时分段复现脚本`proposal_profile.gd`及JSON保留。

相同421帧轨迹、同机同引擎的分阶段顺序运行（并非同进程交替全版本A/B）：

| 接受提案阶段 | 本轮前P50/P95(ms) | 修复后P50/P95(ms) |
| --- | --- | --- |
| submit_pose（含生成与入队） | 8.703 / 11.456 | 2.646 / 3.622 |
| cutter | 5.993 / 7.716 | 2.268 / 3.187 |
| 入队 | 2.116 / 4.471 | 0.217 / 0.457 |
| 残土接触 | 3.039 / 4.280 | 1.199 / 1.883 |

因此submit中位数约降70%，只能称相同离线负载的阶段测量，不能称用户已恢复60FPS。

独立同进程交替7次配对：0.125m清空接触场景，上一轮逐点缓存2.569 ms→批量1.055 ms；0.20m0.820→0.375 ms。完整轨迹scalar旧回调与batch的提案P95 8.943→3.610 ms，两侧均采用新v2哈希，因此这项只隔离采样差异。当前hash测试的uncached/cache对照也是v2，不能再标注为v1文本哈希收益。`cutting_performance`的PAIRED_COMMITS仍比较前期coverage去重，不能归为本轮收益。

## Human manual / Next

重启游戏，保持原机型/地点/画质，F12录制，执行原来挖掘→装满→提斗→卸土→再次挖掘，卡顿F10，F12保存。检查慢帧和8步物理追赶是否减轻。同步coverage/native编辑与其他physics仍有成本，本轮不声称消除了全部卡顿。任务保持in_progress、未提交，等待真实驾驶复测。

## 最终验收补记

2026-09-12用户后续实机确认卡顿已修复，授权提交、推送并归档。本文此前的pending为当时状态，现已完成。
