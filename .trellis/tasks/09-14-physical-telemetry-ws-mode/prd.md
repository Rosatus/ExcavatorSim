# Physical telemetry WS mode

状态：规划完善，2026-09-22。尚未实施业务代码。本文替代 09-14 的暂停版需求；当前授权范围是完善规划。

## 目标与已确认决策

Gateway 默认仅产生语义物理量，通过一条 WS 发送到 can_replay；对侧负责量化、CAN 编码和总线输出。Windows PCAN 为本次硬件验收平台，出口后端沿用现有实现。

- 参数 `--output {physical,can}`，默认 physical；旧 `--mode {standalone,godot-managed}` 仅用于 `--output can`，显式与 physical 同用时报错。
- 保留旧 CAN 流水线、控制协议及旧控制台，原地标注归档，显式参数可用，行为不退化。
- 对侧实际目录 `C:/code/tools/can_replay`，检查基线 `68a8920`，当时工作区干净。用户最初给的 `C:/code/tools/can/_replay` 不存在。
- 直接开发和验证；暂不生成补丁或 original/modified 快照。优先复用对侧能力，只做满足边界的必要扩展。
- 游戏仅保留 WS 地址配置、Gateway 启动/重启和连接状态；移除 CAN 录制、TCP 地址、ICT、定时 CAN 的产品入口。CAN 操作由 replay 控制台承担。
- 遥测超时或 WS 断开后停止该遥测源的 CAN 输出；页面保留最后值并标记断流。恢复只使用新数据，不重放积压。独立手动注入任务不因遥测断流被误停。
- 新控制台为 `tools/replay_console/` 独立项目，复制旧控制台视觉骨架，由对侧托管；旧 `tools/can_gateway/web/` 不迁移、不改造成新控制台。

## 范围与链路

1. Godot ↔ Gateway：保留 UDP 29764（CTN1/CTNC）及 29765（心跳/结果）。保留子进程所有权、精确 PID 重启和旧心跳防串扰约束。
2. Gateway → companion：Gateway 为 WS 客户端，单连接，物理数据与会话事件两类消息。Gateway 不提供新模式 Web API，不加载 DBC 编解码器、CAN sink、PC001、CAN 控制台或 CAN 管理。
3. Browser ↔ companion：REST + 快照 WS。物理值及对侧状态由对侧提供；不展示旧 Gateway CAN 传输状态，不沿用逐 CAN ID freshness/实际频率列。允许显示遥测源整体断流标记。

保留 MachineState、校准、QML 投影和 FrameScheduler 的物理语义及调度。传输 IMU roll/pitch/yaw（deg）、回转角、行走压力（既有 0/9，MPa）、RTK 位置/航向/ENU 速度和 Gateway 采样的墙钟。禁止对侧重新计算行走压力或用自身墙钟替换 GPS 时间。

## 对侧协议评估与最小改动

源码检查：`web_dashboard.py` 的 `/ws` 接受 ping/state/filter，无物理遥测输入；`/api/inject` 和 PC001 要求已编码帧；overwrite 是持久单信号覆盖，不具备完整遥测语义。`socket_bridge.py` 的 injection 消费依赖 PC001 握手，不能直接充当独立 WS 接收运行模式。

因此零修改对侧无法满足已确认边界。必要扩展限于：物理 WS 输入与校验、编码适配、独立发送生命周期、物理值快照与新控制台托管。复用 DBC 加载、overwrite、录制、dashboard、`make_bus_client('pcan', ...)`。保留原有 PC001/API 行为，不重写 PCAN 驱动或强制更改映射。

## 控制台能力清单

- 物理值视图、遥测源会话状态、对侧输出状态。
- CAN 报文表、模糊搜索、通道/上送筛选、搜索命中高亮。
- overwrite 设置/清除，未上送消息物化注入，单次/20 ms/50 ms 预设及当前周期回显，父行与信号行高亮。
- 自定义帧与周期注入、停止操作；覆盖旧游戏定时帧的可配置能力（0x18FFF100、20 ms、10 s），不迁移 Linux ICT 管理流程到 PCAN。
- CSV、RRD、gRPC 录制，info/help、进度条及能力可用状态。
- 完整协议 CSV 22 列及 DBC 信号详情：scale、offset、范围、单位、choices、multiplexer、comment、cycle time、senders。
- 排除交互启动向导及 Rich 文本渲染器。实时源没有总长度时不伪造百分比进度。

## 验收

- [ ] 无参数启动 physical；显式 can + mode 保持旧路径；非法组合明确报错。
- [ ] physical 运行不加载 CAN 编码/出口/旧 Web 模块，不录本地 CAN 文件，不启动 Gateway HTTP 服务。
- [ ] 冻结墙钟和相同遥测输入后，新路径与旧 emit_frames 的每个 `(channel, can_id, extended, dlc, payload)` 完全一致，覆盖所有现有支持的 model/profile 和四类数据。
- [ ] 握手不匹配、未握手数据、格式/非有限数值错误不产生 CAN 帧；坏样本不产生部分 family。
- [ ] 慢端、缺席、断线、UDP 停流、仿真重置、重连均不阻塞 UDP、不导致无界缓存或旧样本补发。
- [ ] 单会话所有权及源级停发正确；手动注入生命周期独立；队列淘汰在实际发送前检查。
- [ ] 新控制台覆盖清单，只连接对侧，独立构建，旧控制台仍可构建和使用。
- [ ] 游戏默认启动新模式、正确显示进程和 peer 状态、持久化 WS 地址、保留精确 PID 生命周期；不再提供旧 CAN 操作入口。
- [ ] Windows PCAN 实机可观察正确通道/帧数据，断流停发、重连恢复及手动注入隔离通过。软件 mock 不冒充实机通过。
- [ ] Gateway 和 replay 相关现有测试相对实施前基线无新增回归，冻包启动冒烟通过。
- [ ] 行走压力 kg 文案修正为 MPa，不改变数值或线协议。

## 非目标与边界

不改 DBC/PC001 字节协议、标定与投影数学、CAN 波特率默认值；不要求 Linux 硬件验收、补丁交付、多遥测生产者并行或第三方兼容。软件无法撤销已进入 PCAN 驱动/硬件的帧，停发保证以应用发送入口为界并测量实际尾部延迟。

## 进度与下一步

完成：需求澄清、当前对侧协议可复用性评估、规划重整。未开始：M1–M4 所有实现与运行验证。滚动执行安排见 implement.md，协议和架构见 design.md。无待用户裁决的需求阻塞；实机阶段再确认可用 PCAN 设备及实际通道配置。
