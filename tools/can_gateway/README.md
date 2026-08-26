# CAN Telemetry Gateway

把 ExcavatorSim 的机器物理量编码为 SY135C CAN 帧 CSV，供 dev_arch2.0_36b5586c
引导系统经 `tools/can_replay` 回放消费。

```
ExcavatorSim (CanTelemetryBridge autoload)          Python gateway（独立进程）
  游戏面板 [CAN 输出] 按钮 ──控制包 CTNC──►          RECORD_START/STOP 分段写 CSV
  遥测流(50Hz, UDP :29764) ───────────────────►      编码器 → output/can_gateway/*.csv
  心跳监听(:29765) ◄────────心跳 CTNK─────────       flags.bit0=recording
游戏启动时自动 spawn python；失败/心跳超时 → 面板显示 offline。
headless（测试/CI）不自动 spawn，测试显式调 spawn_gateway()。
```

## 用法

```powershell
# 游戏 + 面板按钮即完整流程：点 [CAN 输出] 开始录制，再点停止。
# CSV 落在 <仓库根>/output/can_gateway/can_telemetry_<时间戳>.csv

# 单独手动运行 gateway（调试）
python tools/can_gateway/gateway.py --out output/can_gateway

# 冒烟（无需游戏，自注入合成包）
python tools/can_gateway/gateway.py --smoke --max-rows 40

# 测试
python -m unittest discover -s tools/can_gateway/tests   # 协议/编码器金样本
Godot: tests/can_gateway_e2e_test.gd                     # 进程监督+录制全链路
```

参数：`--port` `--imu-hz/--slew-hz/--rtk-hz/--travel-hz`、
`--rtk-byteorder {big,little}`。

## 关键约定

- **编码权威 = dev_arch2.0 `GuideSystem/services/can/protocolparser.cpp`**
  （DBC 与运行时解析存在分歧处一律跟随 parser）。
- **CGI610 全族小端**（含速度帧 ve/vn/vu/v；2026-08-25 按产品决策由大端
  统一为小端）。金样本测试断言默认编码器可逐字节复现实采帧。
  注意：parser 的 `parseCgi610CarV` 代码结构是大端（`(data[0]<<8)+data[1]`，
  全族唯一交叉），与 DBC/实采矛盾且两份实采均为零速帧无法仲裁——
  **若真车回放发现速度异常，优先核查 parser 此函数**。
  （`docs/can_spin_test_fixed.csv` 与本 gateway 无字节序冲突；
  判定端序唯一可靠的准则是"移位量是否等于字节地址偏移"。）
- 瑞芬 IMU：slot=count×0.01−180°；count 三连零 = 无效标记 → 编码器钳位 ≥1。
  parser 安装重映射 roll=s1/pitch=−s0/yaw=s2，在 `conventions.MachineState.
  sensor_slots` 反演。
- 行走压力 0x256：≥8 判移动 → 行进发 ±9，静止发 0。
- 轴系/安装标定集中在 `conventions.py`（ORIGIN_*、MOUNTING 相关纯数据），
  实机校准改表不动码。

## 文件

- `gateway.py` — 收包循环 + 帧率调度 + 冒烟模式
- `conventions.py` — 包解析 / 四元数→ZYX 欧拉 / ENU→大地坐标 / 行走语义
- `csv_writer.py` — CANape CSV 方言（UTF-8-sig，被对方 read_can_csv 消费）
- `encoders/` — ruifen_imu / dxg_slew / sinan_rtk / travel_pilot
- `tests/` — 金样本往返（实采 24 行×15 ID）+ 合成扫描 + 语义断言 +
  对方解析器兼容冒烟；`extract_golden.py` 一键重建夹具
