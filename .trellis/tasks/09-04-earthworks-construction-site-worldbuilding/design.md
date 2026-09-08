# Technical Design

## 1. Isolation boundary

新建独立项目根：

```text
godot/worldbuilding/earthworks_site/
├─ project.godot
├─ README.md
├─ .gitignore
├─ scenes/
│  ├─ earthworks_site_workbench.tscn
│  └─ components/
├─ scripts/
├─ materials/
├─ terrain_data/
├─ source_maps/
├─ asset_catalog/
├─ local_assets/              # ignored; bootstrap copies unchanged GLB here
├─ addons/                    # ignored local dependency junction/copy
├─ tests/
└─ tools/
```

这是仓库内的第二个 Godot project，不位于 `godot/client/res://` 下，因此主客户端编辑器不会扫描、导入或热重载其场景和大型 GLB。它使用同一个锁定的 custom Godot executable，但拥有自己的 `.godot` import cache。验收前不向 `godot/client` 添加引用。

`tools/bootstrap_workbench.ps1` 负责：

1. 从 `tools/godot_voxel_toolchain.json` 解析并校验 Windows editor；
2. 将 `godot/client/addons/terrain_3d` 和可选 `godot/client/addons/godot_ai` 以本地 junction（默认）或 copy 模式提供到 workbench 的 ignored `addons/`；
3. 根据 curated asset catalog 把指定 GLB 原样复制到 ignored `local_assets/`；
4. 验证 SHA、文件大小和必需插件文件；
5. 不写 `godot/client/project.godot` 或产品场景。

当前连接的 `client@7994` 会话正在播放 `res://scenes/main.tscn`，实施时不得对该会话执行 scene open/save。若使用 Godot AI MCP，将启动 workbench 的第二个 editor/session 并明确指定其 `session_id`。

## 2. Terrain architecture

### 2.1 Hard terrain

- Terrain3D 使用自己的 `terrain_data/`、`terrain_assets.tres` 和 `terrain_material.tres`，不共享产品 terrain data。
- 首轮采用 `region_size = 64`、`vertex_spacing = 1 m`，构成约 `192 m × 192 m` 的 3×3 region 场地。
- 中央完整 64 m × 64 m region 不分配给 Terrain3D；外围 8 个 region 承担硬地表。这样中央区在 Terrain3D 侧天然无可见面、无碰撞，不依赖像素级 hole mask 与 VoxelTerrain 对齐。
- 外围地貌由 source height map/可重复生成的 tool 脚本形成：南侧入口缓坡、东西设备坪、北侧堆料高地、边缘排水坡和背景土坡。道路最大常规纵坡目标 8%，短坡不超过 12%。

### 2.2 Editable earth cell

- 中央 region 由一个有限、恒定 LOD 的 `VoxelTerrain` 独占；不使用 `VoxelLodTerrain`，因为可挖区近距离、有限且需要全分辨率编辑。
- 世界尺寸约 `64 m × 20 m × 64 m`，其中有效土层约 12 m；建议统一 scale 0.25 m/voxel，对应 256×80×256 voxel bounds，并向 16-voxel data block 对齐。
- 使用 SDF + `VoxelMesherTransvoxel`、`mesh_block_size = 16`、有限 bounds、一个 visuals+collision viewer。首轮生成器提供南侧平整接近区、北侧 2–3 m 高工作面和轻微非周期起伏。
- Terrain3D 与 VoxelTerrain 使用不同诊断 collision layer；审阅相机/后续车辆可同时 mask 两层。中央缺 region 保证两者几何所有权不重叠，collision layer 只用于诊断，不作为掩盖重叠的手段。
- 边缘坐标对齐 region grid。0.5–1.5 m 的工程化过渡带、排水沟、土埂和安全边界遮蔽不同 mesher 的法线/材质接缝；过渡几何只占一侧，不建立双层行驶平面。

## 3. Site plan

```text
北
┌─────────────────────────────────────────────┐
│ 背景土坡 / 弃土堆      北侧高工作面       管材堆场 │
│          ┌────── Voxel 64×64 ──────┐      │
│ 维护坪   │ 可切工作面 / 作业平台 / 退让区 │  材料坪 │
│/油料区   │        南侧进入口            │/排水沟  │
│          └─────────────────────────┘      │
│ 入口管制 ─── 9 m 环形运输路 ─── 车辆等候/回转坪 │
└─────────────────────────────────────────────┘
南
```

