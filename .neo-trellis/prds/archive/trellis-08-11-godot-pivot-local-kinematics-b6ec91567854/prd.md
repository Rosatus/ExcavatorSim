# 修复 SY205 局部枢轴运动链

## Goal

让真实 SY205 GLB 在非零运动姿态下始终遵守用户提供的
`SY205_Godot_Pivot_Definition_Guide.md`：机械枢轴位置保持在销轴中心，父子局部平移不漂移，回转只绕 Godot 局部 Y，工作装置关节只绕局部 X；同时继续由 Python `view_state` 独占运动权威。

## Confirmed evidence

- GLB 原始层级、节点名称、局部平移、单位缩放和零位累计世界坐标均与指南一致；GLB SHA-256 `cf95534b31bcc156980afefef0a9f273e5c6f727547b3db1e9062ca5619b495a`，无需重导出。
- 当前 `MotionPresentation` 将五个 Python frame 各自写成 `frame_node.global_transform = incoming * calibration_offset`。该公式通过当前 global parity 测试，却没有保持 GLB 的父子局部枢轴平移。
- 以现有 asymmetric fixture 计算，`PIVOT_ARM_JOINT → PIVOT_BUCKET_JOINT` 的局部平移会从指南要求 `(-0.008,-3.026,-0.630)` 漂移为约 `(-0.008,-6.153,-0.649)`；`PIVOT_BOOM_BASE → PIVOT_ARM_JOINT` 也会漂移。
- 枢轴指南要求 D/B 固定在 arm 局部、C 固定在 D/铲斗局部、A 是 B 的子节点，Side Link 控制器复制 A 的 arm-local 位置并绕局部 X 对准 A→C。

## Requirements

1. 保留 GLB 原始 bytes、层级、网格局部 Transform、材质和现有五帧路径；不修改 Python 后端、URDF、协议 schema 或 GLB 文件。
2. 用相邻 Python frame 的相对旋转 delta 驱动 GLB 枢轴，而不是对每个嵌套 pivot 独立写校准后的世界 Transform：
   - root 只承载整机基准位移/姿态，不能作为 slew 关节；
   - `PIVOT_SLEW` 只改变 local Y rotation；
   - `PIVOT_BOOM_BASE`、`PIVOT_ARM_JOINT`、`PIVOT_BUCKET_JOINT` 只改变 local X rotation；
   - 所有 pivot 的 local origin/position 保持 GLB 导入值。
3. 保持被动四连杆边界：D 由 bucket frame 驱动，C 随 D 层级移动，B/A/Side Link 由 Godot 四连杆 solver 视觉推导；solver 不得覆盖 A/C 位置、网格独立 Transform 或 Python 状态。
4. 继续使用唯一的 `MotionProtocol.rows_to_transform` Z-up→Y-up 转换，不在枢轴修复中添加第二次坐标转换或全局 ±90° 补偿。
5. 扩展测试，覆盖指南给出的 parent-local positions、父级关系、旋转轴/scale、不变的 B-D/AB/AC/CD 几何，以及单独 boom/arm/bucket 非零姿态和 zero restore。
6. 非法/非有限/不满足机械约束的输入不得污染上一次有效 pivot 或四连杆姿态；必须保留稳定诊断。

## Out of scope

- 重新导出或修改用户 GLB。
- 添加刚体、碰撞、动画烘焙、液压缸动力学或 backend authority。
- 将 Python link frame 的世界原点强行当作视觉 pivot 销轴中心。
- 改造 terrain、bucket soil、replay 或 HTTP/WebSocket schema。

## Acceptance criteria

- [x] GLB SHA-256、节点层级、所有指南 local translations 和单位 scale 在 Godot 运行时通过误差 ≤ `0.002 m` 的检查。
- [x] zero、swing、boom-only、arm-only、bucket-only 和 asymmetric pose 下，`root→slew`、`slew→boom`、`boom→arm`、`arm→bucket` 的 local origin 与指南保持；slew 只有 Y 旋转，其余主关节只有 X 旋转。
- [x] B/D 在 arm-local 中保持，C 在 bucket/D-local 中保持，B-D 距离不变；AB/AC/CD 及 Side Link 运动满足当前四连杆 contract。
- [x] 非零姿态下，boom、arm、bucket 不再发生因独立 global calibration 导致的父子销轴漂移；现有五帧相邻关节旋转 parity 仍通过。视觉 pivot 的世界原点不要求等于 Python link-frame 世界原点。
- [x] zero/reconnect/stale/restore 后所有主 pivot 的 local Transform、B/Side Link 控制状态和 bucket-tooth presentation proxy 恢复；Python input/state 未被修改。
- [x] Godot standalone matrix、MCP runtime smoke、`pixi run backend-smoke`、`pixi run verify`、Trellis validation 和 `git diff --check` 全部通过。

## Open questions

无。GLB 不变、Python 继续作为 motion authority、Godot 仅重建视觉局部运动链均已由现有架构和用户指南确定。
