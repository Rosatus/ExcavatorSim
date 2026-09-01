# 迁移 Godot 4.7.2 与 Voxel Tools 1.7 工具链

## Goal

将 ExcavatorSim 的日常 Godot 开发、自动验证和 Windows/Linux 正式发行链路，从 Godot 4.7.1 official Mono 迁移到上游 `godot_voxel` v1.7 提供的 Godot 4.7.2 stable custom build（engine commit `ed1daf0bf`，Voxel Tools 1.7）。迁移后项目应能可靠识别 Voxel Tools 模块并使用同系 custom release templates 导出，同时保持现有 Terrain3D、Jolt、Gateway、地形/土壤权威及产品行为不变，为后续独立的 Voxel 地形接入阶段建立可信基线。

## Background and Confirmed Facts

- 已通过 Godot AI MCP 确认 `E:/applications/godot_voxel/godot.windows.editor.x86_64.exe` 报告 `4.7.2-stable (custom_build)`，`VoxelTerrain`、`VoxelLodTerrain` 和现有 `Terrain3D` 均已注册且可实例化。
- 本机 `E:/applications/godot_voxel/` 已具备 Windows/Linux x86_64 普通 editor 与 release template 四件套；四个二进制均报告 `4.7.2.stable.custom_build.ed1daf0bf`。
- 项目无 `.cs`、`.csproj` 或 `.sln`，不依赖 Mono/.NET；当前产品仍使用 Forward+、D3D12、Jolt、Terrain3D 1.0.2 与 `jolt_authoritative`。
- `tools/build_release_dist.ps1`、三个 Terrain3D 验证启动器、`backend/scripts/jolt_product_soak.py` 及发行文档仍引用 4.7.1 Mono。
- `godot/client/export_presets.cfg` 的 Windows/Linux `custom_template/release` 当前为空；若将来场景使用模块类，vanilla template 无法承载 Voxel Tools module。
- 当前存在四条 Terrain3D demo/正式贴图 UID 重复警告，但没有 Voxel Tools、脚本解析或 Terrain3D 加载错误；该既有告警不属于本任务。

## Requirements

### R1 — 锁定并解析同一套工具链

- 在仓库中记录 Godot 4.7.2、Voxel Tools 1.7、上游 release/tag/engine commit、四个官方资产名称、下载 URL、压缩包 SHA-256 和本机解压后二进制 SHA-256。
- 不把约 490 MiB 的 editor/template 二进制提交到 Git；工具链根目录解析顺序必须明确、可覆盖，并以当前 `E:/applications/godot_voxel` 为默认值。
- 构建与验证在启动 Godot 前必须校验所需文件存在、普通版本而非 `double`/`tracy`、实际 `--version` 与锁定版本一致；哈希不符时快速失败并给出稳定诊断。
- Windows 构建器、PowerShell 验证脚本和 Python soak fallback 必须复用同一份锁定元数据，不能各自维护漂移的版本字符串。

### R2 — 迁移开发和测试入口

- 将当前会实际默认选择 4.7.1 Mono 的脚本迁移到 4.7.2 Voxel Tools 普通 editor；继续允许显式 `-GodotExe`、`--godot-exe` 或环境变量覆盖。
- 更新当前可执行命令文档，保留归档任务和历史 journal 的 4.7.1 证据原文。
- 保持 `godot/client/project.godot` 的 `4.7`、Forward+、D3D12、Jolt、Terrain3D plugin 和 authority 设置；不得仅为版本迁移重写场景或资源。

### R3 — 使用同系 custom release templates 导出

- Windows 使用 `godot.windows.template_release.x86_64.exe`，Linux 使用 `godot.linuxbsd.template_release.x86_64`；两者必须来自同一个 v1.7 release。
- 仅配置/注入 release template；上游未提供普通 debug template，因此 `custom_template/debug` 保持为空，不得用 release template 冒充 debug template。
- 构建时通过隔离的临时 Godot project/export preset 注入已解析的绝对 template 路径，源树中的用户 export preset 不得被临时改写或因构建中断遗留机器专属绝对路径。
- 继续由 `tools/build_release_dist.ps1` 作为唯一完整双平台发行入口，保留 Gateway 重建、staging/原子替换、Terrain3D DLL/SO 哈希核验、manifest 和 Linux tar 权限规范化。

