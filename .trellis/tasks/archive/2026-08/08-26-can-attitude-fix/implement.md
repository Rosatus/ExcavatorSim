# Implement — 08-26-can-attitude-fix

## Phase 1: Y-up 欧拉分解（P0）
- [ ] 1.1 conventions.py：新增 quat_to_heading_elevation_roll_deg()（Ry·Rx·Rz 序），数值用例先行（抬臂/航向/组合）
- [ ] 1.2 MachineState.link_rpy 切换新分解；旧 quat_to_zyx_euler_deg 移除调用并标注 deprecated
- [ ] 1.3 test_gateway.py 轴系断言更新：抬臂30→pitch=−30、航向45→yaw=45、回转90+抬臂无奇异

## Phase 2: 安装角补偿层（P1）
- [ ] 2.1 conventions.py：IMU_MOUNT_COMPENSATION_DEG 表（sy205/sy135），附推导注释；link_rpy 应用补偿
- [ ] 2.2 gateway.py --model 参数 + bridge spawn argv 注入（默认 sy135）
- [ ] 2.3 测试：表值 vs manifest 重算对拍；rest 姿态解析 pitch=0±0.01；sy205 下游 Sensor2Ang 复刻 boomPhi/armPhi 验收
- [ ] 2.4 golden 回归：实采帧经新路径逆运算还原

## Phase 3: SY135 铲斗一致性（P2)
- [ ] 3.1 校验 bucket_link == passive_linkage.driven_frame 同源（sy135 mode=none 场景）+ 测试
- [ ] 3.2 parity fixture：bucket 行程扫描 case，q↔CAN byte 单调
- [ ] 3.3 README 关键约定三条契约更新

## Phase 4: 回归与收尾
- [ ] 4.1 Python 全量 + Godot e2e + 矩阵回归
- [ ] 4.2 trellis-check → spec 更新 → commit → finish-work
