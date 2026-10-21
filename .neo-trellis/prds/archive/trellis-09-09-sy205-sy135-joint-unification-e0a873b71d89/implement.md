# 执行计划

已执行并完成自动验证；人工操作/连杆体验验收 pending human review。详见 result.md。

## 1. 固定基准

- [x] 用户下一轮确认规划后执行 task.py start，加载 trellis-before-dev。
- [x] 通过 96 个未改动保护文件、共享 SY135 条目对比与现有 FK/gateway 基准测试验证不变性；见 protection-check.txt。
- [x] 验证 SY205 neutral、单轴正负增量、端点，确定方向和必要 offset；优先检查 -X 轴适配。
- [x] 检查 Python compatibility 的 SY205 URDF/模型消费者和 profile 一致性，明确需要同步的 SY205 数据。
- [x] 检查 frame、bucket posture 与 joint scalar 消费者；passive linkage 外观留待人工验收，不改土方算法。

## 2. 主代理实施

- [x] 添加以 SY135 为只读来源的同步/check 工具，明确共享字段、保留字段和少量 SY205 几何例外。
- [x] 成对更新 SY205 适配和 profile，同步 Godot 副本/SHA、SY205 rig version/catalog hash及必要 compatibility 数据。
- [x] 基准限位起步，只做必要几何修正，保留连续回转、reset、neutral rearm。
- [x] 添加 drift check、正负语义、端点和 SY135 不变量回归；不修改 SY135 golden 期望。

## 3. Agent automated

在仓库根使用已配置项目环境。实施时确认 Godot executable 路径后替换占位符。

```powershell
python backend/scripts/sync_equipment_command_profile.py --check
python -m unittest tools.can_gateway.tests.test_attitude_contract tools.can_gateway.tests.test_bucket_parity tools.can_gateway.tests.test_qml_compat
<Godot> --headless --path godot/client --script res://tests/equipment_command_mapper_test.gd
<Godot> --headless --path godot/client --script res://tests/jolt_articulated_equipment_test.gd
```

- [x] 新同步工具 --check；保护文件无本任务改动；baseline parity、SY205 bounds/FK/frame 同源。
- [x] 如涉及 Python SY205 数据，跑 backend/tests/backend/test_equipment_command_profile.py 及相关模型 FK 测试；如改 backend code 遵循其 spec 跑 pixi run verify。
- [x] 仅具体失败说明跨层回归时扩大测试，不例行导出、全矩阵或性能 soak。没有 gateway 实现改动，不跑其打包/硬件链路。

## 4. Human manual

- [ ] SY205 依次抬降臂、伸缩臂、收翻斗；意图与 SY135 相同。
- [ ] 三轴到两端，无明显翻折/连杆断开，完成一次收料卸料；大致可用即可。
- [ ] 切回 SY135，确认操作体验未改变；物理量链路仍由自动 baseline 验证。

人工未反馈时记录 pending human review，不以 headless 通过代替。

## 5. 收尾

- [x] trellis-check，逐项记录 A1–A5 证据。
- [x] 写清基准来源、唯一适配入口、刷新/check 命令与 SY135/gateway 保护约束。
- [ ] 仅提交本任务变更，记录人工验收状态，不混入其他任务。


## 2026-09-09 user follow-up

SY205 bucket proxy alignment, geometry exception [-20,95] degrees, zero spawn yaw and +Z-aware external cameras implemented. See followup-result.md for revised evidence and pending manual acceptance.
