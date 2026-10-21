# 建立机械 GLB 到 Godot 适配 Skill

## Goal

创建项目级共享 skill `godot-adapt-articulated-glb`，让未来 agent 能在不依赖
SY205 两份外部导入/枢轴指南的前提下，将结构相近的 Blender 机械 GLB 导入
Godot，建立可验证的关节映射、局部运动适配与可选被动连杆表现，并在机械语义
存在歧义时于落盘前一次性请求人工决策。

## Confirmed facts

- GLB 2.0 自身可确定性提供文件哈希、chunk、scene/node graph、node TRS 或 matrix、
  mesh/material/image/skin/animation 引用和 exporter `extras`；这些是可自动提取的
  事实，不需要作者文档。
- Godot 导入后的 `PackedScene` 可验证真实 NodePath、父子关系、局部/全局 Transform、
  mesh/material/texture survival、AABB，以及是否意外产生 skeleton、animation 或
  collision；不能用 `.godot/imported/*.scn` 的二进制缓存替代运行时检查。
- glTF 没有通用的机械关节、closed-chain、authority frame 或 neutral pose 语义。
  节点名称和 `extras` 只能作为作者声明及候选证据，不能单独证明机械正确性。
- 本次已验证的通用运行时模式是：根节点应用整机 delta；每个子关节从相邻
  authority frame 的相对关系提取单轴 rotation delta，保留 GLB 导入的局部
  origin/scale；全部主关节更新后再求解被动机构。

## Requirements

1. 在 `.agents/skills/godot-adapt-articulated-glb/` 创建项目自有 skill；不得修改
   Trellis bundled skills、全局 Codex skill 或 `.trellis/.template-hashes.json`。
2. `SKILL.md` 必须覆盖 discovery → evidence report → consolidated human gate →
   Godot import → manifest/runtime adapter → automated tests → visual review 的完整流程，
   并明确禁止从名称、mesh bounds 或未经验证的 `extras` 擅自断言 pivot/axis。
3. 技能必须在写 manifest、场景或运行时代码前汇总所有真正需要人工决定的事项，
   一次性询问；以下任一情况必须暂停：semantic frame 映射歧义、坐标系/单位/轴符号
   不确定、pivot 不在销轴中心、closed-chain 拓扑或 solver branch 不明确、需要重导出
   或修改用户资产。
4. 提供无第三方依赖的 `scripts/inspect_mechanical_glb.py`：解析 GLB 2.0 container 和
   JSON chunk，输出稳定 JSON（SHA、chunks、document counts、extensions、scene/node
   hierarchy、raw transforms、references、extras、diagnostics），不输出绝对路径、
   traceback 或不可证明的机械推断。
5. 提供按需 references，分别说明证据/置信度/人工门槛，以及 Godot 局部关节适配、
   坐标转换、被动连杆和回归测试模式；内容必须自包含，不链接或要求读取两份 SY205
   外部指南。
6. 提供 `agents/openai.yaml`，使 UI 元数据与 skill 触发语义一致；技能默认允许隐式调用。
7. 适配流程不得默认修改 GLB bytes、重导出模型、创建物理 authority、静默重命名
   protocol/frame IDs，或用 global calibration 覆盖嵌套 pivot 的局部机械链。

## Out of scope

- 自动从任意网格几何恢复 CAD 级销轴中心、joint limit、液压/质量/碰撞参数。
- 自动解决无语义节点、重复节点或任意复杂 closed-chain；此类资产进入人工决策门。
- 将该项目级 skill 发布为全局个人 skill、Trellis bundled skill 或公共插件。
- 修改当前 SY205 GLB、Godot 产品代码或 Python motion authority。

## Acceptance criteria

- [x] `quick_validate.py` 通过，skill 名称、frontmatter 和 `agents/openai.yaml` 合法且一致。
- [x] 检查脚本对当前 SY205 GLB 生成稳定、可重复的报告，SHA 和主要资源计数与现有资产
  合同一致；对截断、错误 magic、错误 declared length 和非法 JSON 返回稳定 code/exit status。
- [x] skill 的默认流程不读取两份外部 SY205 指南，也能从 GLB + Godot import + authority
  contract 建立候选链、区分可证明事实与作者声明，并在歧义时停止落盘。
- [x] reference 明确覆盖 root/local delta、相邻 frame 旋转、一次坐标转换、local origin/scale
  保持、parent-to-child 顺序、passive-after-authoritative、last-valid failure policy。
- [x] 独立 agent 在只获得 skill 路径和一个机械 GLB 适配请求时，能产出正确的先检验后决策
  计划，不把节点名称/extras 当成已验证机械事实，也不会直接修改资产。
- [x] 项目原有 `pixi run verify`、skill-local tests、Trellis validation 和 `git diff --check`
  全部通过；除用户已有无关改动外，提交只包含本 task 与新 skill。

## Open questions

无。项目级共享位置、自动证据边界、统一人工门槛、脚本范围和不依赖外部指南均已由
用户目标及仓库现状确定。
