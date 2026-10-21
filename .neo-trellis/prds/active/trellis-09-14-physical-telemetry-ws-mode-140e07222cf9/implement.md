# Rolling implementation plan

## 状态

2026-09-22：仅完成规划，M1–M4 未实施；没有业务代码、运行测试或硬件验收结果。本轮不激活实现。对侧 baseline 68a8920；实施开始重新检查两个仓库差异，保留用户已有更改。本仓库已有无关任务归档变更，不纳入本任务。

## 里程碑与依赖

| 阶段 | 交付 | 退出条件 |
|---|---|---|
| M1 | 冻结 schema/语义表、Gateway physical path、loopback stub、状态与失效规则 | 不加载 CAN；握手/慢端/断流/重置测试通过；legacy golden 建立 |
| M2（依赖 M1） | 对侧最小物理入口/encoder/独立 PCAN runner | 全 family 字节一致；真实 WS + fake PCAN 故障验收；原协议不回归 |
| M3（依赖 M2 API） | replay_console 独立项目、能力补齐、对侧托管 | PRD 清单逐项核对、构建及浏览器主流程通过 |
| M4（依赖 M1–M3） | 游戏迁移、默认切换、冻包/脚本/文档、实机验收 | 默认启动链可用、旧模式通过、Windows PCAN 验收有证据 |

## M1 可执行步骤

1. 检查两侧 AGENTS/相关 specs 和差异；记录 Gateway、replay 受影响测试基线及当前支持 model/profile/DBC mapping。不把本机模型目录误当作 encoder 已支持列表。
2. 读取真实 emit_frames、RTK encoder、conventions、calibration、QML projection、scheduler；生成冻结墙钟 golden fixtures。记录 family cadence、字段来源、单位、边界、常量及 manifest。
3. 冻结 WS schema、hello ack/reject、session/seq、数据/错误约束、超时与失效状态机；确定 UDP additive 状态扩展及无 profile 的标定指纹。以最小 fixture 验证双方能够独立实现。
4. 分离 physical 导入路径，增加 PhysicalSample/settlement 和独立发送工作者；保留 legacy emit_frames，不先翻转产品默认值。增加 ws endpoint 配置键。
5. 用 loopback stub 测合法与错误握手、无 peer、慢 reader、积压恢复、源停流、tick 回退、第二连接和关闭。断言 UDP 持续接收、缓存有界、旧 generation 不会发送，不只断言最终收到消息。
6. 核对 parity 输入输出、物理导入隔离和 legacy 回归；更新 checkpoint。M1 中不能仅凭队列大小通过就认定网络旧数据问题已解决。

## 后续阶段细化触发点

- M2：M1 schema 固定后列出 companion 最小文件改动；先复用 make_bus_client。检查 PCAN backpressure/retry 的取消语义，再决定是否确需后端小改。保持原 web/bridge tests。
- M3：M2 snapshot/API 确定后，把 PRD 能力清单映射为页面操作与测试；校验断流显示、overwrite/注入、录制、详情、搜索以及无 bundle 行为。
- M4：在默认切换前枚举启动调用方和打包依赖；实机准备时获取设备实际映射/驱动可用性，不以默认 USB 编号猜测连接。没有设备时记录软件验证通过、硬件待验收，任务不冒称完成。

## Windows PCAN 验收步骤

1. 记录应用版本、PCAN 驱动、实际 channel mapping、bitrate 与接收/分析工具，复用用户配置，不自动改物理 CAN 参数。
2. 启动对侧 physical + pcan、游戏/Gateway；检查 hello、一组各 family 数据与 PCAN 实际通道/载荷。
3. 停 UDP、断 WS、恢复两端；测应用停发与硬件尾帧延迟，确认只恢复新值。并行手动注入仍按其生命周期运行。
4. 错误身份/标定不得输出；关闭/重启只影响所属会话/PID；总线异常明确报告。
5. 实机证据与 frozen parity、mock 故障验证分开记录。仅验 Windows PCAN，无 Linux 实机和补丁交付门槛。

## 下一步

用户进入实现后，从 M1 步骤 1 开始；不重做已完成的需求澄清。需要现场信息的 PCAN 映射到 M4 再取得，不阻塞 M1。
