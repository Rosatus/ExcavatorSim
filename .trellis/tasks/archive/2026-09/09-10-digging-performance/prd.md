# 挖掘掉帧诊断与优化

## 完成与验收（2026-09-12）

用户实机复测明确确认“真的修复了”，并授权提交、推送、归档。Human manual验收通过。此前pending/Next内容为各轮历史检查点，不再表示未完成。最终交付包含性能录制（F12开始/停止，F10标记）、离线分析器、coverage去重、二进制提案身份、批量残土采样及回归测试。

提交按任务拆分了与地图功能混合的文件，只将性能部分暂存；不引入未提交地图layout/菜单重构。以Git index导出的独立项目运行contact/performance轨迹和operator_ui测试均PASS/exit0。导入有第三方demo MTL缺失和退出资源日志；UI测试有此前已确认的native teardown日志；未扩展无关修复。隔离结果：`output/digging-performance/index-*.log`。复用前轮8项检查及用户感知验收，无额外全矩阵。

## 历史进展（2026-09-12）

21:24:37用户复测仍有180.5ms慢帧。已完成第二轮：新建/合并提案改用内部v2二进制SHA-256、残土剩余探针批量读取，并补录proposal源码哈希。8项聚焦回归通过；相同421帧离线负载submit中位数8.703→2.646ms（顺序运行，非实机FPS）。完整证据和限制见 [21:24:37后续诊断](./capture-212437-followup.md)。Next：用户重启后F12再次录制原动作；human流畅度验收仍pending，未提交。

快捷键后续修正：用户报告F9令Godot画面停止，录制开始/停止已改为F12（F8已有重新开始作业用途）。菜单、录制徽标、操作说明、UI规范与测试同步。`operator_ui_test.gd` PASS/exit 0，日志 `output/digging-performance/capture-f12.*.log`；有场景owner及弃用API警告，无ERROR。下一次实机复测使用F12开始/停止，F10标记。

已收到真实用户抓取，定位到土体提案CPU开销和8步物理追赶；实施每提案纯SDF接触采样去重与保持原SHA-256格式的提案哈希复用。7项聚焦检查通过，真实轨迹421帧结果等价；接触扫描中位数4.342→2.318 ms，重复哈希1.744→0.020 ms。完整证据、对照范围与限制见 [本轮诊断](./capture-2026-09-12-diagnosis.md)。Next：用户重启游戏后相同动作重新录制，确认感知改善；未提交，human review仍pending。

## 目标与范围
诊断当前 Godot 体素挖掘过程的同步计算和更新热点，通过可复现的基线与优化后测量减少卡顿。不改变挖掘几何、质量守恒、容量溢出、重复切割、卸土和碰撞就绪契约。保留工作区已有修改。用户确认两机型均掉帧，但未来以 SY135 为主要维护对象，SY205 默认不安排专项维护；该原则已写入 frontend/index.md。

## 计划
1. 读取当前切割链路，运行聚焦性能基线，定位主要耗时。
2. 主代理实施有证据支持的局部优化，保留等价性回归。
3. 对比耗时并验证受影响行为，记录剩余瓶颈。
4. 用户追加：提供可开关的性能录制功能，由用户复现后交 JSON 文件分析帧耗时与挖掘瓶颈；实现菜单/F9录制、F10标记、限时存储及离线分析。

## 验收
### Agent automated
- 给出代码和测量支持的原因，明确测试场景与局限。
- 优化前后同一负载对比；几何、账本、顺序和生命周期行为保持一致。
- 通过受影响模块的聚焦测试，未运行的检查不得声明通过。
### Human manual
- 在实际使用的机型和原掉帧地点连续挖掘、装满、卸土并再次挖掘，确认卡顿是否缓解（2026-09-12用户确认修复，验收通过）。

