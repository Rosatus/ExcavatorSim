# 新版 DBC 差异

## 输入与哈希

- 新 CAN3：`E:/projects/temp/GuideSystem/GuideSystem/services/can/dbc/can3.sy135c.dbc`，SHA-256 `dc48542fda0ad369a3a30d0d13e74df1cdcc4c9bab71f01e9be3e56df99e7b58`。
- 新 CAN4：实际文件名为 `E:/projects/temp/GuideSystem/GuideSystem/services/can/dbc/can4.sy135c.dbc`，SHA-256 `fe7dd152c256b8c3d1999792fad66e8872d08d1053c56c51a2272f2978a5e3c1`；用户提供的带空格文件名在磁盘上不存在。
- 当前 bundle 位于 `tools/can_gateway/resources/dbc/`，哈希绑定在 `tools/can_gateway/dbc_engine.py:27-30`，加载校验在 `:969-982`。

## CAN3

- 原 12 帧 ID、名称、DLC=8、信号位置/长度/小端、缩放、偏移和范围未发生实质变化。
- 新增 `0x18FFF000 MSG_18FFF000`：DLC=8，`ROTATE 0|16@1+`，比例 `360/65536`。来源 `can3.sy135c.dbc:119-120`；注释 `:131-132` 说明旧协议曾为 DLC=2，但正式 `BO_` 定义为 DLC=8。
- 新增 `0x18FF3E00 MSG_18FF3E00`：DLC=8，`SWING 0|16@1-`，比例 `0.01`。来源 `:122-123`。
- 新增 `0x18FF3F00 MSG_18FF3F00`：DLC=8，三轴 gyro 与保留温度。来源 `:125-129`；注释 `:135-136` 说明当前业务不解析。
- 4 个角度帧 byte 6 信号由 `reversed` 更名为 `temp`，位布局不变。
- 8 个加速度/陀螺帧新增 byte 6 `temp` 信号，既有信号未移动。
- receiver 多数由 `P_Box` 改为 `Controller`，不影响编码位布局。

## CAN4

- 15 帧的 ID、名称、DLC、sender 与全部信号位布局完全相同。
- `0x0CFDA800` 四个速度信号仅新增“双字节小端”注释，字段本来已经是 `@1-`。

## 归属与例外

- 新 CAN3 共 15 帧，新 CAN4 共 15 帧；两文件没有重复 normalized ID 或名称。
- `0x18FFF100`、`0x256` 均不在两份 DBC，继续作为专用 contract。
- CAN4 的 `0x5801/0x5802` 在 DBC 中带扩展位，仍必须按 extended frame 处理。

## 迁移结论

- `0x18FFF000` 的角度换算与当前 `encoders/dxg_slew.py` 一致，但新路径必须以 DBC 的 DLC=8 和 signal definition 为权威，移除 native catalog 覆盖和仿真专用 encoder 调用。
- 必须同步 bundle 文件、`PROTOCOL_DBC_HASHES`、provenance、Windows/Linux 打包副本与相关计数/哈希测试。
- 旧 DBC 与新 DBC 内容不同，不能依靠 exact-content duplicate collapse 消除冲突；发行/默认 roots 中不得并存旧版和新版。
