# Design — Physical CAN PC001 bridge

## Boundaries and data flow

The TCP reader parses complete PC001 batches and submits raw 16-byte CAN frames
with their integer channel to a physical SocketCAN egress scheduler. The reader
and sender run as separate asyncio tasks on one event loop. SocketCAN service
never blocks the reader.

The egress owns one non-blocking CAN_RAW socket per mapped interface. Pending
state is keyed by `(interface, full transport can_id)` so standard and extended
identities remain distinct. Each key has one latest slot. Per-channel/ID round
robin and a finite syscall budget prevent starvation and busy loops.

On `ENOBUFS`, `EAGAIN`, or `EWOULDBLOCK`, the attempted occurrence is dropped,
the bridge remains connected, and the sender yields before later service.
Other send failures are terminal. Disconnect cancels service and purges pending
state so no frame escapes a prior TCP session.

## Physical interface preparation

The legacy `setup_can0.sh` launches the physical bridge with the fixed mapping
`ch0=can1`, `ch2=can4`, `ch3=can3`. Startup verifies every interface before
connecting and applies only `ip link set dev <interface> txqueuelen 10` through
the existing privilege mechanism. It never changes bitrate or link state.

Virtual-CAN defaults remain `ch2=vcan4`, `ch3=vcan3`; physical defaults are
separate constants so debug replay behavior cannot change accidentally.

## Diagnostics and compatibility

Counters are monotonic and printed periodically only when activity changes,
plus a final summary. Raw frame bytes are forwarded unchanged. Existing bridge
CLI remains available for vcan; a physical mode/entry point selects the fixed
mapping and queue preparation.

## Offline delivery

Create sibling `original-project` and `modified-project` roots containing the
same project-relative paths. Generate a portable Git binary diff with `a/` and
`b/` project-relative paths, validate plain `git apply --check`, apply it to a
scratch copy, and compare hashes with `modified-project`.
