# Gateway 重启语义与 Web 状态布局修复 — Implementation Plan

## Phase A — 规范与 typed 状态契约

- [x] 更新 `can-gateway-control.md`：以 Gateway lifecycle/PC001/Godot telemetry 三个真值
  替代可见 ICT toggle；保留 exact owned-PID kill，禁止 port/name cleanup；消除旧 Linux
  default/host-OS capability 冲突；加入固定表格契约。
- [x] 为 `GatewayStatus` 增加 nullable `godot_connected`，同步 snapshot schema、runtime
  projection、严格 TS decoder 与 fixture。
- [x] 增加 managed/standalone 初始化及 delta 的 focused contract tests。

Rollback point: 此阶段仅增加向后兼容 status 字段；旧消费者忽略新增 JSON key。

## Phase B — Gateway Godot 活跃检测

- [x] 在 owner loop 以本地 monotonic 时间记录合法 CTN1 telemetry，设置 2.5 秒 timeout。
- [x] 只在 managed 状态 transition 时 publish；standalone 固定 `null`。
- [x] 覆盖首次合法包、非法包、control-only、超时、恢复和无 sink/无 PC001 条件。

Rollback point: 删除 activity tracker 即恢复旧状态，不涉及传输或 CAN 数据路径。

## Phase C — Godot Gateway 重启 UI

- [x] 将 `ICTConnectToggle` 改为非 toggle `GatewayRestartButton`，清理 Linux/ICT 旧文案与
  handler 命名。
- [x] handler 校验 endpoint，成功后持久化并调用 `respawn_gateway()`；删除未验证输入的
  即时持久化。
- [x] Bridge 暴露只读 lifecycle；UI 显示启动/重启/失败状态并在 transition 时禁用。
- [x] 保留独立 PC001 handshake 指示，不再以 ICT active/requested 驱动按钮。
- [x] 更新 operator focused tests，并复用现有 Godot Gateway E2E 验证 owned PID replacement
  和 fresh heartbeat。

Rollback point: Bridge 的 PID owner/restart internals不改；UI 改动可独立回滚。

## Phase D — Web 状态与稳定表格

- [x] Runtime summary 删除 ICT 卡，按 mode/nullable field 展示 Godot 已连接、未连接、不适用。
- [x] CAN table 增加 `table-fixed` 与九列 `colgroup`；锁定频率/新鲜度宽度，添加
  `whitespace-nowrap tabular-nums`。
- [x] 保留 50 ms ticker、`min-w-[1260px]`、表格 wrapper 横向滚动和 detail colSpan。
- [x] 扩展 Vitest：状态 snapshot/delta、无 ICT 文案、九列 layout contract、freshness
  100 ms/1 s/999 s 边界。
- [x] 重新构建 `resources/web` production assets。

Rollback point: Web source/build assets成对回滚；后端 nullable 字段可暂时无人消费。

## Phase E — 稳定后一次验证

- [x] Python：Gateway 193 tests 与 Ruff 通过；mypy 已执行并记录既有基线错误。
- [x] React：运行 Vitest、ESLint、typecheck、Vite build。
- [x] Godot：运行 operator/lifecycle focused tests，最后只运行一次相关 headless Gateway E2E。
- [x] 搜索确认 UI 不再存在用户可见 “连接 ICT/断开 ICT/需 Linux 网关”，且不存在新
  port/process-name kill 路径。
- [ ] 人工验收留给用户：浏览器表格边界/窄屏，以及一次真实 Gateway restart/PC001 reconnect。

本任务不构建完整 Windows/Linux/Godot 发行包，除非用户在验收后另行要求。

## User-requested test distributions

- [x] 构建 Windows standalone Gateway 到 `dist/can_gateway`，刷新 provenance manifest，
  并以隔离端口验证冻结程序的 Web/status 与受控 shutdown。
- [x] 通过 WSL/FNM Node 构建 Linux Gateway + can0 helper 到
  `dist/can_gateway_linux`，刷新 provenance manifest，并以隔离端口验证 ELF 的
  Web/status 与受控 shutdown。
- [ ] 用户完成 Windows/Linux 人工分发验收。
