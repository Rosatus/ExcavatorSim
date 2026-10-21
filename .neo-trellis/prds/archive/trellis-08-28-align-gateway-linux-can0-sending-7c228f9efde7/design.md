# Design — Align Gateway Linux CAN sending with can0

## 1. Boundaries

The change stays below the established `FrameSink.append(can_id, payload)` boundary. `emit_frames`, encoders, timed-frame definitions, scheduling, CSV construction, and PC001 framing are consumers or producers outside this task's modification authority.

```text
Godot Connect ICT
  → CTNC(ICT_START, seq)
  → Gateway inspect can0
      → ready: no privileged mutation
      → absent: result failure
      → unready/unverifiable: sudo -n fixed-helper
          → inspect → lock → down/configure/queue/up → verify
  → Gateway SocketCanSink bind(can0)
  → ICT result(seq, success/failure)
  → Godot connecting/connected/error state
  → existing FrameSink.append → existing pack_can_frame → socket.send
```

## 2. Physical CAN readiness

### 2.1 Inspection model

Add a can0-specific setup module that runs `ip -j -d link show dev can0` without a shell and parses JSON. It produces a typed snapshot containing presence, netdev state, `txqlen`, CAN bitrate/restart delay, and controller state when exposed.

A snapshot is ready only when it proves `UP`, `250000`, `100`, `1000`, and a controller state that is not stopped/bus-off. Missing or unparsable required fields are not considered ready.

Gateway performs an unprivileged inspection first: absent maps directly to `INTERFACE_MISSING`; ready skips the helper and binds; other states invoke the helper.

### 2.2 Fixed privileged helper

Build a second PyInstaller onefile executable from a small helper entry point that imports the same can0 inspection/configuration module. This avoids authorizing mutable Python source or a general interpreter through sudoers.

Installed contract:

```text
/usr/local/libexec/excavatorsim/can0-setup-helper   root:root 0755
/etc/sudoers.d/excavatorsim-can0                    root:root 0440
```

The helper accepts no arguments and fixes interface `can0`, bitrate `250000`, restart delay `100 ms`, and queue `1000`. It takes an exclusive `flock` under `/run/lock`, re-inspects, returns if ready, fails if missing, otherwise runs argument-vector subprocesses with no shell:

1. `ip link set can0 down`
2. `ip link set can0 type can bitrate 250000 restart-ms 100`
3. `ip link set can0 txqueuelen 1000`
4. `ip link set can0 up`
5. detailed post-verification

If failure occurs after down and the interface was originally UP, the helper makes a best-effort `ip link set can0 up` recovery while preserving the primary error. An originally DOWN interface remains DOWN on failure; Gateway re-inspects after helper success before binding.

Gateway invokes exactly `sudo -n /usr/local/libexec/excavatorsim/can0-setup-helper`. No `sudo -v`, askpass, shell interpolation, or runtime-controlled parameters are allowed.

### 2.3 Installation and distribution

Keep auditable sources under `tools/can_gateway/`. Extend `dist_linux.sh` to build/copy:

```text
dist/can_gateway_linux/
  gateway
  can0-setup-helper
  install_can0_helper.sh
  uninstall_can0_helper.sh
```

The administrator runs the installer once. It installs the helper atomically, derives or accepts the intended runtime account, writes a temporary exact-command `NOPASSWD` sudoers fragment, validates it with `visudo -cf`, then atomically installs it. The uninstaller removes only the helper and sudoers fragment; it does not down/delete `can0` or touch drivers.

## 3. Gateway SocketCAN lifecycle

- Rename/generalize vcan-only transport naming and diagnostics to SocketCAN/can0 while preserving `SocketCanSink` packing and send bytes.
- Linux Godot launch arguments explicitly select physical SocketCAN/can0; Windows remains TCP.
- On ICT_START, prepare before constructing/binding the socket. Emit success only after bind.
- ICT_STOP closes the active sink.
- A terminal send error disables the ICT sink, reports failure for the active request, and leaves unrelated CSV handling intact where the existing loop permits.
- Duplicate delivery of a finalized ICT_START sequence re-sends the cached result without reconfiguration/rebind. A new sequence while connected returns current success without cycling.

## 4. ICT result protocol

Preserve CTNC, CTNK, and CTND wire layouts. Add an independently identifiable packet on the existing acknowledgement UDP channel.

```text
ICT result: <IBBIHH + UTF-8 detail
magic u32 | version u8 | command u8 | request_seq u32 |
result_code u16 | detail_len u16 | detail bytes
```

The command is `CMD_ICT_START`; detail is capped at 160 UTF-8 bytes and strictly validated. `parse_control_packet` retains `(command, seq)` while existing `parse_control` remains a compatibility wrapper.

Stable result categories are: success, unsupported transport, can0 missing, helper/privilege unavailable, setup command failed, interface not ready after verification, socket open failure, bind failure, terminal send failure, and internal failure. Godot maps the stable code to user guidance and appends only sanitized short detail.

Godot state machine:

```text
disconnected
  └─ click → connecting(requested=true, active=false, pending_seq=N)
       ├─ matching success → connected(active=true, active_seq=N)
       ├─ matching failure → disconnected + visible error
       └─ timeout → disconnected + result-timeout error

connected
  ├─ stop → disconnected
  └─ active-seq terminal failure → disconnected + visible error
```

Mismatched/late results are ignored. The button uses active state for “Disconnect ICT” and pending state for “Connecting ICT”. Gateway restart/exit clears both. Old clients ignore the new packet; new clients time out safely against an old Gateway instead of claiming false success.

## 5. Error and operational behavior

Visible failures distinguish missing hardware/driver, helper missing, sudoers authorization missing, iproute2/setup failure, post-check mismatch, AF_CAN unavailable, bind failure, and terminal send failure.

The existing PC001 handshake bit remains untouched; Linux can0 transport readiness is carried only by the ICT result state.

## 6. Validation and rollback

Unit tests use injected runners and mock sockets without root/hardware. Godot tests inject acknowledgement datagrams. Existing CAN packing/golden/timed-frame/CSV/PC001 tests are mandatory non-regression gates.

Real-Linux validation is separate because WSL lacks `can0`: install helper, verify non-interactive sudo, capture detailed link state, connect ICT, and observe frames with `candump` or an external receiver.

Rollback uses the explicit uninstaller to remove the sudoers fragment and helper, restores the prior Gateway distribution, and does not delete/down `can0` or alter its driver.
