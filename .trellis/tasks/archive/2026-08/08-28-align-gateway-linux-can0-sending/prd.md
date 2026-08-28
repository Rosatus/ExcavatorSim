# Align Gateway Linux CAN sending with can0

## Goal

Update the previously developed Gateway Linux distribution so that **Connect ICT** sends already-constructed CAN frames through a real `can0` interface aligned with the inspected `setup_can0.sh` contract, instead of the existing vcan-specific path.

This change is limited to the Linux ICT transmission boundary. CAN-frame construction, payload semantics, scheduling, and unrelated Gateway behavior must remain unchanged.

## Background and Confirmed Facts

- The supplied literal reference path does not exist in this workspace. The inspected equivalent is `E:\projects\dev_arch2.0_36b5586c\tools\can_replay\setup_can0.sh`, with `setup_vcan.sh` beside it.
- The archived task `08-26-linux-gateway-vcan-ict` established the `FrameSink` boundary and explicitly excluded real CAN hardware.
- `SocketCanSink` already uses generic Linux `AF_CAN` / `SOCK_RAW` / `CAN_RAW`, binds to the selected interface, and sends through `sock.send(pack_can_frame(...))` (`tools/can_gateway/sinks.py:64-93`). The socket data path can use `can0` without changing frame construction.
- The remaining vcan coupling is in names, defaults, setup checks, startup selection, and diagnostics: `require_vcan_interface`, `_open_vcan`, `--sink vcan`, `--interface vcan0`, and `--setup-vcan` (`tools/can_gateway/sinks.py:67-90`, `tools/can_gateway/gateway.py:274-287,377-406`).
- The current Godot Linux launcher supplies no `--sink`, so it falls back to CSV; only Windows explicitly selects its ICT transport (`godot/client/scripts/can_telemetry_bridge.gd:275-289`, `tools/can_gateway/gateway.py:377-381`).
- The reference physical-CAN contract uses `can0`, bitrate `250000`, restart delay `100 ms`, and TX queue length `1000`. The interface must already have been created by the hardware driver; configuration is `down` → CAN bitrate/restart → TX queue → `up` → verification (`E:\projects\dev_arch2.0_36b5586c\tools\can_replay\vcan_setup.py:86-129`).
- Interface existence alone does not prove readiness. An existing `can0` can be down, use different parameters, or have a stopped/bus-off controller.
- A missing driver-created `can0` cannot be repaired with `ip link set`; it is a hardware/driver prerequisite failure and must not trigger virtual-interface creation.
- Godot spawns Gateway without an interactive console. Normal operation cannot depend on `sudo -v` or an invisible password prompt.
- The current control plane has no ICT-start result message. Setup/bind failures only reach Gateway stderr while Godot marks ICT requested immediately, so an explicit result is required to avoid false success.
- Existing CAN ID/DLC/payload packing and extended-ID/EFF behavior are covered by tests and form a non-regression boundary.

## Requirements

### R1 — Physical CAN readiness

- Linux **Connect ICT** must automatically prepare and bind the fixed physical interface `can0`; no normal-operation `--setup-can` step is required.
- Ready-to-skip means all of the following are proven by detailed link inspection: interface exists, netdev is UP, bitrate is `250000`, restart delay is `100 ms`, TX queue length is `1000`, and CAN controller state is neither stopped nor bus-off.
- If `can0` is verified ready, do not cycle it; proceed directly to SocketCAN bind.
- If `can0` exists but is not ready or cannot be fully verified, apply the reference-aligned sequence before bind: `down` → configure bitrate/restart delay → set TX queue length → `up` → detailed post-verification.
- If `can0` does not exist, fail without trying to create it and report that the USB-CAN device or driver must be checked.
- Setup, verification, bind, and terminal send failures must produce stable, actionable can0/SocketCAN diagnostics rather than vcan- or WSL-specific instructions.

### R2 — Restricted unattended privilege

