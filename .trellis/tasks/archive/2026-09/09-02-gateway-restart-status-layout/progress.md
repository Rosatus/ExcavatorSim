# Progress

## 2026-09-02 — Implementation complete, manual acceptance pending

- Godot 的 ICT toggle 已替换为 owned Gateway 启动/重启按钮；endpoint 只在验证后保存，
  STARTING/STOPPING/FAILED 由 bridge lifecycle 驱动。首次 heartbeat 前退出现在进入
  FAILED；无仍存活 owned PID 的重试直接 spawn，不向未知端点发送 shutdown。
- Gateway status 新增 nullable `godot_connected`。managed 模式只由合法 CTN1 receive
  time 驱动，2.5 秒超时；standalone 为 `null`。snapshot、runtime WebSocket delta、
  TypeScript decoder 与 React summary 已贯通。
- Web 运行摘要已删除 ICT 卡；Godot、PC001 与 transport 分别显示。CAN 表保持 50 ms
  ticker，采用九列固定布局、局部横向滚动及不换行表格数字。
- Web production assets 已重新构建；未构建任何发行包。

## Automated evidence

- Gateway: `193` tests passed, `2` environment skips.
- Ruff: affected Gateway Python files passed.
- React: `10` Vitest tests passed; ESLint、TypeScript、Vite production build passed.
- Godot 4.7.2 custom build: project parse、operator UI、PC001 indicator focused checks passed；
  `can_gateway_e2e_test.gd` 最终日志为 `PASS`，覆盖 exact owned-PID replacement、fresh
  heartbeat 与 PC001 reconnect。E2E 使用隔离 UDP/TCP/Web ports 和项目 Pixi Python。
- `git diff --check` passed；旧用户可见 ICT toggle 文案搜索为空。

## Known baseline

- Repository mypy currently reports 21 pre-existing errors across Gateway dependencies and
  platform-specific stubs (including `os.geteuid`, `fcntl`, `socket.AF_CAN` and existing
  untyped functions). Ruff and runtime tests cover this change; no mypy diagnostic points to
  the new `godot_connected` projection.
- The broad legacy `operator_ui_test.gd` still reports three unrelated model-switch/generation
  assertions. The new isolated Gateway restart UI test, the PC001 indicator test, project parse,
  and the real Gateway E2E all pass.

## Manual acceptance

- Confirm the Godot button starts/restarts the owned Gateway and leaves PC001 at waiting until
  a real handshake.
- Observe freshness transitions and narrow viewport scrolling in a real browser; verify the
  table no longer changes column widths.

## 2026-09-02 — User-requested Gateway test distributions

- Rebuilt `dist/can_gateway/gateway.exe` and `dist/can_gateway_linux/gateway` from the
  current dirty working tree; Linux also includes the rebuilt `can0-setup-helper`, installer,
  uninstaller and both adjacent DBC files.
- Replaced stale September 1 manifests with current `build-manifest.json` files. They
  intentionally record source commit `fef7e0f` and `git_tree_dirty=true` because acceptance
  precedes commit.
- Windows frozen smoke: standalone TCP ready, Web root HTTP 200, controlled shutdown exit 0.
- Linux ELF smoke under WSL: standalone TCP ready, `godot_connected=null`, Web root HTTP 200,
  controlled shutdown exit 0. Both Linux binaries were identified as x86-64 ELF.
- WSL non-interactive shell did not expose the user's FNM Node and lacked `uv`/`venv`.
  Build used explicit FNM Node 24.18.0 and installed user-scoped `uv 0.12.9` under
  `/home/rosatus/.local/bin`; no system apt packages were changed.
- Added `dist/can_gateway_windows-x86_64.zip` and
  `dist/can_gateway_linux-x86_64.tar.gz` for transfer. The Linux archive was staged under
  WSL so executables/install scripts are `0755` and DBC/manifest files are `0644`.
