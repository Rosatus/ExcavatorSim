# Fix Godot-Managed Offline Custom Authority — Implementation Plan

## Phase 1 — Lock The State-Transition Regression

- [x] 在 `tools/can_gateway/tests/test_gateway_process.py` 增加一个 focused Godot-managed TCP 进程 canary，使用隔离端口与临时配置目录。
- [x] 无 PC001 client 时通过 Web API 将代表性 simulation-capable 行切到 custom，跨越多个发送周期后断言 authority仍为 custom、scheduler仍 active、drop增加且 egress frequency未伪造。
- [x] 随后完成 `who/PC001` 握手，不再次 mutation，断言后续 custom payload成功发出。
- [x] 断开并重连，断言 authority保持且没有离线 backlog replay；只观察重连后的周期发送。
- [x] 保留现有 standalone 进程测试，明确其无客户端 Start/断连 disarm 行为不变。

## Phase 2 — Separate TCP Availability From Managed Authority

- [x] 修改 `tools/can_gateway/gateway.py::send_operator_frame()`：managed TCP handshake false 时走 sink 的 no-client drop路径，不调用 `reset_managed_overrides()`。
- [x] 修改 `refresh_runtime_status()` 的 PC001 disconnect transition：managed 模式只发布 transport 状态，不重置 row authority/scheduler；standalone继续 disarm。
- [x] 保留 SocketCAN terminal retirement、explicit reset、shutdown/restart和 timed CAN 分支。
- [x] 确认 authority mutation仍原子更新 revision/snapshot/event，并且不同 ID 不受兄弟行影响。

## Phase 3 — Focused UI And Transport Regression

- [x] 扩展 `tools/can_gateway/web/src/App.test.tsx`：`godot-managed + pc001_handshake=false + dropped>0` 时 custom radio enabled，点击发出正确 key/authority/revision 请求。
- [x] 复用 `tools/can_gateway/tests/test_pc001_sink.py` 的 no-client drop、disconnect purge与 reconnect no-replay测试；不复制其完整并发/队列矩阵。
- [x] 若需要补 owner/API test，只覆盖 managed authority成功与断连不产生 authority reset/event，不扩大 HTTP permission scope。

## Phase 4 — Contract And Documentation Alignment

- [x] 更新 `.trellis/spec/backend/can-gateway-control.md`：TCP handshake absence/transient disconnect不重置 managed row override；session restart和真实 terminal fault边界保持。
- [x] 更新 `tools/can_gateway/README.md` 中 Godot-managed 三态说明和离线/重连行为。
- [x] 搜索并修正旧 task/design之外仍宣称“所有 managed transport disconnect 都回退”的现行文档；归档任务保留历史，不改写。

## Automated Validation

先运行快速、确定性的 owning tests：

```powershell
pixi run ruff check tools/can_gateway/gateway.py tools/can_gateway/tests/test_gateway_process.py
pixi run python -m unittest tools.can_gateway.tests.test_can_console
pixi run python -m unittest tools.can_gateway.tests.test_gateway_web
pixi run python -m unittest tools.can_gateway.tests.test_pc001_sink
pixi run python -m unittest tools.can_gateway.tests.test_gateway_process
```

前端仅运行相关快速测试；每个独立 PowerShell 进程先初始化 Node CLI：

```powershell
& 'C:\Users\rosatus\.codex\scripts\Initialize-NodeCli.ps1' -Require node
Set-Location tools/can_gateway/web
npm test -- App.test.tsx
npm run typecheck
```

实现稳定后只运行一次 Gateway 测试发现与必要 lint；不重复等价 gate：

```powershell
pixi run python -m unittest discover -s tools/can_gateway/tests
```

## Validation Budget And Exclusions

- 不启动 Godot 做视觉/场景测试；本修复责任边界可由真实 Gateway 子进程、TCP client 和 HTTP API确定性覆盖。
- 不运行浏览器截图矩阵、paired soak或长时间 cadence soak。
- 不构建 Windows/Linux/Godot发行包；若用户后续要求发行，再建立独立交付步骤。
- 若 focused process canary 暴露 flaky timing，优先改为事件/状态条件等待，不通过增加长 sleep或重复运行掩盖。

## Completion Gate

- [x] PRD AC1–AC7均有测试或明确现有证据映射。
- [x] managed no-client/断连/重连与 standalone断连语义分别通过。
- [x] PC001 no-replay、drop统计和 egress truth无回归。
- [x] spec、README和代码一致。
- [x] 用户已批准规划并运行 `task.py start` 进入实施。

## Verification Notes — 2026-09-01

- `pixi run ruff check tools/can_gateway/gateway.py tools/can_gateway/tests/test_gateway_process.py` passed.
- Focused Python suite (`test_can_console`, `test_gateway_web`, `test_pc001_sink`, `test_gateway_process`) passed: 33 tests.
- Focused React suite (`App.test.tsx`) passed: 8 tests; `npm run typecheck` passed.
- `pixi run verify` passed its project backend gate: Ruff, mypy, 185 backend pytest cases, provenance and standalone-path verification.
- The broader `tools/can_gateway/tests` discovery was attempted once and exposed one pre-existing/flaky `test_gateway_runtime.GatewayRuntimeCoreTest.test_console_runtime_events_are_coalesced_to_fifty_milliseconds` failure (expected 1 event, observed 0); it does not touch changed files and is not part of this task's focused gate.
- No Godot launch, browser visual test, or soak was performed.
- At the user's delivery request, the Windows frozen Gateway was rebuilt and copied to `godot/dist/windows/can_gateway`; both copies have SHA-256 `C33E831B687D421B95A98D37F2A910CF2D7CEE4D55A409E53C92CFE0B4723E26`. Both package manifests were regenerated and the frozen executable `--help` smoke passed. No Godot or Linux release was rebuilt.
