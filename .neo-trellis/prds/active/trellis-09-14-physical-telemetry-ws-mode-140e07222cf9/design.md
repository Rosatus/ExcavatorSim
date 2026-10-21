# Design — Physical telemetry WS mode

2026-09-22 规划版；业务代码未实施。需求以 prd.md 为准。以下参数是实现初始选择，须由 M1 故障测试验证，不作为额外审批项。

## 1. 职责与兼容边界

`CTN1 → MachineState / QML projection → PhysicalSample → WS → PhysicalFrameEncoder → existing CAN bus client`。

物理量边界在姿态解算后、协议量化前。共享物理语义但不让 physical 路径通过导入 gateway legacy 入口间接加载 DBC/sinks。保留 legacy emit_frames 作为字节基准。physical 运行生命周期必须支持游戏启动和退出，不借用仅 can 可用的 --mode；显式 parent PID/heartbeat 约束沿用当前监督设计。

Godot 只移除产品中的录制/ICT/定时 CAN 操作及发送调用；Gateway legacy 控制协议定义与处理保留。不得全局删除 RECORD_START/STOP 破坏旧模式。

## 2. WS v1 与配置

入口拟定 `/ws/physical`，与浏览器 `/ws` 分离，复用同一 uvicorn 服务。Gateway 参数 `--ws-endpoint`，默认 `ws://127.0.0.1:8000/ws/physical`，通过 GatewayConfigStore 独立键持久化，不把旧 0.0.0.0 TCP 地址静默迁移为客户端目的地址。跨机器由用户配置；对侧监听地址复用现有 web 配置。

对侧新增独立 physical 接收命令/运行模式，复用 bus/bitrate/channel mapping 参数；不依赖 PC001 连接。Windows 验收使用 pcan；默认映射来自现有 bus_client，不在新协议硬编码 USB 口。原命令不变。

协议落在 `protocol/physical-telemetry-ws-v1.schema.json`，manifest 添加独立版本键，不提升无关主协议版本。协议及语义常量只在本仓库维护权威源，对侧使用可校验版本/摘要的发布副本，不要求对侧运行时读取本仓库路径。

### 消息

- hello：version、session_id、model、profile、calibration_sha256、encoding_contract_hash、rates_hz、families。每次重连/仿真重置创建新 session。
- hello_ack / hello_reject：对侧确认期望身份和版本后才允许数据；拒绝含稳定错误码。单生产者，现有有效生产者占用时拒绝第二个，避免静默抢占。
- data：session_id、单调递增 seq、仿真 t_ms、物理采样 unix_s，以及 imu/slew/travel/rtk family。时钟字段单位明确，不接受 NaN/Inf。
- imu：body/boom/arm/bucket 各 `[roll,pitch,yaw]`，deg。
- slew：angle_deg；travel：left/right，MPa，保留 0/9。
- rtk：lat/lon（deg）、alt（m）、heading_deg、ve/vn/vu/speed（m/s）、vice_lat/lon/alt、satellite_status、用于 GPS 周/时间的 Gateway unix_s。
- 会话事件：source_stale/source_live、健康/错误；对侧状态响应区分已握手与数据活跃。

profile 与 model、DBC machine 的显式映射，以及无 QML profile 时 calibration 指纹的规范形式，在 M1 从实际 supported profiles 列表生成并纳入契约。对侧从配置/受支持契约白名单取得期望值，不能只信任发送者自报 hash。M1 对 RTK 字段与编码常量逐项核对，避免两侧重复应用 origin、secondary antenna 或 clamp。

## 3. 排队、超时与断流

