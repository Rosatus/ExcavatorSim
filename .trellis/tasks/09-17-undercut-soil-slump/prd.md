# 欠削悬空土：commit 内支撑清理（检测+删除）

## 问题

深挖/侧向掏挖时，铲斗抽掉下方支撑体素后，上方土壤的 SDF 仍是实体 ——
体素地形不模拟重力，悬空土壤永久残留（坑沿悬唇、洞顶）。

## 现状事实（2026-09-17 确立）

- `overburden_cleanup` 不是通用支撑机制：仅在铲斗包络低于
  `INITIAL_SURFACE_Y - 1.5v` 时，沿铲斗内腔投影向上清到**原始地表**
  （cutter `:542`,`:405-427`）。不追当前坑面、不管坑壁/坑沿。
- 质量账本只记 bucket↔terrain 交换；**删除不进账本即守恒**
  （与 sparse_coverage_approximate 哲学一致；用户明确接受
  "多余的土壤消失，不用精准模拟"）。
- 复用件：`_issue_readiness_work`（编辑区合并 ticket）；
  `PROTECTED_SHELL_VOXELS=2`（保护壳=地板支撑）。

## 决策记录（用户拍板 2026-09-17）

用户初提 C（overburden 烟囱通天+多余土消失）。评估后确认：

- C 需拆 mass staging（否则烟囱覆盖区全部计入斗 → 斗秒满）且触发条件
  锚定初始地表（垫高区失效）、只覆盖铲斗内腔投影。
- **A' = 检测+删除**：commit 后对受影响列做支撑扫描，"底部坐空气"的
  solid 段直接置空气。覆盖 C 全部范围（斗上方柱位就在受影响区内）+
  坑沿悬挑 + 斗移走后遗留 + sy205/exact 路径；不动 cutter、不拆 staging。
- **采行 A'**；overburden 烟囱保留原样（第一道防线，减少 A' 扫描量）。

## 方案：commit 尾部支撑清理

### 语义

cut commit 的 SDF 编辑落地后，对受影响区列做底向上扫描：
列内一旦出现 `air gap → solid run`（段底体素的正下方是空气），该段
**及其上方所有实体**删除（置正 SDF）——悬空段上方的段在支撑消失后
同样悬空，级联删除。保护壳/窗底实体视为有支撑。

### 接入（两条路径同一 helper）

- exact `_commit_proposal`:`_tool.paste` + `commit_cut` 后、
  `_issue_readiness_work` 前。
- native `_commit_native_proposal`:`do_path` 编辑 + material commit 后、
  `_issue_readiness_work` 前。
- helper 内部：`copy` 有界区域（x/z = edit_area + 1 halo；y =
  edit_bottom-1 .. zone_top-shell）→ buffer 上扫描删除 → 有改动才
  `paste`；返回区域并入 readiness 的 merged_area（同一波 mesh 重建）。
- 无悬空 → 成本 = 一次小 copy + 列扫描，零写回。

### 界限与遥测

- `MAX_SUPPORT_CLEANUP_COLUMNS`、`MAX_SUPPORT_CLEANUP_SAMPLES` 上限；
  超限只处理近端列，遥测暴露 clamp。
- `VoxelCutTransaction` 新增：`support_cleanup_usec`、
  `support_deleted_samples`、`support_columns`。
- deposit 路径不跑（加土不产生悬空）。

### 不变式（测试断言）

> commit 后受影响列内不存在"段底为空气"的 solid 段；
> `conservation_error_q == 0`；斗内质量只反映切削入账。

## 执行计划（已完成 P0–P3,2026-09-17)

- **P0** ✅ `voxel_support_cleanup_test.gd`：预制洞穴（do_sphere 掏空地表
  下 4v 半径）→ 浅表切削覆盖该列 → 断言悬空顶板删除 + 守恒 0 +
  `support_deleted_samples > 0` + 受影响列无"段底为空气"的实体；
  sy135(native)/sy205(exact）双路径。先红（4 条断言失败）后绿。
- **P1+P2** ✅ `_apply_support_cleanup(edit_area)`：有界列扫描
  （x/z=edit_area±1,y=edit_bottom-2 至 zone_top-shell）→ copy→列内
  底向上扫描→`below_solid`/级联删除→有改动才 paste。exact 路径接在
  `commit_cut` 后，native 路径接在 `commit_approximate_cut` 后，
  删除区并入同一 `_issue_readiness_work`。
- **P3** ✅ `MAX_SUPPORT_CLEANUP_COLUMNS=512` /
  `MAX_SUPPORT_CLEANUP_SAMPLES=16384` clamp（超限按 edit 中心裁剪，
  余下留待后续 commit);transaction 增 `support_cleanup_usec`/
  `support_deleted_samples`/`support_columns`；测试已入
  `run_voxel_cutting_tests.ps1`。
- **回归**:15 个 voxel 测试族全绿（authority/cutting_perf/world/
  construction/dump/lift/residual/hash/queue/cutter/material-field +
  live_residual residual=0)。

## 验收证据

- `voxel_support_cleanup_test`：双路径全过——预制洞穴顶板在 commit 后
  被删除，`conservation_error_q==0`，受影响列无悬空。
- 常规挖掘 commit:`support_deleted_samples==0` 时零写回（仅一次小
  copy+扫描）；删除发生时 paste 一次并入同波 readiness。
- 已知语义边界：只按列判定（纯竖向支撑）；悬空段整体消失不落地——
  用户明确接受。横向休止角扩散与渐进坍落为可选后续（P4，未实施）。

- Blockers: 无。
- Next: 实机深挖验证视觉（悬空应即时消失）；若需"落下堆成锥"再开
  P4（DepositSurface.plan 放置端升级）。
