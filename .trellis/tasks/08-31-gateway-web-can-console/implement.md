# Gateway Web CAN Console Redesign — Implementation Plan

## Delivery Strategy

按“纯模型 → authority → egress → API → UI → 集成/打包”顺序实现。每阶段先通过 owning focused tests，再进入下一阶段；稳定后只运行一次较宽 gate。主代理负责代码修改与最终验证，子代理仅用于宽检索或独立核验。

## Phase 1 — Unified Message Model And Persistence

- [x] 新增 `tools/can_gateway/can_console.py`，定义 canonical SFF/EFF identity、authority enum、capability、descriptor、draft、snapshot DTO。
- [x] 将 operator DBC catalog 投影为 unified descriptors，不复制 DBC encode/decode/mux 逻辑。
- [x] 为 `0x18FFF000` slew 与 `0x256` travel 增加 thin adapter，直接复用现有 encoder/decoder；锁定 exact golden payload。
- [x] 将现有 DBC config schema 演进为 console schema 3，提供 schema 1/2 migration；恢复 selected off/custom 但永不恢复 arm。
- [x] 定义 portable JSON format/fingerprint、full replace candidate validator 与 atomic save；transport/theme/runtime fields 明确排除。
- [x] 单元测试：identity（SFF/EFF 不碰撞）、DBC/native round-trip、旧 schema migration、invalid/corrupt/unknown fingerprint 零副作用、atomic write failure、managed no-store。

Risk/rollback：先保持现有 `OperatorDbcRuntime` API 可用；新 model 未接入 owner loop 前不改变运行行为。任何 migration defect 可回退到 schema 2 reader，而不会改写原文件。

## Phase 2 — Per-ID Authority And Scheduler Integration

- [x] 在 Gateway owner loop 构造 console runtime：standalone restore + disarmed；godot-managed session defaults by capability。
- [x] 泛化/复用现有 `PeriodicDbcScheduler` 作为 unified custom scheduler，保持 per-message monotonic、1..100 integer、skip missed slots、single-entry rate reset。
- [x] 将 `emit_frames()` 输出在 `append_frame()` 前通过 authority gate；只 gate RTK/IMU/slew/travel，timed CAN 旁路。
- [x] 新增 owner commands：preview、message save、authority change、standalone custom start/stop、import。
- [x] authority 切换时原子更新 simulation gate/custom entry/snapshot；清除对应 SocketCAN pending old authority slot。
- [x] transport disconnect/reconfigure/terminal error：standalone disarm；managed custom overrides 回退 simulation/off；不自动恢复 stale custom。
- [x] 单元测试：同 ID 单一 authority、不同 ID 独立、managed defaults/override/reset、standalone restore-but-disarmed、global start/stop、purge、timed invariants、CSV/PC001/SocketCAN exact bytes。

Risk/rollback：最高风险是同 ID 双发。先用 fake sink + virtual clock 锁定 state transition，再接真实 sink。不得以 SocketCAN coalescing 测试代替 authority 测试。

## Phase 3 — Transport-Egress Tracker

- [x] 在 runtime 层新增 thread-safe per-identity tracker，保存 last payload 与最多 10 个 successful monotonic timestamps。
- [x] 复用 SocketCAN `sent` outcome callback；congestion/coalesced/submitted/terminal 不更新 freshness。
- [x] 将 `TcpPc001Sink._pending` 项从裸 bytes 扩充为带 metadata 的 frame item；保持 `_take_batch` 生成的 PC001 bytes 完全一致。
- [x] `sendall` 成功后回调 batch items；失败/断线不记录 egress。
- [x] server 计算 actual Hz 与 sample count；authority change 清空 rate samples但保留最后真实 payload/freshness。
- [x] 加入 50 ms 最多一次的 dirty-row batch event，禁止逐帧 JSONL/WebSocket。
- [x] 单元测试：10-sample rolling mean、warm-up null、authority reset、SocketCAN congestion不刷新、TCP success/failure/batch wire、event coalescing、bounded state。

