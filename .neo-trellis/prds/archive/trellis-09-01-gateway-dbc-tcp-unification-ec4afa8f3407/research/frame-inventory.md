# Gateway 主动发送 CAN Identity 清单

## 当前代码与旧 bundle

- 当前内置 DBC：CAN3 12 帧 + CAN4 15 帧，共 27 个唯一 EFF identity。
- Godot 自动 producer：IMU 4 + RTK 10 + `0x18FFF000` + `0x256`，共 16 个。
- timed producer：`0x18FFF100` 1 个。
- 当前 DBC 外生产帧共 3 个：`0x18FFF000`、`0x18FFF100`、`0x256`。

生产出口为 `tools/can_gateway/gateway.py:96-124` 的 `append_frame()`；Godot producer 位于 `gateway.py:1116-1175`，timed producer 位于 `gateway.py:180-213,1020-1026`。

## 新版 bundle 完成后

- 新 CAN3 15 帧 + CAN4 15 帧，共 30 个唯一 EFF identity。
- `0x18FFF000` 已由新 CAN3 DBC 定义并迁移到 shared codec。
- DBC 外仅保留 `0x18FFF100` EFF 与 `0x256` SFF 两个专用 contract；没有其他内置生产 CAN ID。
- Godot/timed 自动 producer 仍是 17 个 identity，但组成变为 15 个 DBC 帧（IMU4 + RTK10 + slew）和 2 个专用帧（travel + timed）。
- Web 内置 catalog 可自定义发送 30 个 DBC identity + 2 个专用 identity，共 32 个。

`--dbc-dir` 允许用户在运行时加载额外 DBC，因此可发送集合可以增加，但这些额外 ID 仍然是 DBC 定义帧，不属于隐藏的手写帧。

## PC001 i32 channel

- PC001 batch 格式为 `[u16 count] + count × [16-byte Linux can_frame + i32 LE channel]`，见 `tools/can_gateway/pc001_sink.py:1-12,28-32`。
- 16-byte `can_frame` 已包含 CAN ID、DLC 与最多 8-byte payload；后面的 i32 是 PC001 桥接/路由元数据，不属于 CAN payload，也不改变 DBC 编码。
- 当前 sink 在 `pc001_sink.py:146-154` 对所有帧写死 i32 `0`。
- GuideSystem 生产 parser 使用 CAN3=3、CAN4=2、0=自动识别/其他；用户已批准让 PC001 i32 同步承载 CAN3/`0x18FFF100`=3、CAN4=2、`0x256`=0。
