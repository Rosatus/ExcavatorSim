# Godot 4.7.2 + Voxel Tools 1.7 工具链迁移设计

## 1. Boundary

本任务只替换“用于打开、验证和导出项目的引擎工具链”。产品运行时结构不新增 Voxel 节点：

```text
Pinned upstream release metadata
              ↓
Shared toolchain resolver ──→ Windows custom editor
              │               Linux editor (WSL checks)
              └─────────────→ Windows/Linux release templates
                                      ↓
Existing isolated export + package pipeline
                                      ↓
Existing Terrain3D/Jolt/TerrainState product
```

Voxel Tools 在阶段一只是“被编入 editor/template 且可由 ClassDB 证明存在”的能力。Terrain3D 仍是现有 native presentation，TerrainState 仍是逻辑高度场权威，Jolt/派生 collider/土壤 writer 的行为不变。

## 2. Toolchain Lock and Resolution

新增一份机器无关的工具链 lock，至少包含：

- release URL、tag `v1.7`、Voxel Tools version `1.7`；
- Godot version `4.7.2.stable.custom_build.ed1daf0bf` 与 engine commit；
- 四个允许的普通 x86_64 资产文件名、官方 zip digest、解压后 binary digest；
- 默认工具链根目录 `E:/applications/godot_voxel`。

新增共享 resolver：解析优先级为显式 CLI 参数 > `GODOT_VOXEL_ROOT` > lock 中的默认根目录。resolver 返回规范化绝对路径，并提供 `resolve` 与 `verify` 两种用途。所有调用方读取这一 lock；PowerShell 不再复制版本/哈希常量，Python soak 也不再维护 4.7.1 fallback 数组。

校验分层：

1. 每次入口快速检查文件名/存在性/大小和 SHA-256。
2. Windows editor/template 直接运行 `--version`；Linux editor/template 由 WSL 运行 `--version`。
3. 只有正式发行/工具链专项验证运行四件套完整检查；日常 focused 测试只检查本次所需 executable。

不提供自动静默下载，也不提交二进制。缺失时诊断必须列出官方 asset URL、目标目录和预期 digest，用户可显式补齐；这避免构建过程中意外联网和不可审计替换。

## 3. Export Template Injection

不在跟踪的 `export_presets.cfg` 中持久化 `E:/applications/...`。发布构建和 source/export runner 复用一个 staging helper：

1. 将 `godot/client` 复制到 release staging 下的隔离 project，排除 `.godot`、cache、dist 与运行输出。
2. 在隔离副本的两个 preset 中写入 resolver 返回的绝对 `custom_template/release`；`custom_template/debug` 保持空。
3. 使用同一锁定 Windows custom editor，对隔离项目执行 Windows/Linux `--export-release`。
4. 构建成功或失败后只删除 staging；源 `project.godot`、`export_presets.cfg` 与用户编辑器状态不变。

完整构建仍由 `tools/build_release_dist.ps1` 编排。其现有 staging/原子安装/失败回滚保持不变；模板注入发生在替换正式 dist 之前。

## 4. Compatibility Canaries

新增单一、无场景依赖的 `voxel_module_smoke.gd`：

- 断言 engine version 匹配 lock 的 Godot/commit；
- 断言 `ClassDB.class_exists("VoxelTerrain")` 与 `VoxelLodTerrain`；
- 通过 ClassDB 实例化后立即释放，不创建 terrain、viewer、stream、collision 或 generator；
- 同时断言 `Terrain3D` 可用，证明 module 与现有 GDExtension 在当前组合下共存。

该脚本在 source editor、Windows packaged exe、WSL Linux packaged exe 各运行一次。它验证 module 被编进 template，而不暗示 Voxel 已接入产品。

现有 Terrain3D export smoke 继续负责 native presentation、fallback/recovery、Terrain3D binary 和 authority parity。只扩展 runner 的引擎/template provenance，不把 Terrain3D 契约重写成 Voxel 契约。

## 5. Provenance and Licensing

工具链 lock 是构建输入证据；package manifest 增加 `build_toolchain` 段，记录实际使用的 editor/template 名称、版本、SHA-256、release URL/tag/engine commit。manifest 的 artifact file list 与 Git dirty-tree 语义保持不变。

在 `THIRD_PARTY` 中加入 Voxel Tools 的 LICENSE 和 ExcavatorSim provenance 说明。Terrain3D/Sky3D notices 原样保留。

## 6. Compatibility and Rollback

- `project.godot` 继续声明 feature `4.7`，不写 `Voxel` plugin；module 类来自 custom engine，不需要 editor plugin entry。
- 不添加 `addons/zylann.voxel`，避免 module/GDExtension 类冲突。
- 旧 4.7.1 可执行文件不删除；回滚为恢复旧入口默认值并停止注入 custom templates。
- 因没有 Voxel runtime data，回滚不涉及 terrain/soil/save 数据迁移。
- 两个编辑器不得同时作为活动开发实例；迁移验收前关闭旧 4.7.1 会话，避免 import/save 与 MCP 指向混乱。

## 7. Main Risks

- Terrain3D 1.0.2 GDExtension 与 4.7.2 custom engine 的 ABI/RenderingServer 行为差异；通过 focused editor/import、Terrain3D smoke 和一次 final matrix 捕获。
- 上游仅提供 release template；debug export 不在阶段一内，不能伪造。
- Windows custom editor 没有 Mono/console 变体；项目无 C#，并以 headless exit code/日志替代对 console wrapper 名称的依赖。
- Linux template 由 Windows editor 导出但在 WSL 执行；resolver 必须分别处理 Windows path 与 `wslpath`，并在执行前保证 Linux 文件可执行。
- manifest 若只记录最终 exe，无法证明输入 template 来源；通过独立 `build_toolchain` provenance 补足。