Risk/rollback：PC001 wire 是硬边界。修改前后对 greeting、prefix、count、EFF ID、DLC、payload 做 byte-for-byte regression；callback 可单独移除且不影响 transport。

## Phase 4 — HTTP/WebSocket Contract And Permissions

- [x] 新增原子 `GET /api/v1/can-console`，一次取得 status、server monotonic anchor 和 unified rows。
- [x] 新增/迁移 row update、preview、authority、start/stop、export/import endpoints；全部采用 strict allowlist、64 KiB、revision/request-id 和 owner completion。
- [x] 将 managed 权限改为 endpoint capability matrix：仅 row authority/custom preview/save；transport/reload/arm/import/export 继续 403。
- [x] 扩展现有 `/api/v1/events` typed event，不新建 WebSocket；gap/reconnect 仍回完整 snapshot。
- [x] 保留旧 `/api/v1/dbc` contract 与 tests，避免无关兼容破坏。
- [x] API tests：standalone/managed × allowed/forbidden matrix、stale revision、invalid import、atomic snapshot、event replay/gap、no mutation on failure。

Risk/rollback：不能只在 React 隐藏权限。所有 forbidden behavior 必须由 Python API tests 证明 server-side 403。

## Phase 5 — React/Tailwind/shadcn Console

- [x] 更新 typed contract decoder/reducer；禁止 components 直接 cast untyped event detail。
- [x] 把旧 `DbcControl`/inline `MessageEditor` 拆成 row console、expand panel、authority segmented radio、Dialog editor、freshness cell、import/export controls。
- [x] 在 Dialog 中复用 values/payload 双向 debounced preview、exact-DLC/frequency validation、explicit Save 和 stale-response protection。
- [x] 实现共享 freshness ticker、server anchor 校准、format/color boundary；actual Hz 只展示 server projection。
- [x] 定义 light/dark CSS tokens、theme provider、system preference 与 localStorage；修正固定 dark-only surface（包括日志区）。
- [x] 保留 transport summary、load warning、event/log download；standalone 显示 global Start/Stop 和 import/export，managed 按 capability 显示 row controls。
- [x] 响应式：桌面宽表、窄屏横向滚动、sticky header/identity；保证 keyboard focus、Dialog trap、radio labels 和 aria-live errors。
- [x] Vitest/jsdom：theme、row expand、mode capability、modal round-trip、save、global arm、managed override、freshness boundaries、event delta/gap/reconnect、import/export errors。

Risk/rollback：先让新组件消费 fixture/typed snapshot，再切换真实 API。旧页面在 Phase 4 完成前保留，避免 backend/frontend 同时不可运行。

## Phase 6 — Integration, Specs, Packaging And Handoff

- [x] 更新 `tools/can_gateway/README.md`：三态、egress 语义、managed capability、arm safety、JSON format、theme/URL。
- [x] 更新 `.trellis/spec/backend/can-gateway-control.md`，记录 unified authority、native adapters、egress tracker、API permissions、persistence/fault contracts。
- [x] 如 Godot 文件无需修改，仅保留现有 `--mode godot-managed` argv regression；若实施发现必须编辑 Godot scene/script，先使用 godot-ai MCP 做结构检查/开发，并按 frontend spec 只增加最窄 deterministic test。
- [x] 运行一次真实 Gateway process canary：HTTP snapshot → WS event → custom send → PC001 payload → stop；不建立浏览器 E2E runner。
- [ ] 稳定且提交后仅运行一次 Windows/Linux unified release build，确认 React bundle、Gateway frozen resources、DBC/native code、manifest 和 Godot adjacent Gateway 均更新。
- [x] 最终独立 review：检查同 ID 单 authority、managed permission、PC001 wire、no auto-arm、timed exclusion、event rate bound 与 spec drift。

