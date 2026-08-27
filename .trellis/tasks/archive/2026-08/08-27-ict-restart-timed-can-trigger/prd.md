# ICT endpoint restart and timed CAN trigger

## Goal

Improve the Godot/Python-side ICT controls without modifying the QML/ICT CAN
relay: make endpoint changes take effect predictably and provide a timed CAN
command through every currently active gateway output.

## Background

- The Python gateway is the PC001 TCP server and the unchanged ICT relay is its
  TCP client.
- The existing Godot panel can update the configured TCP host/port, but the
  endpoint is currently applied only on the next gateway spawn.
- The ICT control is a toggle. When active, one click disconnects; the following
  OFF-to-ON click reconnects.
- The gateway already supports simultaneous recording and ICT sinks.

## Requirements

### R1. Endpoint-aware ICT reconnect

- Preserve the current toggle semantics. Changing the endpoint while connected
  requires one click to disconnect and a following OFF-to-ON click to reconnect.
- On the OFF-to-ON action, compare the validated panel host/port with the
  endpoint used to start the current gateway.
- If the endpoints are equal, reuse the current gateway and do not restart it.
- If the endpoints differ, stop the current gateway, wait for it to release its
  process and ports, start a replacement with the requested endpoint, and only
  then request ICT connection.
- Invalid endpoint input must not stop or replace a healthy gateway.

### R2. Timed CAN trigger

- Add a non-toggle Godot UI button that triggers raw extended CAN ID
  `0x18FFF100`, DLC 8, payload `01 00 00 00 00 00 00 00`.
- One trigger starts immediately and emits at a nominal 50 Hz for 10 seconds
  (500 scheduled slots under uninterrupted operation).
- Pressing the button while a run is active restarts a single 10-second window
  from that click. Runs do not overlap, queue, or increase the 50 Hz rate.
- The frame is sent through every output active at each scheduled instant:
  recording output, ICT output, or both.
- The timer must not depend on Godot physics telemetry arriving at 50 Hz.

### R3. Compatibility and scope boundary

- Preserve the current Godot telemetry packet, PC001 handshake/batch framing,
  QML compatibility projection, and existing normal CAN schedules.
- Preserve the existing QML application and ICT CAN relay unchanged.
- Preserve the raw-ID boundary: CSV records `0x18FFF100`; PC001/SocketCAN adds
  `CAN_EFF_FLAG`, producing wire ID `0x98FFF100`.

## Acceptance Criteria

- [ ] An OFF-to-ON ICT request with an unchanged normalized endpoint does not
  replace the gateway process.
- [ ] An OFF-to-ON ICT request with a changed normalized endpoint replaces the
  gateway, releases the old listener, and accepts the unchanged relay on the new
  endpoint before ICT is reported active.
- [ ] Invalid host/port input leaves the current gateway and ICT state unchanged
  and produces an actionable UI diagnostic.
- [ ] One timed-button activation schedules 500 slots from `t=0` through
  `t=9.98s` at 20 ms intervals under uninterrupted virtual time.
- [ ] Re-triggering during an active run discards the previous remaining window
  and starts one new 500-slot schedule without overlapping output.
- [ ] Each emitted frame has raw ID `0x18FFF100`, DLC 8, and payload
  `01 00 00 00 00 00 00 00`.
- [ ] Recording-only, ICT-only, and simultaneous recording+ICT tests observe the
  same triggered frame through the active canonical sinks.
- [ ] CSV output uses ID `0x18FFF100`; TCP/SocketCAN packing uses wire ID
  `0x98FFF100` and preserves the exact payload.
- [ ] Timed scheduler tests use an injected/virtual monotonic clock and do not
  wait 10 real seconds.
- [ ] Existing Python gateway tests, focused Godot CAN tests, packaging smoke,
  and QML compatibility tests remain green.

## Out of Scope

- Changes to QML, GuideSystem, `socket_client_to_vcan`, or PC001 wire framing.
- Restarting or rebinding the gateway on every endpoint text edit.
- A second disconnect/reconnect button, queued timed runs, overlapping runs, or
  a separate timed-frame stop command.
- Turning the v1 control packet into a variable-length endpoint configuration
  protocol; endpoint changes remain supervised through local process arguments.
- Fixing the existing TCP pending-queue retention policy when no relay client is
  connected.
