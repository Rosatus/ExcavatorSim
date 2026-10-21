# Gateway 数据流与迁移影响

## 当前路径

- Godot UDP telemetry 经 `parse_packet -> emit_frames -> can_console.allows -> append_frame` 进入 CSV/TCP/SocketCAN，见 `tools/can_gateway/gateway.py:1116-1184`。
- IMU/RTK 已走共享 DBC codec；`0x18FFF000` 与 `0x256` 仍调用专用 encoder，见 `gateway.py:1143-1149`。
- Web custom 通过 owner-loop queue 与 scheduler 进入同一 transport sender，见 `gateway_web.py:439-473`、`gateway.py:873-910`。
- Linux 当前无 `--sink` 时默认 SocketCAN，Windows 默认 TCP，见 `gateway.py:1233-1269`；Godot bridge 又显式为 Linux 注入 SocketCAN、Windows 注入 TCP，见 `godot/client/scripts/can_telemetry_bridge.gd:292-312`。

## Channel 缺口

- `CanapeCsvWriter` 当前将所有行硬编码为 `ch3`，见 `csv_writer.py:44-55`。
- `FrameSink`、`append_frame`、DBC message definition 和 Web DTO 均没有 channel 元数据。
- PC001 TCP wire 自带 i32 channel，但当前恒写 `0`，见 `pc001_sink.py:146-154`；本任务将其改为 occurrence channel 的 `0/2/3` 数值映射。
- 因此 channel 必须作为一等帧元数据贯通：catalog/native descriptor -> console row -> gateway append -> CSV/Web/PC001；最终映射为 CAN3/`0x18FFF100`=`ch3`/wire 3、CAN4=`ch2`/wire 2、`0x256`=`ch0`/wire 0，不能只加前端列。

## 跨平台默认模式

- Windows/Linux 默认均改为 TCP Server，并统一 standalone/Godot-managed 的 transport capability 表达。
- Linux can0 helper、readiness、nonblocking/coalescing sender 保留在显式 `--sink socketcan`（或等价清晰参数）分支，标注“低延时模式（暂时停止维护）”。
- 默认 TCP 路径不得调用 `_open_can0()`、`prepare_can0()` 或 sudo helper。
- Godot Linux bridge 参数、状态文案和 E2E 断言都必须从默认 can0 改为默认 TCP。

## 发行/持久化

- 内嵌与相邻 DBC 都由现有构建复制；内容一致时 catalog 静默折叠。
- DBC SHA 变化会使旧 console catalog fingerprint 安全失效；旧配置不应按错误 schema 强行套用。
- 需要定义兼容迁移：按 canonical CAN ID、authority、payload/values 和 frequency 尽力迁移仍存在且 descriptor 兼容的行，不兼容项回退默认并给聚合诊断。
