# Web、批量三态与 timed CAN

## 当前 Web

- 帧表与工具栏在 `tools/can_gateway/web/src/components/CanConsole.tsx:325-376`。
- 单帧三态 `off/custom/simulation` 已由 `AuthorityControl` 实现，见 `:239-260`。
- 编辑弹窗已支持物理值/payload 双向编辑和 1..100 Hz 整数频率，见 `:64-233`。
- `CanConsoleMessage` 尚无 channel，见 `web/src/types.ts:131-146`。
- WebSocket 负责 runtime delta；mutation 仍走带 revision 的 REST。批量切换不应由前端循环单条 PUT，否则会产生 stale revision 和多次副作用。

## 批量 API 推荐

- 新增 owner-loop 原子 batch authority command，一次校验 expected revision、一次持久化、一次清理/重排 scheduler、一次发布 snapshot event。
- “全部关闭”“全部自定义”作用于全 catalog。
- “全部仿真”对 `simulation_capable` 行设为 simulation，对没有 Godot producer 的行设为 off，并返回被关闭的 ID 清单；不能静默保留旧 custom sender。
- 当前 Godot producer 只有 4 个 RPY、10 个 RTK、`0x18FFF000` 和 `0x256`。新版 `0x18FF3E00`、`0x18FF3F00` 以及 CAN3 加速度/陀螺行没有仿真源。

## `0x18FFF100`

- 当前不在 console catalog；`allows("timed", ...)` 无条件放行，见 `can_console.py:582-588`。
- 现有 timed burst 固定 payload `01 00 00 00 00 00 00 00`、50 Hz、10 秒、最多 500 帧，见 `gateway.py:81-85,164-213`。
- 要在 Web 显示并支持 custom，必须将其注册为专用 descriptor，并明确 off/custom/simulation 对 timed burst 的仲裁，而不能只增加一行 UI。
- 用户已决定 custom 仅编辑 raw payload + frequency；由于没有 DBC signal 定义，物理值区域显示无定义，不提供 byte0..byte7 伪物理量。