- 主入口置于西南/南侧，出生和自由观察相机起点在硬地表上。
- 9 m 主运输道路形成非完全对称的环路；主要交叉口提供约 15 m 转弯半径和 12 m 以上会车/回转净宽。
- 核心 Voxel 工作面位于中央，入口朝南；北侧形成可读的高工作面，避免一开始只是无特征平面。
- 西侧为设备维护、垃圾斗和小型工具区；东侧为混凝土管、托盘和材料区；北侧为弃土堆与视觉制高点；外围以低矮土坡、稀疏枯植被和安全设施收边。
- 固定 review cameras：`OverviewCamera`、`EntranceCamera`、`WorkFaceCamera`；另有自由飞行 `ReviewCameraRig`。

## 4. Visual system

- Forward+，中性偏暖下午光；太阳角度突出坡面，不让长阴影吞没道路。
- WorldEnvironment 使用 ACES、温和 SSAO/雾化和受控天空亮度。尘雾只承担空间分层，不遮挡地形交界。
- Terrain3D 至少区分压实土路、裸露土坡、碎石/岩土和边缘稀疏植被四类视觉表面；VoxelTerrain 采用与裸土相容、但略有颗粒与湿度差异的 triplanar soil material。
- 路缘、排水沟、轮迹/压实带和材料堆形成中景节奏；安全橙、混凝土灰、蓝绿设备件作为有限色彩锚点。
- 重复件采用 MultiMesh 或低成本模块；首轮高面 GLB 只作少量英雄道具，不依靠数十个原始锥桶填充画面。

## 5. Asset boundary

首轮候选：砂土堆、细砂堆、混凝土排水管、木托盘、施工手推车、绿色垃圾斗、铁锹、折叠路障、交通桶/少量锥桶、停止标志、两个低三角植被变体。排除 600 万面巨石和 530 万面破碎沥青。

`asset_catalog.json` 为每项记录：

- stable id / semantic role；
- 外部 source path 与 workbench cache path；
- bytes / SHA-256 / observed triangle count；
- source scale、Godot placement scale、rotation correction；
- import state 和 fallback proxy type。

源 GLB 只复制不改写。`ConstructionAssetInstance`（tool component）优先载入本地缓存；不存在时生成尺寸相近的代理并给出聚合诊断。代理使干净 checkout 仍可打开场景。减面阶段未来只需更换 catalog target，不改变地图节点和语义布局。

## 6. Authoring and authority

- 地形 source maps、site layout constants 和 asset catalog 是可复现输入；`.godot/imported` 永远不是源。
- Terrain3D 是硬地表权威，VoxelTerrain 是中央可挖体积权威；任何 transition mesh 只负责边缘结构，不冒充第二份土体。
- workbench 不接现有 `ExcavationWorld`、土量账本或 Jolt 产品链。局部挖除 smoke 只使用 `VoxelTool` 验证体积可编辑与下方无 Terrain3D。
- MCP 是开发工具，不是运行时依赖。场景文件、source maps、catalog 和脚本必须能通过 headless Godot 复现和验证。

## 7. Migration and rollback

- 首轮所有产品文件变更限定在 `godot/worldbuilding/earthworks_site/**`；Trellis 记录限定在本任务目录。
- workbench 删除即可完整回滚，不会留下产品入口、autoload、input map 或资源引用。
- 未来迁移采用单独任务：先优化/固化资产，再把自包含地图包复制到 `godot/client`，显式接入主场景；本任务不预先修改主项目以“方便以后”。

## 8. Risks

- Terrain3D 1.0.2 官方仅明确覆盖 Godot 4.4–4.6，对 4.7 custom 必须先做最小插件/hole/collision canary。
- 原始 GLB 极重；即使减面延后，也必须限制 unique load 和实例数，优先完成地形与代理布景。
- Terrain3D 与 Voxel Tools 没有官方无缝集成 API；使用完整未分配 region 作为所有权边界，避免宣称任意多边形无缝融合。
- 视觉质量是主观验收项。Agent 负责结构、导入、边界和性能诊断，最终构图/材质/照明由用户在一次稳定候选上人工验收。
