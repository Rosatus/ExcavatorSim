# Earthworks Site Workbench

Godot-first 独立土方工地地编。与 `godot/client` 并列隔离，不接入产品主场景、车辆控制、土量账本或 Gateway。

## 打开

在仓库根目录执行：

```powershell
& .\godot\worldbuilding\earthworks_site\tools\bootstrap_workbench.ps1 -SyncAssets
& 'E:\applications\godot_voxel\godot.windows.editor.x86_64.exe' --editor --path .\godot\worldbuilding\earthworks_site
```

bootstrap 从 `tools/godot_voxel_toolchain.json` 校验引擎 SHA，复制独立插件缓存；`-SyncAssets` 仅复制 catalog 内 4 个源 GLB，检查字节与 SHA。无源素材时保留代理。`-VerifyOnly` 只检查依赖与已有缓存。正常打开不运行地图生成工具。

**当前成果是可继续编辑的地编基线；最终构图、近景材质与游览观感等待人工验收。** Godot AI 是编辑工具：插件启用时会自动注册其调试 autoload；禁用 Godot AI 插件会移除该 autoload，地编场景脚本没有任何 MCP 调用。Terrain3D 与 Voxel Tools 是地图的必要依赖。

## 地图与操作

- 场地 `x,z = [-64,128)`，192 × 192 m；北为 `-Z`。
- 中央 `x,z = [0,64)` 由 VoxelTerrain 独占。0.25 m/voxel 是预览精度，底部 -16 m，保证至少 12 m 有效土层；北侧初始工作面约 2.8 m。
- 外围 8 个 Terrain3D region，显式禁用 world background。9 m 双向环路，15 m 中心线转弯半径。当前路网为水平基线，外缘地貌、排水沟独立起伏。
- 入口与值班房位于西南；维护坪在西侧；管材材料坪在东侧；堆料位于北侧；排水沟沿东侧外围。
- 运行后：`1` 总览、`2` 入口、`3` 工作面；按住右键 + `WASD` 飞行，`Q/E` 升降，`Shift` 加速；`F1` 尺寸、车辆量规与边界；`Esc` 释放鼠标。
- 自由相机用于审阅，不是车辆驾驶或碰撞控制器。量规表示 8×3×3.5 m 车辆和挖掘机预留体积，不宣称已通过真实车辆动力学验收。

## 编辑权威

- `scenes/earthworks_site_workbench.tscn`：布局、相机、灯光、分区布景。`HandAuthored` 是增量人工内容的预留分组；保存场景即保留位置修改。
- `terrain_data/`：Terrain3D 可编辑地形，使用 Terrain3D 编辑器雕刻/绘制并保存。中央区域禁止添加 Terrain3D region。
- `source_maps/soil_height.res`：初始体素高度图，按 `(世界高度+16)/20` 编码；生成器范围 `[-64,16]` voxel。初始地形与编辑器预览网格来自同一 profile。编辑器显示无碰撞的初始预览网格，运行时关闭它、仅显示原生 VoxelTerrain。它不反映运行时挖除结果。
- `scripts/site_profile.gd` 与 `tools/build_site.gd`：初始布局生成来源。**生成器不会在打开或运行地图时执行。** 修改 profile 不会自动覆盖现有人工地形。重新生成须显式 `--replace-generated`，会覆盖场景和生成数据，先通过 Git 保存人工修改；不要拿它当日常保存按钮。
- 可挖区最外侧 3 m 作为保护/接缝带；后续产品接入必须将该编辑边界接入权威编辑门控。当前只提供独立 smoke 挖除，不接入用户挖掘输入。
- Terrain3D 碰撞 layer 1，Voxel layer 2，正 X/Z 边缘填缝条 layer 3（bit mask 4）；查询地面使用 mask 7。体素网格止于最后一个采样点 63.75 m，硬地从 64 m 开始，两条互不重叠的 0.25 m 填缝条只覆盖缺口；编辑器预览也止于 63.75 m。层用于诊断，所有权由几何区间决定。静态堆料和施工道具是布景，不是可倾倒土体或正式车辆障碍物。

从零再生成的工具顺序（只用于重建初始布局）：

```text
Godot --headless --path <workbench> --script res://tools/build_site.gd -- --textures-only
Godot --headless --editor --path <workbench> --import
Godot --headless --path <workbench> --script res://tools/build_site.gd
```

`--sample` 仅用于空目录的一段南侧硬地与完整有限土体 canary；已有完整 terrain_data 时不要用 sample 覆盖测试。

## 资产与 Blender 需求

`asset_catalog/catalog.json` 保存来源、SHA、面数、尺度和用途。原始 GLB 保持字节不变，忽略的 `local_assets/` 可随时由 bootstrap 恢复。`asset_catalog/imports/` 保存实际导入配置，embedded images 使用 Basis Universal (`gltf/embedded_image_handling=2`)，本阶段不生成 LOD、不抽取纹理。

四类地表纹理由本项目的 FastNoiseLite 生成，无外部纹理授权依赖；它们是首轮材质基线，不是扫描级地表材质。体素使用世界空间程序化土壤着色。近景纹理品质留给人工检查。

Blender 需求记录在 `.trellis/tasks/09-04-earthworks-construction-site-worldbuilding/blender-requirements.md`。后续低面资产、自然土堆造型输出到新的派生文件，不覆盖外部原始 GLB。

## 验证

Agent automated：

```powershell
& .\godot\worldbuilding\earthworks_site\tools\bootstrap_workbench.ps1 -VerifyOnly
& 'E:\applications\godot_voxel\godot.windows.editor.x86_64.exe' --headless --path .\godot\worldbuilding\earthworks_site --script res://tests/workbench_smoke.gd
git diff --check
```

Windows 脚本中需要等待 GUI 引擎退出时使用 `Start-Process -Wait -PassThru -WindowStyle Hidden` 并读取 `ExitCode` 与日志，不能把命令启动成功当作测试通过。

Smoke 检查重新加载后的材质、region/bounds、硬地/体素碰撞互斥、接缝通行、深层 SDF、真实局部移除及代理载入。挖除只存在于测试进程内，不保存到地图。`artifacts/` 保存本机日志与诊断，Trellis research 记录稳定结果。

Human manual（pending）：在独立 workbench 运行一次，从入口沿环路观察维护坪、材料坪与工作面；切换三个相机，确认尺度、纹理、灯光、边缘接缝和施工氛围。`F1` 核对尺寸后关闭。需要精修的位置按分区记录；不要因 headless 通过而视为视觉验收通过。

后续产品迁移需要单独接入坐标、车辆支持/障碍碰撞、正式体素精度与土方循环；当前地图不自动接入产品。