## Progress
- 已建立任务；工作区存在大量其他任务未提交修改，不纳入本任务。
- 当前产品为 voxel-only；本轮聚焦 SY135 native path。SY205 staged SDF 扫描是代码级候选热点，未测量/未修改，不宣称解决其掉帧。
- 已优化 `_native_coverage_coordinates`：严格几何候选已经插入 coverage 后，后续相同坐标直接跳过重复的边界、距离及排序键计算。缓存仅属于当前调用，不复用旧 SDF；原先严格包含判定失败的坐标仍可由其他路径纳入。
- 同进程交替运行优化前后版本，各 5 次真实 SY135 合并切割：覆盖采样中位数 **8009 → 3868 μs (-51.7%)**，完整切割中位数 **16225 → 12023 μs (-25.9%)**。两版几何摘要、质量、顺序、队列结果完全一致。测试为 headless、开启诊断，不代表渲染 FPS 或全游戏帧时。
- 自动检查：`voxel_cutting_performance_test.gd` PASS（0.125/0.20 m；重复、变半径、零长度、边界、上限、SDF刷新、diagnostics开关及配对真实事务）；`voxel_residual_recut_test.gd` PASS / exit 0（含满斗和残留重复切割）；scoped `git diff --check` PASS。
- 日志：`output/digging-performance/final.stdout.log`、`final.stderr.log`（空）；`recut.stdout.log`、`recut.stderr.log`（空）。引擎：锁定的 Godot 4.7.2 / Voxel Tools 1.7。
- 剩余：native edit 仍约 4.7 ms，渲染/物理及异步 mesh/collision 工作未计入上述 CPU 切割计时。全区 viewer 是待测假设，不为未经证实的收益改变碰撞覆盖契约。
- Next: 用户在原掉帧位置用 SY135 连续挖掘、装满、卸土、再挖；若仍有明显卡顿，采集实际场景帧时及 native/mesh/collision 阶段，决定下一轮优化。实际流畅度待验收，任务保持 in_progress，不归档。代码未提交。

### 用户性能录制组件（2026-09-10）
- 已实现 `performance_capture.gd`、主场景 root observer、高级工具按钮，F9 开始/停止、F10 标记、仅录制时显示徽标。最多 180 秒墙钟 / 60000 帧，停止或正常场景退出保存 `user://performance-captures/capture-*.json`；失败保留数据供重试。
- 逐帧 numeric rows：墙钟帧间隔、engine process/单步 physics、主视口 CPU/GPU 渲染、渲染准备、draw calls、primitive、内存、暂停/焦点、土体总计/提案/step/发布订阅者，以及嵌套提交分阶段耗时。所有 physics step 在下一行累计，不仅保存最后一次事务；未成行尾部另存。
- 4 Hz 记录机型/代次/版本、队列、就绪工作数、Voxel Tools 统计、质量档位/分辨率/测试开关；起始元数据包括引擎、CPU/GPU、帧率/VSync 和源码摘要。默认关闭无轮询；录制期间不做逐帧文件写入/JSON/排序。
- 独立核验后的修正：单独 `performance_timing_enabled` 只启用轻量时钟，不打开完整诊断/SDF digest；原完整诊断状态保持并在报告中显著标记。窗口焦点 enter/exit 通知排除跨帧失焦，第一不完整帧、暂停与失焦帧不进入驾驶摘要。180 秒明确包括菜单时间；零驾驶帧会在UI和报告提示。
- 分析工具：`tools/analyze_performance_capture.py`（Python 标准库，Markdown 和可选 JSON），报告分位数、慢帧、标记前后窗口、土体/渲染/采集开销相关性；不会把相关性当因果、不会把 GPU 不可用当零成本。用法见 `docs/performance-capture.md`。
- 验证：`performance_capture_test.gd` PASS/exit 0（停止/重入/限时/暂停/短暂焦点切换/所有physics累加/4Hz/失败重试/退出保存/诊断保留）；故意在文件下创建目录的失败测试有预期 ERROR 日志。`operator_ui_test.gd` PASS/exit 0（真实帧与土体hook、F9/F10、菜单、reset期间续录、停止关闭时钟）；存在已知 native teardown 日志 `!is_inside_world` / `!is_inside_tree`，在不启用录制、仅相同4次physics等待的旧UI测试对照中也复现，未扩展修复。日志 `output/digging-performance/{performance_capture_test,operator_ui_test}.final.*.log` 与 `capture-ui-baseline.*.log`。
- `voxel_cutting_performance_test.gd` PASS/exit 0：新增真实 timing-only vs disabled SDF/账本/队列等价，证实开启录制时原生诊断摘要调用次数为0；日志 `capture-timing.*.log`。Python 分析测试与 scoped Ruff 已通过；实际 UI 生成 JSON 已经被分析脚本成功读取。
- Next：用户重启游戏后在 SY135 上 F9，空闲约10秒→挖掘/装满/卸土/再挖，卡顿按 F10，F9保存；从高级工具打开目录交付 JSON。正常 Forward+ GPU计时、真实帧率与入口可用性等待用户测试；没有做Agent游戏画面验收。收到文件后用分析工具定位剩余瓶颈，任务继续 in_progress。
