# Technical design

## Boundaries

This is one integrated product-control feature with three owners:

1. Godot logical actions own keyboard and gamepad input semantics.
2. A presentation-only Godot HUD observes those actions without becoming motion
   authority or intercepting camera input.
3. Python PC001 owns physical handshake truth; an additive heartbeat flag
   projects that truth through the Godot bridge to a UI lamp.

The external QML relay, PC001 handshake bytes, CAN frames, model kinematics, and
gameplay authority remain unchanged.

## Input mapping

| Physical control | Key | Logical action | Operator meaning |
|---|---:|---|---|
| Left stick up | W | `motion_arm_positive` | arm out |
| Left stick left | A | `motion_swing_negative` | swing left |
| Left stick down | S | `motion_arm_negative` | arm in |
| Left stick right | D | `motion_swing_positive` | swing right |
| Right stick up | I | `motion_boom_positive` | boom down |
| Right stick left | J | `motion_bucket_negative` | bucket curl |
| Right stick down | K | `motion_boom_negative` | boom up |
| Right stick right | L | `motion_bucket_positive` | bucket dump |
| Left track forward/reverse | R / F | `track_left_forward/reverse` | left track |
| Right track forward/reverse | Y / H | `track_right_forward/reverse` | right track |

`MotionClient._ensure_input_actions()` will replace stale keyboard and joy-axis
events before installing exactly one canonical key and the existing
model-adjusted gamepad axis. Track setup already follows replacement semantics.
The four-axis vector order and model gamepad multipliers do not change.

## Control HUD

Add a reusable `ControlInputHUD` scene/script instantiated under `OperatorUI`:

- bottom-right anchors with a 16 px safe-area inset and a bounded size that fits
  1280x720;
- translucent dark `PanelContainer`, two directional joystick groups and two
  track-pedal groups;
- one named tile per logical action, containing the key and concise motion label;
- normal neutral styling and a high-contrast green active style;
- recursive `MOUSE_FILTER_IGNORE` so middle-drag orbit and wheel zoom pass
  through every descendant;
- per-frame semantic `Input.is_action_pressed()` observation. It reads every
  action separately rather than a resolved axis, so opposing held keys both
  remain highlighted even when the motion command resolves to zero.

The HUD is presentation-only: it never writes InputMap, axes, chassis commands,
or lifecycle state.

## ICT handshake data flow

```text
TCP accept -> send "who" -> receive "PC001" -> TcpPc001Sink stores client
  -> gateway heartbeat flag 0x04
  -> CanTelemetryBridge physical-handshake state + change signal
  -> OperatorUI red/green/neutral lamp beside ICT control
```

- Add a read-only `TcpPc001Sink.is_handshake_connected()` projection whose true
  condition is an accepted, currently stored client socket.
- Add `HEARTBEAT_FLAG_ICT_HANDSHAKE = 0x04` and an optional heartbeat builder
  argument. Packet magic, version, length, existing flags, and legacy parse
  helpers remain compatible.
- The gateway sets the bit only for a handshaken TCP PC001 sink. SocketCAN/vcan
  never sets it.
- `CanTelemetryBridge` stores the bit separately from `_ict_requested` and
  `_ict_active`, exposes a getter, and emits a change signal. It clears the
  projection on heartbeat expiry, spawn/restart, and teardown so stale state
  cannot survive a gateway generation change.
- `OperatorUI` renders:
  - green `已握手` when the Windows PC001 bit is true;
  - red `未握手`/`未连接` when Windows/TCP has no accepted client;
  - neutral `直连·无需握手` for Linux/vcan.
- The lamp deliberately remains green when forwarding is toggled off but the
  accepted TCP socket remains connected. The button remains the forwarding
  intent/activation control.

Old Godot ignores bit `0x04`. New Godot connected to an old gateway reads the
missing bit as false. No protocol version bump is required.

## Failure and freshness behavior

- Bad/partial handshake never stores a client and never turns the lamp green.
- Peer EOF/reset clears sink state; the next heartbeat projects red. Detection
  latency is bounded by the existing idle probe plus heartbeat cadence.
- TCP half-open state is limited by operating-system detection because PC001 has
  no client application heartbeat; this is explicitly not a business-health
  indicator.
- Gateway heartbeat expiry or endpoint restart clears green immediately at the
  bridge boundary, before a replacement client may handshake.
- Only one PC001 client is represented, matching the existing single-session
  listener.

## Rollback

The input constants/copy, HUD scene/script, and heartbeat bit are additive or
localized. Rollback removes the HUD instance and `0x04` projection and restores
the old physical keys; no persisted user data or external protocol migration is
needed.