### R4 — 证明 Voxel module 与现有运行时并存

- 增加一个最小 headless module canary，只验证锁定版本下 `VoxelTerrain`/`VoxelLodTerrain` 的 ClassDB 注册与可实例化，不向主场景添加节点、不写入 voxel 数据。
- source project、Windows export 和 Linux export 都必须通过 module canary；成功导出但使用 vanilla template、模块缺失或版本错配必须被检测为失败。
- 保留并验证 Terrain3D GDExtension 加载、现有 Terrain3D fail-open presentation、Jolt 物理和 TerrainState 权威边界；Voxel module 的存在不得成为第二个 terrain/collision/soil writer。

### R5 — 发行 provenance 与第三方通知

- 在发行包第三方通知中加入 Voxel Tools 的许可证和版本/来源说明；不得依赖“模块已编进 exe”而省略通知。
- Windows/Linux package manifest 继续记录最终产物字节哈希；另记录构建所用 editor/template 的 version、engine commit、Voxel Tools version 与输入 SHA-256，使产物能够追溯到上游工具链。
- 正式发行仍要求干净工作树；开发构建允许进行但必须保留 `git_tree_dirty=true`。

## Acceptance Criteria

- [x] AC1：共享工具链检查报告四个普通 x86_64 二进制均存在，版本为 `4.7.2.stable.custom_build.ed1daf0bf`，解压后二进制 SHA-256 与锁文件一致；任一缺失、错版、`double`/`tracy` 或哈希错误都会在启动 Godot 前失败。
- [x] AC2：所有当前活动的 4.7.1 Mono 默认启动路径已迁移；历史 journal 和归档任务未被改写；项目没有新增 Mono/C# 依赖。
- [x] AC3：Godot AI MCP 或等价 ClassDB canary 在新 editor 中确认 `VoxelTerrain`、`VoxelLodTerrain`、`Terrain3D` 可实例化，主场景保持 `ready`，无新增 Voxel/Terrain3D/脚本加载错误。
- [x] AC4：Windows 与 Linux release export 均使用各自锁定的 v1.7 custom template；source/export module canary 全部通过，且 debug template 字段仍为空。
- [x] AC5：现有 Terrain3D Windows DLL/Linux SO 原始字节哈希校验继续通过；一条 focused TerrainState/Terrain3D/Jolt 兼容验证证明 authority、fallback 与 collision 边界未改变。
- [x] AC6：稳定候选上仅执行一次完整 standalone matrix；发生缺陷后只重跑直接受影响的 focused gate，符合 validation budget。
- [x] AC7：统一发行构建生成 Windows 目录、Linux 目录及 Linux tar；Gateway、notices、Voxel provenance、Terrain3D binaries、权限与 build manifests 齐全，Windows/WSL packaged headless canary 通过。
- [ ] AC8：一次人工代表性检查（SY205、balanced、Forward+）确认新 editor 和至少 Windows packaged build 的地形材质、机械显示、基本控制与启动行为没有可见退化；完成前标记 `pending human review`。
- [x] AC9：回滚不依赖地形数据迁移：恢复旧工具链入口/模板配置即可重新使用 4.7.1 基线，TerrainState、Terrain3D、Jolt 和土壤状态格式没有发生变化。

## Out of Scope

- 向主场景添加 `VoxelTerrain`/`VoxelLodTerrain`，生成或编辑 voxel 数据。
- 用 Voxel Tools 替换 Terrain3D、TerrainRenderer、TerrainCollider 或 TerrainState。
- 修改挖掘、切削、载荷、土量账本、Jolt 支撑/阻挡、碰撞层或权威协议。
- 安装 Voxel Tools GDExtension；module 与同名 GDExtension 不得并存。
- `double` 大世界、Tracy profiler、Mono/.NET、自编译 Godot 或 custom debug templates。
- 修复 Terrain3D demo 贴图 UID 重复告警、视觉重制、性能 soak 或发行截图矩阵。

## Deferred Items

- Voxel 地形 presentation/collision/soil adapter 的架构、数据迁移与性能评估属于后续阶段二 Trellis 任务。
- 如果未来必须支持 debug export、非 x86_64 或其他平台，再单独获得/构建与 v1.7 同源的模板。
