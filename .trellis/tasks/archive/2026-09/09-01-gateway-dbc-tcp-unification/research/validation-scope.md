# 验证与发行影响

## 规格

- `.trellis/spec/backend/can-gateway-control.md`
- `.trellis/spec/backend/quality-guidelines.md`
- `.trellis/spec/backend/can-qml-compatibility.md`
- `.trellis/spec/frontend/validation-budget.md`

## 快速自动验证

- Gateway Python tests：DBC hash/catalog/diff encode、CSV/Web/PC001 channel mapping、混合 channel batch、default TCP/no helper、explicit SocketCAN、timed/custom authority、batch revision/persistence。
- React Vitest：channel 列、新帧、三批量按钮、unsupported simulation 结果、WebSocket refresh、旧 profile migration。
- 定点 Godot headless：Linux/Windows argv 都默认 TCP，PC001 handshake 与 Gateway 状态；显式低延时参数单独验证 argv，不跑视觉场景。
- provenance、manifest 和打包布局测试。

## 人工一次

- Windows/真实 Linux 无参数启动并连接 TCP client，核验 CSV channel、Web 三态与新增帧。
- 真实 Linux 以显式低延时参数连接 USB-CAN，确认原 helper/readiness 与物理发送仍能工作。
- 浏览器明暗主题及布局交互由人工验收；不增加冗长视觉自动化。
