# Gateway Web runtime core and platform transport control

## Goal

Establish the safe runtime/control foundation required by the Gateway Web
console: explicit modes, a loopback HTTP API, one-owner command execution,
immutable status, bounded persistent logs, and race-free platform transport
lifecycle.

## Requirements

- Add explicit `standalone` and `godot-managed` modes; update Godot to pass the
  latter without changing Windows-TCP/Linux-can0 selection.
- Start an `aiohttp` service at `127.0.0.1:29777` by default, support
  `--web-port`, fail startup on bind conflict, and support standalone-only
  `--open-browser` after readiness.
- Keep the Gateway core as the only CAN sender and transport mutator. Web
  handlers submit typed revision-aware commands and read immutable snapshots.
- Enforce managed-mode read-only and platform-fixed transport capability in the
  API, not only in the UI.
- On Windows standalone, allow explicit PC001 endpoint rebind with
  disarm/disconnect/close/bind semantics and persist only a successful endpoint.
- Make the PC001 service thread the only socket writer. Drop/count frames while
  no valid client handshake exists and eliminate unbounded/stale pending data.
- On Linux standalone, expose status and confirmed fixed can0 restart; normal
  startup preserves ready/no-cycle behavior, while restart always invokes the
  fixed down/configure/queue/up/post-check contract.
- Add sequence-addressed bounded live events plus asynchronous JSONL logging in
  the per-user log directory, rotating five approximately 20 MB files.
- Aggregate high-rate message sends in one-second windows; do not synchronously
  write disk or stream one event per frame from the CAN loop.
- Provide current/all-log downloads without backpressuring the Gateway core.

## Acceptance Criteria

- [ ] Loopback-only service, deterministic port override, fatal bind conflict,
  and browser-open policy are covered by tests.
- [ ] Managed mutations and wrong-platform transport calls receive stable API
  errors even when invoked without the React UI.
- [ ] Web request threads cannot directly call sinks or the can0 helper.
- [ ] PC001 writes never interleave, disconnected frames are bounded/dropped,
  handshake loss is observable, and existing framing/handshake tests pass.
- [ ] Windows rebind and Linux restart expose explicit progress/failure states,
  disarm first, and never auto-resume.
- [ ] Status revisions and command preconditions prevent stale browser writes.
- [ ] Live and persistent logs remain bounded under 27 messages at 50 Hz and
  survive restart; current and retained-history downloads work.
- [ ] Existing UDP, CSV, timed-frame, ICT, SocketCAN, and Godot lifecycle tests
  remain compatible.

## Out of Scope

- DBC parsing, signal editing, scheduling, or load estimation.
- React views beyond a minimal static/API smoke fixture.
- Any new transport type or remote Web access.
