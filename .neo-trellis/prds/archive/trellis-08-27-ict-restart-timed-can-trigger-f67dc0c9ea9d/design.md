# Design

## Boundaries and authority

- `CanTelemetryBridge` owns the locally spawned gateway process, desired ICT
  endpoint, restart sequencing, and Godot control-packet transmission.
- `OperatorUI` owns input validation feedback and button presentation, but does
  not directly supervise processes.
- The Python gateway owns the timed CAN schedule and canonical sink fan-out.
- QML, GuideSystem, the existing relay client, PC001 framing, and normal
  pose-to-CAN projection remain unchanged.

## Endpoint-aware restart

### State

Extend `CanTelemetryBridge` with separately observable values for:

- desired normalized `tcp_host` / `tcp_port`;
- endpoint committed to the current successfully spawned child;
- child PID and lifecycle state (`offline`, `starting`, `online`, `stopping`,
  `restarting`);
- pending desired ICT-active state;
- restart deadline and the exact child PID eligible for forced termination.

Endpoint equality compares normalized host text and validated integer port. The
spawned endpoint is committed only after `OS.create_process()` returns a valid
PID. Invalid panel values never mutate the desired endpoint.

### OFF-to-ON flow

1. `OperatorUI` validates and submits the panel endpoint, then requests ICT on.
2. If the current child is online and its endpoint matches, send `ICT_START`
   without a restart.
3. If no live child exists, spawn with the desired endpoint and defer
   `ICT_START` until a fresh heartbeat arrives.
4. If a live child uses a different endpoint, retain `desired_ict_active=true`,
   send `CMD_SHUTDOWN`, and enter `restarting`.
5. Poll only the recorded child PID with `OS.is_process_running()`. After a
   bounded grace period, `OS.kill()` may terminate that exact owned child; never
   scan or kill by port/name.
6. Once the old PID is confirmed dead, drain queued heartbeat packets, reset
   heartbeat freshness, spawn the replacement, and wait for a post-spawn
   heartbeat.
7. Send `ICT_START` and report ICT active only after that fresh heartbeat.

Failure to spawn, bind, or receive a fresh heartbeat leaves ICT inactive and
surfaces an actionable status. It does not loop indefinitely. An OFF request
during restart cancels the pending `ICT_START` but still lets the already-started
process transition complete safely.

The Windows bundled executable and Python fallback must share one argument
builder so both receive `--sink tcp --tcp-host ... --tcp-port ...`; non-Windows
behavior stays unchanged unless already configured otherwise.

## Timed CAN command

Add `CMD_TIMED_CAN_START = 6` to both mirrors of the existing v1 control enum.
The packet remains 12 bytes and keeps protocol version 1. Older commands retain
their byte representation.

The Godot UI adds one ordinary button, available for repeat clicks. When the
gateway is offline, clicking produces a warning and sends nothing. Otherwise it
sends command 6; no CAN bytes are generated in Godot.

## Python timed scheduler

Introduce a small pure timed-burst state object driven by injected monotonic
time:

- constants: raw ID `0x18FFF100`, payload eight bytes, period `20 ms`, duration
  `10 s`, 500 nominal slots;
- `trigger(now)` replaces any active schedule and makes slot zero immediately
  due;
- `service(now, sinks)` emits due work without depending on telemetry samples;
- completion clears the active state; gateway shutdown discards it.

The gateway loop computes its receive timeout from the earlier of the normal
poll bound and the next timed deadline, then services the timed scheduler after
control handling and on receive timeout. Normal operation emits slots at
`t=0, 0.02, ..., 9.98`. A delayed loop does not create overlapping schedules or
raise the configured rate; missed wall-time slots are not released as an
unbounded catch-up burst.

For every actual emission, call `active_sinks()` at that instant and append the
same raw `(can_id, payload)` to each returned sink. Thus recording-only,
ICT-only, and simultaneous modes share the existing behavior. CSV sees the raw
ID; TCP/vcan packers add the EFF flag.

## Compatibility and failure behavior

- The relay continues to connect as the PC001 client and sees no protocol
  change.
- The QML compatibility mapper and normal family `FrameScheduler` are untouched.
- Command 6 is additive inside control v1; coordinated Godot/gateway packaging
  is required for the new button to work.
- Restart uses only the exact PID returned by this bridge, satisfying the
  no-unverified-process-cleanup boundary.
- The existing TCP no-client pending-queue behavior is documented as a risk but
  is not changed in this task.

## Rollback

The change is localized to one additive command, one UI control, the bridge
lifecycle state, and the gateway timed state. Reverting those files restores the
prior endpoint and output behavior without any QML/relay migration or persisted
data conversion.
