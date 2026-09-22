# 修复结果

## 根因与修复

上一轮只复制 SY135 command signs，没有落实设计要求的 SY205 资产轴适配；因此 W/S、I/K、J/L 都会反向。仅更新符号表测试无法发现这个问题。根因分类：变更传播遗漏 + 跨层测试缺口，不是键绑定错误。

本次保留共享 signs [-1,+1,+1,-1]，将 SY205 boom/arm/bucket rig 轴改为 -X；swing +Y、rest 和 anchors 不变。SY135 的物理量、资源和 gateway 链路没有修改。

同时补齐原计划未完成部分：

- sync_sy205_joint_contract.py 提供 SY135 → SY205 的共享限位/执行器/profile 同步及只读漂移检查，同步 catalog/hash/provenance。
- Python compatibility 的 SY205 实时和回放使用专属资产坐标适配；限位跟随同一 rig，缸长偏置和 legacy bucket posture 在各自边界转换。SY135 不使用该适配。
- 删除上轮误加到 catalog 的无效 rig_version 字段。

## Agent automated

- Godot equipment_command_mapper_test：通过。实际输入经过积分和 FK；四轴正反方向、W 前伸、K 抬臂、三关节双端点和不越界均断言。
- Godot jolt_articulated_equipment_test：通过，两模型运动、neutral/rearm、limits/reset 等原有合同通过。
- 后端：195 passed；新增 10 个 SY205/保护测试包含八个轴向样例、runtime/replay/缸长/limits、SY135 原模型/标定/FK 不变。
- gateway：attitude 9、bucket parity 2、QML 17，合计 28 passed。
- 工具链：23 passed、1 skipped（Windows symlink 权限限制）。Ruff、mypy、provenance、standalone path 检查通过。
- sync_sy205_joint_contract.py --check 与原 profile sync --check 通过。
- 96 个保护文件相对任务开始时未改动的 HEAD 内容一致；共享 profile/catalog 中 SY135 条目一致。

验证过程：首轮后端全检定位到 SY205 legacy bucket posture 尚未适配，修复后该测试和后端全套通过。随后 provenance 检查定位到生成物旧 hash，同步后该 gate 单独通过；其余已通过测试不重复刷跑。verify.log 保留排查过程最后一次组合命令结果，最终补充 gate 以上述记录为准。

独立审查未发现 SY135/gateway 变化；提出的生成器 provenance 与端点覆盖问题已补齐。

## Human manual — pending

重启当前运行实例以重新加载 profile/rig。SY205 检查 W/S 前伸/收回、I/K 下降/抬升、J/L 收斗/翻斗、A/D 回转，观察全行程连杆并完成一次收料卸料；切回 SY135 核对原有操作体验。大致可用即可，不要求两机型绝对姿态一致。

原始 SY205 导入 fixture/URDF 继续表达资产坐标。历史 SY205 原始关节角数据不可直接当成新的共同逻辑角；本任务不迁移历史记录文件。

## 防止复发

新增 model-joint-semantics.md，规定 signs 与资产轴必须成对变更；使用实际 FK 回归，禁止仅修改 expected signs 宣称通过。SY135 始终作为不可变参考，人工验收未反馈前任务保持 in_progress。