- UDP intake 不等待网络。发送工作者与 intake 隔离；数据按 family/key 最新值合并，IMU 一组原子替换，RTK 一组编码，不保留历史 FIFO。
- 初值：telemetry 超时 500 ms；应用内待发送样本最大年龄 250 ms；hello 超时 3 s；网络发送超时 1 s；重连 0.25–5 s 指数退避并加抖动；事件队列上限 64。参数及调节依据写入测试/配置说明。
- Gateway 与 receiver 都用本地 monotonic 衡量停流和队列驻留，不直接相减两台机器的墙钟。seq/session 排除重复和旧会话。仿真 tick 回退意味着重建会话。
- receiver 发送前再次检查 session、源状态、队列年龄；断流使该源 generation 失效并清除未发送帧。慢发送达到期限直接终止会话、清空 pending、重新握手。恢复必须等待握手后的新遥测，不能把断线前最后值重新标成 fresh。
- 超时协议必须覆盖 TCP 内积压：应用队列清空不等于网络缓冲清空。M1 用可控慢链路验证；可用 receiver challenge/ack 建立恢复门槛，恢复时丢弃门槛之前的数据，不能凭到达时间把旧批次当成新数据。
- 事件在有效连接内不合并、不静默丢弃；队列满/发送失败时显式结束会话。离线不提供持久事件日志；重连重新声明当前状态。删除原“断网仍永不丢事件”的不可实现承诺。
- UI 保留最后物理值，整体标记等待/活跃/断流/拒绝。独立手动 injection 有独立 source，遥测停流不取消它；只依附遥测的 overwrite 不制造新的持续发送源。
- 已进入驱动的帧无法撤回；测试分别记录应用停发时间及总线最后帧时间。检查现有 PCAN QXMTFULL 重试是否可被上层截止期限终止；只有证据表明必要时才最小扩展后端，不用无限后台线程掩盖积压。

## 4. 编码与字节一致性

IMU 使用 legacy 表达式 `round((slot + 180) / 0.01)`，slots=(-pitch,roll,yaw)，clamp [1,65535]。不得等价改写为乘 100。回转经对应 ROTATE signal；行走压力直接编码既有 0/9，不从速度推导。RTK 保留原 origin、常量、1 m 副天线、范围与 GPS 时间算法，明确哪些已由 physical settlement 计算，禁止重复转换。

实施前对 legacy emit_frames 保存冻结时钟的 fixtures 和逐帧 tuple。覆盖零位、正负/极值、舍入半边界、RTK 边界、行走 0/9、所有实际支持 model/profile。先直接调用新 encoder 比较，再用真实 loopback WS + fake PCAN 端到端比较。无故障情况下每个 family/调度步逐帧比较；过载允许丢旧数据但不允许旧数据恢复回放。

## 5. 对侧复用与控制台

新增 physical endpoint/encoder/session runner 为主要改动；复用 DBC loader、overwrite resolver、dashboard、recorder 和 bus client。新 runner 拥有输出生命周期，不启动假 PC001 服务来激活旧 injection loop。CAN 帧成功发送后再沿用原 on_frame 观测语义，编码失败与硬件发送失败区分报告。

浏览器物理值/会话通过对侧快照的 additive 字段提供；老字段/API 保留。新静态 bundle 与旧内嵌 dashboard 保留可选择入口，缺 bundle 明确报错而不出现空白页。详情接口按需补齐现有缺失字段。完整能力范围见 prd.md。

新前端只复制视觉骨架一次，不建立与归档项目的持续同步。独立 package/build；对侧以配置指向构建输出，部署时复制 bundle，不依赖开发机器绝对路径。

## 6. Godot 与发布

复用桥接器唯一子 PID、配置持久化与重启逻辑；游戏连接状态分别表达进程在线、WS 已握手、遥测断流。在 M1 设计 additive UDP 状态包/兼容字段，不挪用旧 recording/ICT flag 含义；旧包解析保持。浏览器不连 Gateway。

默认切换必须与游戏 argv 迁移、冻包依赖、smoke_frozen_gateway、test_gateway_process 和 run_standalone_matrix 同批集成；M1–M3 可先显式 physical 验证，M4 才提交可运行的默认切换。legacy 路径用 `--output can --mode ...` 回归。
