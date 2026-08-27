# Excavator controls HUD and ICT handshake indicator

## Goal

Make keyboard operation resemble a two-joystick excavator control station,
surface the mapping in a responsive in-game HUD, and show whether the ICT
gateway has completed its client handshake rather than merely whether ICT was
requested.

## Background

- `W/A/S/D` shall represent the four directions of the left joystick.
- `I/J/K/L` shall represent the four directions of the right joystick.
- `R/F` shall drive the left track forward/backward.
- `Y/H` shall drive the right track forward/backward.
- The current working tree contains separate, pre-existing QML compatibility
  profile edits; this task must not overwrite or silently include them.
- The product uses the ISO excavator pattern and the fixed logical order
  `(swing, boom, arm, bucket)`. The requested layout therefore maps to:
  `W/S = arm out/in`, `A/D = swing left/right`, `I/K = boom down/up`, and
  `J/L = bucket curl/dump`.
- Product camera controls do not use the requested keys. A separate demo scene
  uses WASD, but it is not part of the product main scene.
- The PC001 server's authoritative handshake transition occurs only after it
  sends `who`, receives `PC001`, and stores the accepted client socket. Current
  Godot ICT requested/active state and gateway heartbeat do not prove this.

## Requirements

- **R1 — Keyboard layout:** replace only the physical keyboard bindings with
  the requested two-stick/track layout while preserving the existing logical
  ISO excavator actions and all existing gamepad bindings.
- **R2 — Canonical InputMap:** each product action owns exactly one current
  keyboard event so old runtime mappings cannot remain active after reload or
  model refresh.
- **R3 — Control HUD:** add a semi-transparent, lower-right HUD showing both
  joystick direction pads and both track pedals with their keys and motion
  meanings. It must remain readable at the supported minimum viewport and must
  not intercept mouse camera controls.
- **R4 — Held-state feedback:** highlight every held semantic action. Opposing
  directions may resolve to zero motion, but both held controls remain visibly
  highlighted; independent actions may highlight simultaneously.
- **R5 — ICT handshake truth:** add a red/green physical PC001 handshake lamp
  beside the existing ICT control. Only a successfully accepted `who/PC001`
  client socket may turn it green. Gateway startup, heartbeat, ICT request, and
  forwarding activation alone cannot do so.
- **R6 — State separation:** the lamp reports the physical client handshake
  independently of CAN forwarding. If forwarding is toggled off while the
  client socket remains handshaken, the lamp remains green. Linux/vcan mode,
  which has no PC001 TCP handshake, displays a neutral not-applicable state.
- **R7 — Compatibility:** preserve the unchanged QML-side CAN relay, the PC001
  byte stream, the 16-byte heartbeat size, protocol version 1, CAN pose
  semantics, and gameplay authority boundaries. The handshake state may use an
  additive heartbeat flag ignored by older consumers.

## Acceptance Criteria

- [x] **AC1:** exact mappings are `W/S = arm out/in`, `A/D = swing left/right`,
  `I/K = boom down/up`, `J/L = bucket curl/dump`, `R/F = left track
  forward/reverse`, and `Y/H = right track forward/reverse`.
- [x] **AC2:** legacy product keyboard bindings are absent after action setup;
  model-specific gamepad direction profiles and the `(swing, boom, arm,
  bucket)` vector order are unchanged.
- [x] **AC3:** the HUD stays inside 1280×720 and 1920×1080 viewports, has a
  translucent background, describes all twelve keys, and all descendant
  controls ignore mouse input.
- [x] **AC4:** press/release changes the matching visual state; two independent
  keys and both directions of one opposing pair can be highlighted together.
- [x] **AC5:** on Windows/TCP the lamp is red before handshake, green after the
  server accepts `PC001`, red after detected peer disconnect or gateway
  restart, and green after a later successful reconnection.
- [x] **AC6:** toggling forwarding off does not turn a still-handshaken socket
  red; Linux/vcan renders a neutral not-applicable indicator.
- [x] **AC7:** heartbeat packets remain protocol-v1 16-byte packets, old flag
  meanings remain unchanged, and the external relay handshake is untouched.
- [x] **AC8:** focused Python protocol/sink tests, Godot input/HUD tests, real
  gateway handshake E2E, and the standalone matrix pass without mixing in the
  pre-existing QML profile working-tree changes.

## Out of Scope

- Modifying the external QML model or QML-side CAN relay behavior.
- Changing excavator kinematics or CAN pose semantics.
- Adding gamepad hardware support unless it is required to preserve an existing
  action abstraction.
- Treating a TCP half-open connection as unhealthy before the operating system
  reports EOF/reset; PC001 has no application-level client heartbeat.
- Supporting multiple simultaneous PC001 clients or changing the current
  single-client listener/session policy.
