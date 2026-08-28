# Implementation Plan — Gateway React console and distributions

## 1. Frontend foundation

- [ ] Scaffold React/TypeScript/Vite with Tailwind and selected shadcn source
  components; commit package lock and deterministic build/test commands.
- [ ] Add typed API client, revision/error handling, status/catalog bootstrap,
  WebSocket sequence reconnect, and offline/gap state.
- [ ] Add shared Python/TypeScript contract fixtures to prevent DTO drift.

## 2. Operator console

- [ ] Build status cards and managed-mode read-only status/log experience.
- [ ] Build platform-specific standalone transport control with confirmation,
  progress, failure, disarm, and refresh behavior.
- [ ] Build DBC source/message table, signal editor, generated-default and
  conflict notices, strict validation preview, per-message Hz, load display,
  reload, and explicit start/stop.
- [ ] Build bounded aggregate log view and current/all-history downloads.

## 3. Approved assets and provenance

- [ ] Recompute/verify source DBC hashes and copy them byte-for-byte into bundled
  resources and staged executable-adjacent `dbc/` directories.
- [ ] Record both project-owner-approved DBCs in repository provenance and add
  tests that packaged bytes match the approved hashes.

## 4. Packaging integration

- [ ] Update Windows and Linux build scripts to build static assets and fail on
  missing/stale output.
- [ ] Include `aiohttp`, `cantools`, `platformdirs`, Web resources, and DBC
  resources in both PyInstaller outputs.
- [ ] Preserve the Linux can0 helper/install/uninstall assets and update usage
  documentation for URL, modes, DBC drop-in, logs, and Node-free target use.

## 5. Verification

- [ ] Run frontend typecheck, lint, production build, and component tests.
- [ ] Run managed/standalone/platform API-to-UI integration tests, including
  403/409/validation/offline/event-gap cases.
- [ ] Smoke test production static routing and log downloads in a browser.
- [ ] Build/inspect Windows and Linux packages and test on Node-free targets.
- [ ] Run Godot managed-launch and Gateway regression suites.
