# Construction 地图工程

新地图独立维护在此处，原 `earthworks_site` 保留。主项目只保存地图选择与加载逻辑；本目录的模型、贴图和地形不进入精简版。

## 编辑

先在仓库根目录运行 `godot/worldbuilding/construction/tools/bootstrap.ps1`，再用项目固定的 Godot Voxel 4.7.2 编辑器打开此目录的 `project.godot`。

- `maps/construction/Construction-Site.tscn`：迁移后的布景，所有地图资源位于 `res://maps/construction/`。
- `maps/construction/Ground.tscn` 与 `terrain_data/`：可编辑 Terrain3D。沿用源工程临时地面的水平标高 -0.02 m，范围约 566 × 692 m；源工程没有提供可恢复的 Landscape 高度图。地图外缘使用地形洞，关闭无限背景。
- `maps/construction/WorldEnvironment.tscn`：Sky3D 预览天空。运行产品时使用主项目已有 Sky3D，避免叠加两套环境和太阳光。
- `preview.tscn`：独立地图预览。右键 + WASD 飞行，Q/E 升降，Shift 加速，Esc 释放鼠标。
- 大地图的地面警戒线内已接入 Voxel Tools 真实挖土、装斗、卸土；训练场继续使用自己的独立体素土区。
- `maps/construction/WorkArea.tscn`：出生点与挖掘区。出生点取自用户运行时位置 X=38.301582、Z=31.119902，朝向由 179.847° 校准为 180°（前向 +Z）；Marker 的 Y=-0.02 是地面标高，底盘会按物理描述自动抬高。土区 18×28 米，中心 X=38.301582、Z=53.5，近边 Z=39.5，仅保留四边地面黄线，没有短桩。内部初始地形为半幅基坑：靠近出生点一侧（本地 -Z）已挖成约 1.5 米深的坑——全宽坡道供机械上下（约 21°，唯一非陡坡），两侧边坡和中线工作面均为陡坎断面，坑底约 8 米平地可平放一台机械；远侧半幅保持原标高作为待挖区。坑深由 `metadata/starter_pit_depth_m` 配置（0 为平地）；周边 1.5 米为稳定保护边缘，其余区域可以继续挖掘和堆土。重置恢复初始坑形与空斗。
- 土体由主项目的 `VoxelWorkZone` 创建。独立地图工作台仍显示完整硬地面；只有支持挖掘的主项目启动时才开启 Terrain3D 洞，避免预览工程出现没有土体填补的洞。

地形在编辑器内保存即可。`tools/build_ground.gd` 只用于首次生成；`--replace-generated` 会重建并覆盖地形数据，不是日常更新命令。

## 构建与分发

在仓库根目录执行：

```powershell
# 导入并生成地图包
./tools/build_construction_pack.ps1

# 精简版（原有 Gateway/双平台构建前提仍适用）
./tools/build_release_dist.ps1

# 包含大地图的版本
./tools/build_release_dist.ps1 -IncludeConstructionMap
```

地图包输出为 `godot/dist/maps/construction.pck`。编辑器运行主项目时从此处读取；导出程序从可执行文件旁的 `maps/construction.pck` 读取。完整分发是基础程序加此文件，精简分发省略此文件。不需要维护两套主场景或复制一份客户端。

构建器通过 `tools/prepare_construction_textures.py` 在导入前后落实贴图预算：未设置尺寸上限的贴图（包括 GLB 自动提取图片）默认 1024，道路贴花最多 1024，其他已有显式上限保留。保留原始图片，只缩小导入产物。贴花会进入共享渲染图集，几张 8K 图片即使各自有效，合并后也可能超过设备尺寸上限。`-SkipImport` 会拒绝不符合预算的 sidecar；改变导入设置后必须完整重建。

Esc 菜单中，机型选择下方是地图选择。缺包时显示“未安装”；切换需要确认，重新开始作业并保留机型。启动参数 `-- --without-map-packs` 可用于验证缺包行为。地图源资源没有放进 `godot/client`，客户端的 `all_resources` 导出不会把这些大文件自动打进去。

打包器只收录 `res://maps/construction/` 及其导入缓存，不包含 `project.godot`、插件、全局脚本类缓存或客户端脚本。它依赖主程序已有的 Terrain3D 1.0.2、Sky3D 和同版本 Godot 导入格式。Windows/Linux 桌面共用 S3TC/BPTC 纹理包；移动平台需单独构建纹理格式。

源场景超过两万个静态碰撞体，两个工程的 Jolt `max_bodies` 均配置为 32768。主程序履带使用地图静态碰撞或已就绪的 Voxel 土体碰撞作为支撑，禁用训练场硬地面；地图切换时 CAN 连接保留，帧引用重新绑定。

## 版本管理与来源

仓库 `.gitattributes` 对本目录下 `.png`、`.glb`、`.res` 设置了 Git LFS。`.tscn`、`.tres`、脚本与源资产 `.import` 设置保留文本差异；`.godot`、插件副本与构建输出不提交。GLB 导入时生成的 434 张内嵌图片及其 sidecar（约 1.89 GB）同样忽略，可由 GLB 再次导入生成，PCK 仍收录其运行时依赖。Git LFS 管约 8.17 GB 的源资产，PCK 管约 2.55 GB 的成品分发；没有改写历史或创建额外 Git 仓库。

`source_manifest.json` 记录从 `E:/projects/unreal/construction` 复制的源路径、字节数和 SHA-256。该导出没有附上游资产许可证，manifest 不代表新的授权声明。原始目录未改动，复制的二进制网格已通过 Godot 重存，修正其内部材质路径。迁移工具为根目录 `tools/import_construction_map.py` 与本目录 `tools/relocate_binary_resources.gd`；不要重新迁移覆盖后续人工编辑。

## 检查

`tools/audit_dependencies.gd` 检查场景/资源的缺失依赖。主项目 `tests/map_switch_test.gd` 验证缺包、切换、机型保持、静态地面驾驶与训练场恢复；`tests/construction_pack_test.gd` 验证实际 PCK 的地形、碰撞及 SY135 驾驶。记录在仓库 `artifacts/construction-map/`。

固定编辑器的 headless import 在退出时会报告少量已知资源/RID 未释放。构建器保留这些日志并提示，但资源加载错误、脚本错误和打包错误仍会中止构建。画面、材质与实际操控体验需要人工在 Forward+ 中确认，自动碰撞检查不代替该验收。

2026-09-12 贴图修复后，地图包为 714,119,788 字节（旧版 2,551,209,156）。同机 RX 9070 XT、D3D12/Forward+ 的自动渲染测试首帧约 4.3–5.0 秒，场景加载约 4.0–4.7 秒；这是已有缓存、直接进入大地图的测试，不是重启系统后的冷启动或编辑器菜单切换保证。`construction_pack_test.gd` 非 headless 运行时会验证绘制计数，并输出实际渲染资源占用。画质仍需在 Esc 菜单进入地图后人工检查。
