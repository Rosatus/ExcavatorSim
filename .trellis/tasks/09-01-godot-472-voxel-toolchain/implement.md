# Godot 4.7.2 + Voxel Tools 1.7 工具链迁移实施计划

## Phase A — 锁定工具链与快速校验

- [x] 新增工具链 lock，记录 v1.7 release、Godot/Voxel/commit、四个 asset URL、zip digest、解压后二进制 digest 和默认 root。
- [x] 实现共享 resolver/validator，支持显式 root、`GODOT_VOXEL_ROOT`、默认 root 三层解析与稳定错误诊断。
- [x] 增加 resolver focused tests：正常四件套、缺文件、错 hash、错 version、错误 variant、override precedence。
- [x] 在实现说明中记录本机锁定的 binary SHA-256：
  - Windows editor `4AA32DE020EF9AEA9FD9BF5A3A22FA72BB55DB3DAC6BD1CF8AC45B775D7749C3`
  - Windows release template `21229489A7078EABF26E910044EC2DEFE19FCD49143DF6E8C545948515D98D8C`
  - Linux editor `BBEC8C1C5AF9C61B6ACBDFC85214404CA3037D0758DC567D0C4A2C68E475453F`
  - Linux release template `EB21C5D7B85D281DB68C3B315237C6E6CEACF65067C7E5C595B2B94AA3E40B7E`

## Phase B — 迁移所有活动入口

- [x] 更新 `tools/build_release_dist.ps1`、三个 Terrain3D PowerShell runner 和测试 README 的默认 engine 解析。
- [x] 更新 `backend/scripts/jolt_product_soak.py` fallback，使其读取共享 lock/resolver；保留显式 `--godot-exe` / `GODOT_EXE` 优先级。
- [x] 更新 `docs/release-candidate.md` 与相关 active specs 的当前版本/命令；不得修改 archive/journal 历史证据。
- [x] 审计 `rg "4\.7\.1|Godot_v4\.7\.1|stable_mono"`，确认剩余命中仅为历史记录或明确兼容说明。

## Phase C — 隔离注入 custom templates

- [x] 实现可复用 staging helper：复制 project、排除生成目录、在副本 preset 中写入 Windows/Linux release template 绝对路径并保持 debug 为空。
- [x] 将完整 release builder 和 Terrain3D release validation runner 接入该 helper；异常路径确保源 preset 不变且 staging 可安全清理。
- [x] 在正式 export 前验证 editor 与两个 templates 同 release/version/hash；保持现有 Terrain3D DLL/SO hash assertions。
- [x] 保持现有 Gateway 构建、manifest、Linux tar mode、atomic replacement 和 rollback 语义。

## Phase D — Module/compatibility canary 与 provenance

- [x] 新增最小 `voxel_module_smoke.gd`，只验证 engine identity、VoxelTerrain/VoxelLodTerrain/Terrain3D ClassDB 注册及瞬时实例化。
- [x] 将 source、Windows packaged、Linux packaged module canary 接入 focused release validation，避免逐场景/逐帧扩展。
- [x] 扩展 build manifest 的 toolchain provenance，记录实际 editor/templates 的来源、版本、commit 与输入哈希。
- [x] 增加 Voxel Tools LICENSE/provenance staging；保留现有 Terrain3D/Sky3D notices。

## Phase E — Agent Automated Validation

先稳定 focused checks，再按顺序执行；重型 gate 只在最终相关编辑后运行一次。

- [x] resolver 单元测试与改动脚本的静态检查。
- [x] 四件套版本/hash 校验；Linux 两个文件通过 WSL `--version`。
- [x] 新 editor 一次 headless import canary：
  `& E:\applications\godot_voxel\godot.windows.editor.x86_64.exe --headless --path .\godot\client --editor --quit`
- [x] `voxel_module_smoke.gd`、`terrain_state_test.gd` 和最邻近 Terrain3D/Jolt compatibility canary。
- [x] Godot AI MCP 只读检查：目标 session 为 4.7.2 custom，main scene ready，VoxelTerrain/VoxelLodTerrain/Terrain3D 可实例化，无新增相关 editor errors。
- [x] 最终稳定候选一次 full standalone matrix（触发原因：engine-wide/native extension/shared lifecycle 迁移）。
- [x] 最终稳定候选一次 Windows/Linux release build 与 source/export packaged smoke；校验 Terrain3D binary hashes、Voxel module、notices、manifest、Linux tar 内容/权限。
- [x] `pixi run verify`；只有跨层失败才扩大检查范围。
- [x] 明确不运行 Jolt soak、paired soak、截图矩阵或 Agent 视觉验收。

## Phase F — Human Manual Acceptance

- [ ] 关闭旧 4.7.1 editor，只保留 4.7.2 custom editor；打开 `res://scenes/main.tscn`。
- [ ] 使用 SY205、balanced、Forward+ 启动一次，短暂检查 Terrain3D 材质/地面、机械显示、相机、基础履带和工作装置控制，没有启动错误或明显视觉退化。
- [ ] 对 Windows packaged build 重复一条最短启动/控制检查；Linux 目标机只要求启动检查时可在后续发行验收完成。
- [ ] 用户确认前记录为 `pending human review`，不得以 headless 通过代替。

## Review and Rollback Gates

- [x] Review 1：lock/resolver 不允许 machine-specific path 泄漏进 tracked export preset。
- [x] Review 2：module canary 不创建 terrain/collision/soil authority，不引入 `addons/zylann.voxel`。
- [x] Review 3：release diff 保留 Terrain3D/Gateway/notices/manifest 和 atomic install 行为。
- [x] 若 editor/import 失败，停止在 Phase B；若 custom template/package smoke 失败，保留旧 dist，回滚 staging/template 接线，不触碰 runtime data。

## Automated Validation Record

- `pixi run verify`：通过（backend 185 passed；tools 16 passed、1 skipped；lint/typecheck/provenance 通过）。
- 完整 standalone matrix 已按预算执行一次；Gateway E2E 的初次失败来自裸 Python 缺少 `cantools`，在 `pixi run -e gateway` 下聚焦复跑 33/33 通过。
- `bucket_soil_tool_test.gd` 的 scrape classification 在新旧引擎均同样失败，确认是既有 4.7.1 baseline 缺陷，不属于本次迁移；其余尾部检查通过。
- 聚焦 Terrain3D release validation：`output/terrain3d_phase4/20260901-155217/run-summary.json`，editor/Windows/Linux 均通过且双平台导出包均证明 Voxel/Terrain3D ClassDB 可用。
- 最终 `tools/build_release_dist.ps1`：成功生成 Windows、Linux 与 Linux tar，双平台独立 export canary 通过；manifest 均记录四个锁定组件，tar 可执行权限为 `0755`，无 staging/backup 残留。
- Godot AI MCP：唯一活动 session `client@27d6` 为 4.7.2 custom、plugin/server 3.2.4、`main.tscn` ready；三类均 `can_instantiate=true`。仅见四条已知 demo/正式贴图 UID 重复告警。
