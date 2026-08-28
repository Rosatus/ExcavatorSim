# Implementation Plan — Align Gateway Linux CAN sending with can0

## 1. Preserve baselines

- [x] Record focused Python and Godot baseline results before editing.
- [x] Confirm frame-packing/EFF, timed-frame, CSV, and Windows PC001 tests/fixtures are the construction and compatibility guardrails.
- [x] Do not edit encoders, frame definitions, timed payload constants, scheduling math, QML protocol, or PC001 framing.

## 2. Implement testable can0 readiness logic

- [x] Add typed parsing of `ip -j -d link show dev can0` with injected runner support.
- [x] Classify absent, ready, down, parameter mismatch, stopped/bus-off, and unverifiable output.
- [x] Add the fixed configuration transaction and post-verification, including serialization and best-effort recovery after post-down failure.
- [x] Test exact command order and prove that no path creates `can0` or accepts runtime-controlled CAN parameters.

## 3. Add and secure the privileged helper distribution

- [x] Add the no-argument helper entry point using shared can0 setup logic.
- [x] Extend `tools/can_gateway/dist_linux.sh` to build both ELF onefiles and include installer/uninstaller assets.
- [x] Add administrator-run install/uninstall scripts for the fixed `/usr/local/libexec/excavatorsim/can0-setup-helper` path.
- [x] Install as root-owned/non-user-writable; generate exact-command NOPASSWD sudoers; validate with `visudo -cf` before activation.
- [x] Ensure uninstall removes only owned helper/sudoers artifacts and never changes device/driver state.
- [x] Document prerequisites and remediation for missing helper/authorization.

## 4. Convert Linux ICT transport to can0 preparation

- [x] Generalize `SocketCanSink` names/checks/diagnostics without changing `pack_can_frame` or `append` wire bytes.
- [x] Inspect first, call only `sudo -n <fixed-helper>` when needed, verify again, then bind.
- [x] Make Godot Linux spawn select physical SocketCAN/can0 explicitly; retain Windows TCP arguments.
- [x] Preserve ICT STOP, CSV coexistence, timed-frame fan-out, and non-Linux behavior.
- [x] Convert terminal send failure into an ICT transport failure without changing frame construction.

## 5. Add sequence-correlated ICT results

- [x] Preserve CTNC sequence in a new parser while retaining the old parser API.
- [x] Add bounded ICT result codec and stable result constants on the acknowledgement channel.
- [x] Emit one final result for each new ICT_START sequence and cache/resend duplicates without repeated setup.
- [x] Map readiness/helper/socket/bind/send failures to stable categories and sanitized details.
- [x] Test codec validation, sequences, duplicates, success, and representative failures.

## 6. Make Godot/UI reflect acknowledged readiness

- [x] Add disconnected/connecting/connected state with pending and active sequences.
- [x] Accept only matching results, ignore late/mismatched packets, and add deterministic timeout behavior.
- [x] Show connecting while pending and disconnect only after success; reset and expose actionable text on failure.
- [x] Keep PC001 handshake indicator semantics unchanged.
- [x] Add/register a focused standalone Godot ICT-result/state test; update affected E2E assertions to wait for acknowledgement.

## 7. Documentation and generated distribution

- [x] Replace Linux vcan instructions with can0 prerequisites, admin install/uninstall, automatic Connect ICT behavior, and diagnostics.
- [x] Document that the helper does not create `can0`, install drivers, or receive CAN.
- [x] Build and verify both Linux executables and distribution assets.

## 8. Verification gates

- [x] Run focused Python tests for can0 setup, sinks, Gateway results, frame packing, timed ICT, CSV, and PC001.
- [x] Run focused Godot ICT protocol/state/E2E tests and the standalone matrix, accounting only for documented baseline failures.
- [x] Run Python compile/import and Linux packaging smoke checks.
- [x] Review the diff for forbidden CAN construction, scheduling, Windows PC001, QML handshake, or receive changes.
- [ ] On target Linux with exclusive USB-CAN access, verify ready/no-cycle, mismatch auto-configuration, missing hardware/authorization errors, non-interactive sudo, and observed SocketCAN frames matching existing packing.

## Rollback Points

- Do not enable Linux can0 spawn by default until protocol/setup tests pass.
- Do not install sudoers until `visudo -cf` passes on the staged fragment.
- If target validation fails, run the uninstaller, restore the previous Gateway package, and leave `can0`/driver state intact.