- The Linux distribution must include an administrator-run installer for a fixed-purpose, root-owned CAN setup helper and a tightly scoped `sudoers` authorization.
- The helper must accept no user-controlled interface, bitrate, restart, queue, path, or shell command. Its contract is fixed to `can0 / 250000 / 100 ms / 1000`.
- Gateway may invoke only the installed helper's fixed absolute path through non-interactive `sudo -n`; it must never attempt interactive authentication or wait for a hidden prompt.
- The helper and its parent installation directory must not be writable by the runtime user. Installation must validate the sudoers fragment before activation.
- Helper absence or missing authorization must fail fast with installation guidance.

### R3 — ICT result and UI truthfulness

- Gateway must send a sequence-correlated ICT-start result through the existing acknowledgement channel after preparation and bind complete, or on failure.
- Godot must distinguish connecting, connected, and failed states. It may display ICT connected only after a matching success result.
- Setup/bind/send failure must clear the pending/connected state and expose a stable error category plus a short actionable detail.
- Late or mismatched results must not change current ICT state. Repeated handling of the same start request must not reconfigure or rebind unnecessarily.

### R4 — Scope preservation

- Preserve CAN identifiers, DLC, payload construction, byte order, scaling, encoding, scheduling, timed-frame definitions, and EFF-flag behavior.
- Preserve CSV output, RECORD control, Windows PC001/TCP transport, QML handshake semantics, and existing ICT START/STOP intent.
- Preserve unrelated Linux Gateway distribution behavior.

## Acceptance Criteria

- [ ] The Linux-distributed Gateway's ICT path selects physical SocketCAN `can0` and sends its existing packed frames without changing frame contents.
- [ ] A verified-ready `can0` is not cycled and is bound directly.
- [ ] A present but unready/unverifiable `can0` is configured in the required order and passes detailed post-verification before bind.
- [ ] An absent `can0` is not created; the UI reports the USB-CAN/driver prerequisite.
- [ ] The normal Connect ICT path never waits for an interactive sudo prompt.
- [ ] The root helper is fixed-purpose, root-owned after installation, invoked by fixed absolute path, and authorized through a validated least-privilege sudoers entry.
- [ ] Missing helper, missing authorization, setup command failure, post-verification failure, socket open/bind failure, and terminal send failure produce distinct stable results and actionable UI text.
- [ ] The UI shows connecting while pending, connected only after the matching success result, and returns to disconnected on failure or stop.
- [ ] Duplicate/late ICT results do not cause repeated configuration or stale UI transitions.
- [ ] Existing CAN construction golden behavior, extended-ID/EFF packing, timed ICT frames, CSV output, and Windows PC001/TCP tests remain unchanged and pass.
- [ ] Automated tests cover readiness decisions, privileged invocation boundaries, result codec/state transitions, and representative failures; a real-Linux hardware procedure verifies final `can0` parameters and observed transmission.

## Key Decisions

- Runtime behavior is automatic on **Connect ICT**; there is no required manual setup command in the normal workflow.
- Privilege is provisioned once at installation through a fixed helper plus scoped sudoers entry, as approved by the user.
- Existing and UP is not sufficient to skip configuration; all target parameters and controller usability must be verified.
- `can0` absence is a hard hardware/driver error, not an instruction to create an interface.
- Success/failure is acknowledged explicitly; UI request state is not treated as transport-ready state.

## Out of Scope

- CAN-frame identifier, DLC, payload, byte-order, scaling, encoding, signal-construction, or scheduling changes.
- CAN receive behavior.
- Changes to timed-frame definitions or ICT command intent.
- Windows PC001/TCP transport, QML protocol/handshake semantics, or the ICT indicator's handshake meaning.
- General Gateway refactoring, a general-purpose privilege framework, a permanent daemon, or boot-time CAN management.
- Creating `can0`, installing hardware drivers, or modifying the external reference repository.

## Risks and Deferred Validation

- Reconfiguring a mismatched active `can0` necessarily performs down/up and can briefly interrupt other bus users; readiness verification avoids this when already compliant.
- Hardware removal or another network manager can race inspection/configuration. Command failures and post-verification must be authoritative; the helper should serialize its own setup transaction and restore UP only when the interface was originally UP, without hiding the primary error.
- WSL on this machine has no real `can0`; real hardware transmission, controller-state behavior, and target iproute2 JSON fields require final validation on the target Linux host.
- Target Linux must provide SocketCAN, `iproute2`, `sudo`, the USB-CAN driver, and the administrator-installed helper authorization.
