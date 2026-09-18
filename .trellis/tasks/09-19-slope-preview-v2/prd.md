# 09-19-slope-preview-v2

## 背景

修坡预览第一版用 `SlopeCutPreviewVisual` 画半透明橙色楔体（`no_depth_test`），
效果是"悬浮荧光块"而非"将消失的土"：顶面为粗网格采样重建，与真实地形（尤其已
挖坑面）不贴合，存在 z-fighting 与穿透渲染的观感问题。用户要求换思路。

## 目标

预览表达拆成两层，替代楔体网格：

1. **体素区地表消隐闪烁**（世界内）：挖掘只发生在 voxel zone，直接让真实地形表面
   中"将被削掉"的部分在 实体↔透明 之间闪烁；消隐相位露出的洞内始终显示目标剖面
   "完工地面" ghost skin。
2. **侧视剖面 HUD**：沿舱向轴的 2D 侧视图，显示机身侧影、大臂/小臂/铲斗连杆、
   地形线、目标剖面线、切削区填充、齿尖与目标面误差、参数读数。
   仅修坡预览/激活态显示（平地辅助不出）。

## 已确认决策

- 闪烁形式：**消隐 + 完工地面**（discard-blink + ghost floor 常显）
- 侧视图范围：**仅修坡相关态**（preview + active）
- 激活期世界内：不再消隐（真土已在切），目标面 ghost 保留作设计面参考
- 楔体网格整体退役；体积估算保留给侧视图读数

## 方案

### A. voxel 消隐（`voxel_soil_bounded.gdshader`）

材质已挂 `VoxelTerrain.material_override`，fragment 已有 `soil_world` varying。
新增 preview uniforms，解析判定：

    s = dot(soil_world.xz - origin, axis)
    h_t = toe_h + (s > toe_s ? tanθ·(s - toe_s) : 0)
    cut = cut_mode==1 && s∈[s_min,s_max] && |t|≤half_w && soil_world.y > h_t
    cut → fract(TIME·hz)>0.5 时 discard；实体相位 ALBEDO 混入 tint

`TIME` 驱动脉冲，零逐帧 uniform 更新。`cut_mode`：0=off 1=preview 2=active。

### B. 完工地面 ghost（`slope_cut_preview_visual.gd` 重构）

目标面是分段解析面（平段+坡段），直接生成 ribbon quad（无需地形采样）：
- 深度测试 ON，暖土色 alpha≈0.35 → 只在洞/悬空处可见
- 剖面边缘细亮线 no-depth → 任何相位下坡线可读
- 预览期+激活期都显示（激活期=设计面参考）

### C. 侧视图（新 `slope_side_view.gd`，Control._draw）

- 数据：runtime `slope_view_snapshot()` → `slope_status_snapshot().view` →
  session 自动镜像 → UI `queue_redraw`
- 投影：s = dot(xz-origin, axis)，h = y；关节 origin 经 `frames_for_positions`
- 地形折线复用 `slope_cut_preview` 采样器（t=0 中线）
- 角标 `d=… θ=… V=…` 取代世界内 Label3D readout

### D. 推送链路

`VoxelWorkZone` 缓存 `_soil_material` + `set_cut_preview(dict)`/`clear_cut_preview()`；
runtime `update_slope_preview` 时经 `_terrain_world.voxel_work_zone` 推送；
取消/确认时 `clear`。

## 非目标

- 不改控制律/剖面数学/状态机语义
- 不改 voxel 数据/authority/ticket 管线（纯表现层）
- 平地辅助不加侧视图

## 验收

- `preview_uniforms()` 打包纯函数 + 侧视投影纯函数单测
- slope/bucket/assist_menu 现有测试全 PASS
- 手动：消隐节奏、洞内 ghost 观感、侧视读数、激活期 ghost 静态显示