## Agent Automated Validation

实施中使用最窄命令；以下为预期 gate，按实际改动文件收窄：

```powershell
pixi run ruff check tools/can_gateway
pixi run python -m unittest tools.can_gateway.tests.test_dbc_engine
pixi run python -m unittest tools.can_gateway.tests.test_gateway_runtime
pixi run python -m unittest tools.can_gateway.tests.test_gateway_web
pixi run python -m unittest tools.can_gateway.tests.test_pc001_sink
pixi run python -m unittest tools.can_gateway.tests.test_gateway
```

前端命令在同一 non-login PowerShell 进程初始化 Node：

```powershell
& 'C:\Users\rosatus\.codex\scripts\Initialize-NodeCli.ps1' -Require node
Set-Location tools/can_gateway/web
npm run lint
npm run typecheck
npm test
npm run build
```

稳定后一次：

```powershell
pixi run python -m unittest discover -s tools/can_gateway/tests
pixi run verify
```

若 `pixi run verify` 已包含并通过同 revision 的 focused suite，不重复运行等价 gate。日志只保留失败摘要；不运行视觉 screenshot matrix、Godot full matrix 或 soak。

## Human Manual Acceptance

实现交付时提供最小步骤，以下保持 pending，不能由 Agent 声称通过：

1. Standalone：打开 `127.0.0.1:29777`，检查桌面/窄窗口布局、明暗主题、展开物理量和 Dialog 可读性。
2. Standalone：选择两条 custom、分别编辑 values/payload 和频率；确认未点全局 Start 前不发，Start 后 expected/actual/freshness变化，Stop 后停止。
3. Standalone：刷新与重启后配置仍在但不自动发；导出、修改、导入并确认完整恢复。
4. Godot：启动后所有 simulation-capable 行为 simulation；将一条 off、一条 custom，确认只有对应 ID 改变；重启 Godot 后恢复全 simulation。
5. 在可用 Windows PC001 与 Linux can0 各做一次代表性检查，确认平台 transport、payload 与新鲜度说明符合实际操作认知。

## Completion Gate

- [ ] PRD AC1–AC9 均有对应自动证据或明确 pending human evidence。
- [x] 没有修改 CAN encoding/timed/transport wire contracts。
- [x] 新 config/import 失败路径零副作用；restart 不 auto-arm。
- [x] 新 WebSocket event 有界、批量、可从 gap 恢复。
- [ ] Specs、README、source tests 和最终 dist 对齐。

## Implementation Verification — 2026-08-31

- Gateway focused lint 通过；Gateway test discovery 共运行 183 项并通过（2 skipped），随后新增的导入写盘失败与 SFF/EFF purge 回归也在 focused suite 通过。
- React Vitest 8 passed，TypeScript typecheck、ESLint 与 Vite production build 通过；构建产物已同步到 `resources/web`。
- 单进程 canary 已覆盖原子 console snapshot、既有 WebSocket event、custom authority/edit/start、PC001 exact payload 与 stop。
- `pixi run verify` 的 backend lint/typecheck 通过，185 个 backend pytest 全部运行到 100%；pytest 在 Windows 清理用户临时目录 `pytest-current` 时因既有 ACL 返回 `WinError 5`，因此命令最终退出 1。按测试预算不重复宽 gate。
- 尚待：人工浏览器/真实 Windows PC001/Linux can0 验收；提交后的 unified release build、manifest 与最终 dist 对齐。
- Windows 验收包已于 2026-08-31 单独构建至 `dist/can_gateway`：`gateway.exe` SHA-256 为 `40d90423bef2c522e2c7ffb3360f9f4f95debdcc4a72edfd39d2dbb890f01db8`，内置 32 帧 CSV smoke 通过。该验收 manifest 明确标记 `git_tree_dirty=true`，不替代验收、提交后的统一正式发行构建。
