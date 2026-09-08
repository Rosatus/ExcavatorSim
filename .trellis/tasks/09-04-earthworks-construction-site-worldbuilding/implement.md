# Implementation Plan

## Preconditions

- [ ] 用户批准本 PRD / design / implementation summary 后再运行 `task.py start`。
- [ ] 实施前完整读取 `.trellis/spec/frontend/client-boundary.md`、`.trellis/spec/frontend/godot-mcp.md`、`.trellis/spec/frontend/validation-budget.md` 与 `docs/godot-integration.md`。
- [ ] 记录开始时 `git status`，把另一位 agent 的所有既有修改视为只读；不 stage、不格式化、不回退这些文件。
- [ ] 确认当前 `godot/client` MCP session；若仍在运行产品主场景，不对它执行任何写操作。

## Phase A — Isolated workbench foundation

- [ ] 新建 `godot/worldbuilding/earthworks_site/` 独立项目骨架、README、ignore 与目录结构。
- [ ] 编写 bootstrap：校验 custom Godot、建立 ignored Terrain3D/Godot-AI dependency junction 或 copy、同步 curated GLB、验证 SHA。
- [ ] 建立独立 Godot AI MCP session（若可用）；任何 MCP 写调用显式指定 workbench session id。
- [ ] 建立最小 Forward+ scene，验证 `Terrain3D`、`VoxelTerrain`、`VoxelMesherTransvoxel` 可实例化；Terrain3D 4.7 compatibility canary 失败则停止地编并报告，不绕过插件。

Rollback point: 删除 workbench 目录和本地 junction/cache；产品客户端应无 diff。

## Phase B — Terrain and circulation blockout

- [ ] 创建 3×3、64 m region 的 Terrain3D 独立数据集和可重复 source height maps，保留中央 region 未分配。
- [ ] 创建有限 VoxelTerrain、SDF generator、土层和边界诊断；完成一次局部 `VoxelTool` 移除 smoke。
- [ ] 搭建入口、9 m 环形主路、维护坪、材料坪、弃土区、排水沟、外围坡体和 64×64 m 中央工作区。
- [ ] 加入工程车辆尺度量规、15 m turning template、出生点与三个固定审阅相机。
- [ ] 结构性验证 Terrain/Voxel 不重叠、中央无 Terrain3D collider、Voxel 有约 12 m 有效土层。

Rollback point: terrain source maps 与 terrain_data 独立，可回到空 workbench foundation。

## Phase C — Visual language and dressing

- [ ] 完成 Terrain3D 四类基础材质、Voxel soil triplanar material、道路压实带与边缘过渡。
- [ ] 建立代理优先的模块化围挡、标桩、路缘、排水与临建组件。
- [ ] 按 catalog 同步并导入少量 hero GLB；核对 source/cache SHA、材料、bounds、单位和 orientation。
- [ ] 布置设备坪、管材区、弃土区和入口视觉锚点；避免规则网格、等距重复和全场同密度。
- [ ] 完成环境、太阳、空气透视、近中远景层次与 review camera composition。

Rollback point: hero asset subtree 与材质可独立禁用，blockout terrain 保持可运行。

## Phase D — Stable candidate and handoff

- [ ] 清理编辑器错误与缺失资源；聚合高面资产诊断，不逐实例刷日志。
- [ ] 执行一次稳定候选的 objective performance snapshot，记录 FPS、draw calls、objects、video memory 和 voxel meshing spikes；不把减面扩展进本阶段。
- [ ] 完成 README：bootstrap、打开方式、相机、诊断层、素材来源、人工验收路径和后续迁移边界。
- [ ] 运行 Agent automated checks；检查 diff 只在 workbench 与本任务目录。
- [ ] 交给用户做一次 Forward+ 人工视觉/游览验收，并把结果记录到任务。

## Agent automated validation

```powershell
# bootstrap dry-run / dependency and asset verification
& .\godot\worldbuilding\earthworks_site\tools\bootstrap_workbench.ps1 -VerifyOnly

# custom engine import and parser canary
& 'E:\applications\godot_voxel\godot.windows.editor.x86_64.exe' `
  --headless --editor --path .\godot\worldbuilding\earthworks_site --quit-after 2

# focused structural and terrain-ownership smoke
& 'E:\applications\godot_voxel\godot.windows.editor.x86_64.exe' `
  --headless --path .\godot\worldbuilding\earthworks_site `
  --script res://tests/workbench_smoke.gd

# changed-path boundary
git status --short
git diff --check
```

The exact engine path must be resolved and SHA-verified from `tools/godot_voxel_toolchain.json`; the literal above is the current expected location, not a second authority.

## Human manual validation

在最终稳定候选上只运行一次代表性 Forward+ 审阅：

1. 从入口相机确认道路导向、场站层次和安全边界；
2. 使用自由相机沿环路进入中央作业区，观察车道宽度、转弯空间、坡度和视觉遮挡；
3. 从工作面相机确认 Voxel 土层厚度、开挖面的可读性、Terrain3D 接缝和材质统一性；
4. 从总览相机确认近中远景、视觉锚点、重复感、灯光和尘雾；
5. 在诊断层开/关状态下确认 region、Voxel bounds、出生点和运输路线与最终画面一致。

## Deferred follow-up

- 原始 GLB 系统减面、LOD/HLOD、纹理图集与最终资产提交策略。
- 接入产品主场景、挖掘机控制、Jolt、土量/倾倒和存档。
- Windows/Linux 产品发行包与正式性能预算。
