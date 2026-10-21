# Design — 08-26-can-attitude-fix

## 1. Y-up 姿态分解（P0）

### 数学

从 Godot 四元数构造旋转矩阵 R（世界←link），按 **R = Ry(yaw)·Rx(pitch)·Rz(roll)**
分解（先航向、后俯仰、后横滚）：

```
yaw   = atan2(R[0][2], R[0][0])          # 世界 X-Z 平面内 link forward(-Z 列)的方位
pitch = atan2(−R[1][2], hypot(R[0][2], R[2][2]))   # elevation：forward 轴与水平面的夹角
roll  = atan2(R[1][0], R[1][1])          # 绕 forward 纵轴的侧倾
```

注意 Godot -Z 为前，矩阵列/行取法在实现时以数值验证为准（抬臂 q=+30° 必须得到
elevation=+30）。

### 符号契约链

| 层 | 关系 |
|---|---|
| 物理段方向 | 抬高 → 段仰角 elev > 0 |
| 下游解析 pitch | = −elev（抬起为负，真机金样本语义） |
| parser 重映射 | pitch = −s0 ⇒ s0 = +elev |
| sensor_slots() | slots[0] = −pitch_arg ⇒ 调用方传 pitch=+elev |

即 `link_rpy()` 返回 (roll, pitch, yaw) 中 **pitch 直接填段仰角**，
sensor_slots 的现有反演 `(−p, r, y)` 不动。

## 2. 安装角补偿层（P1）

### 数据来源（程序化推导 → 常量表钉死）

```
mount_comp[link] = seg_rest_elevation − frame_fwd_rest_elevation
```

| model | boom | arm | bucket | 出处 |
|---|---|---|---|---|
| sy205 | +47.65 | −78.24 | tip 推导 | pivot_contract 铰点累加（帧为单位阵） |
| sy135 | −35.00 | +55.00 | +75.00 | rest_transforms X 旋转（35/−55/−75），段几何全水平 |

实现为 conventions.py 常量字典 `IMU_MOUNT_COMPENSATION_DEG: dict[str, dict[str, float]]`，
附推导脚本注释；测试断言表值与 manifest 重算一致（读 JSON 对拍，防漂移）。
模型选择：gateway 无模型概念 → 由 UDP 包外的环境变量？**否**——bridge spawn argv
新增 `--model sy135|sy205`（默认 sy135），conventions 按 args.model 选表；
MachineState 构造加可选 mount_table 参数。

### 应用位置

`MachineState.link_rpy(link)` 返回补偿后欧拉：
`(roll, pitch + mount_comp[link], yaw)` —— roll/yaw 无安装差（IMU 固连不改变绕
纵轴/竖轴零位，假设安装无侧偏；如后续实采有偏差再加常量）。

## 3. SY135 铲斗一致性（P2）

- bridge 侧校验：motion_presentation/motion_client 激活 sy135 后，bucket_link 节点
  与 passive_linkage.driven_frame 同路径（sy135 passive_linkage.mode="none"，
  bucket_link 即驱动节点——天然同源；测试钉死该关系）。
- 相对角单调：parity fixture 新增 case（q_bucket 从 −60° 到 +60° 扫描），
  断言 CAN 字节随 q 单调（sy135 bucket 无四连杆反演问题，直接映射）。
- fixture 文件：`tests/fixtures/sy135_bucket_sweep.json` 或并入既有 parity cases。

## 4. 测试计划

| 用例 | 断言 |
|---|---|
| 纯抬臂 30° | 解析 pitch=−30±0.01，其余 <0.01 |
| 纯航向 45° | 解析 yaw=45±0.01 |
| 回转 90°+抬臂 | pitch≈−30、yaw≈90、无奇异 |
| sy205 rest | boomPhi 47.6±1 / armPhi 30.6±1（下游 Sensor2Ang 复刻公式） |
| sy135 rest | 解析 pitch: boom=+35±0.5? — 注意 sy135 rest 时段几何水平但下游期望看到什么？→ 段仰角 0 ⇒ 解析 pitch=0；下游标定误差项吸收形状。**验收以"等效钢面 IMU"为准：rest 时解析 pitch=−mount_comp? 否——rest 时段仰角=0，解析 pitch 应为 0±0.01**（安装角补偿使钢面 IMU 在 rest 时读数为段方向仰角的负值=0） |
| golden 逆运算 | 实采槽位经 decode→re-encode 还原分布 |
| 单调扫 bucket | CAN byte 随 q 单调 |

关键澄清（rest 期望）：安装角补偿后，rest 姿态下所有连杆解析 pitch=0（段水平），
boomPhi/armPhi 由**下游标定 pitch_error** 与其 Sensor2Ang 公式从 0 附近解算出
47.6/30.6 —— 这正是"下游零改动渲染正确 rest 形状"的机制。

## 5. 风险

| 风险 | 缓解 |
|---|---|
| 矩阵元素行列取错导致符号翻转 | 先写数值用例（已知四元数→期望欧拉）再实现 |
| golden 测试因编码路径变化而破 | golden 是实采 IMU 帧（已是钢面语义）；新路径输出应更接近金样本而非偏离——若破，说明补偿方向错 |
| sy205/sy135 表混用 | argv --model 显式传入；缺省 sy135；测试覆盖两表 |
