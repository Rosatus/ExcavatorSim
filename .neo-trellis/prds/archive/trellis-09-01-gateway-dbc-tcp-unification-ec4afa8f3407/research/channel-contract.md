# DHC CSV 与 PC001 channel 契约

## 已确认

- 本任务最终要求 CSV/Web 标签：CAN3 DBC=`ch3`、CAN4 DBC=`ch2`、`0x18FFF100`=`ch3`、`0x256`=`ch0`。
- 当前 CSV 的 `CAN通道` 文本是 `chN` 形式；当前实现错误地恒写 `ch3`。
- PC001 wire 的 i32 channel 历史契约一直恒为 `0`，历史设计也明确 channel 恒 0。
- GuideSystem 生产 parser 对设备入口采用 CAN3=3、CAN4=2，且 vcan bridge 固定上送 0 后自动识别；新的逻辑 CAN3/CAN4 标签与生产 parser 一致。其旧测试夹具曾使用 CAN4=4，但不作为本任务权威。

## 最终规划决策

- 本任务将 `ch0/ch2/ch3` 作为统一 channel authority 贯通到 CSV、Web 与 PC001。
- PC001 i32 使用逻辑标签的数值部分：CAN3/`0x18FFF100`=`3`、CAN4=`2`、`0x256`=`0`。
- 只改变 i32 元数据值；PC001 framing、handshake、16-byte CAN frame、ID/DLC/payload/EFF packing不变。
