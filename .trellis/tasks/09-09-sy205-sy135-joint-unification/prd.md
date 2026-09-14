# SY205 关节语义与限位向 SY135 收敛

## 目标

SY135 为唯一维护基准。SY205 使用相同关节物理量语义和近似操作行程，只保留资产几何必需的适配，减少独立配置。用户接受近似，不要求精确复现 SY205 真机。用户已批准实施；当前修复完成自动验证，人工动作/连杆验收待反馈。

## 已确认背景

- 操作轴为 swing/boom/arm/bucket，正向意图为右转/抬臂/伸臂/收斗；SY135 转换符号 [-1,1,1,-1]，SY205 [-1,-1,-1,1]。操作意图已一致，模型坐标不同（`protocol/equipment-command-profile-v1.json:3-28`）。
- 两个 rig 拓扑相同，速度/加速度/jerk 相同，rest/anchors/limits 不同（`godot/client/resources/physics/sy135_physics_rig.json:16-26`、`sy205_physics_rig.json:16-26`）。当前工作装置是运动学积分。
- gateway legacy 补偿与 SY135 专有 QML 投影是不同角度定义，不能作为关节限位或零位互换使用（`tools/can_gateway/conventions.py:26-52`、`qml_profile.py:77-107`）。

## 要求与验收

| 要求 | 可观察验收 |
|---|---|
| R1 SY135 不变：方向、零位、单位、限位、初始姿态及 gateway 链路均为硬约束 | A1 相同输入/tick 下，SY135 joint scalars、accepted FK、presentation/CTN1 与修改前基准按原容差一致；既有 gateway 测试通过，保护文件无本任务引入的改动 |
| R2 SY205 位置/速度/目标量采用 SY135 正负方向与 rad 单位，资产方向留在适配层 | A2 正负操作实际动作正确、标量语义一致，reset/model switch 无残留输入；禁止只翻 signs 导致反向动作 |
| R3 SY205 行程近似跟随 SY135 | A3 以统一逻辑 q 中 boom [-25°,45°]、arm [-60°,45°]、bucket [-45°,45°] 为起点，连续回转；全行程有界、无反转，可收斗/卸料。允许最小必要端点修正并记录依据 |
| R4 单一维护来源 | A4 SY135 基准可确定性刷新 SY205 重复控制字段，check 能发现漂移；几何、身份、质量、履带配置不被覆盖 |
| R5 gateway 真实物理链路保持 | A5 SY135 legacy/QML 输出不变，不改补偿、标定、DBC、投影或编码；SY205 不伪装成 SY135，不启用其不支持的 QML profile |

Agent automated：A1、A2 标量/方向、A3 数值边界、A4、A5。Human manual：SY205 动作/连杆外观、基本收料卸料与大致行程；实施后未反馈时标记 pending human review。

## 不在范围

- 修改 SY135 资源、关节物理量语义、gateway 输出链路。
- 为 SY205 新建 QML/CAN 标定体系或精确真机限位；要求两模型世界角度、端点和工作包络完全一致。
- 重做 GLB、液压动力学、履带、土方算法，清理其他任务改动。

## 规划结论

用户本轮反馈碰撞代理错位、收斗碰小臂、外翻不足，以及出生/外部视角反向。此前“统一限位无需额外修正”的结论撤回：仅标量端点检查不足以验收几何。SY205 bucket 采用允许的几何例外 [-20°,95°]；代理重定位到实际导入网格；出生去掉额外 PI，外部相机按 +Z 车头取后方。SY135 与 gateway 保护边界维持不变。详见 followup-result.md。
