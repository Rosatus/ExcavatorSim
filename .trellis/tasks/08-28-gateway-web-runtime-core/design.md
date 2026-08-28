# Design — Gateway Web runtime core

## Core loop

Extract runtime state behind a `GatewayCore` object. Its owner loop consumes the
existing UDP input plus a thread-safe typed command queue. A wakeup socket makes
new Web commands interrupt the loop without a coarse polling delay. Command
results complete request futures with bounded timeouts; timeout does not grant
the Web thread authority to execute the operation itself.

Publish frozen, JSON-ready `GatewayStatus` snapshots by atomic reference swap.
Each committed user-controlled configuration mutation increments a revision;
volatile telemetry and lifecycle fields do not. Mutating API calls carry the
configuration revision observed by the browser; a mismatch returns a conflict
and a fresh status reference.

## HTTP runtime

An `aiohttp` application runs on a dedicated event-loop thread and serves the
versioned API, WebSocket events, log downloads, and static-resource fallback.
Startup is coordinated so Gateway success is reported only after the loopback
socket binds. Shutdown stops accepting commands, disarms scheduled producers,
closes transports, drains bounded log work, and joins the Web thread.

API policy is derived from the explicit runtime mode and detected platform.
Handlers validate content type, request size, JSON schema, revision, and
capability before enqueueing a command. No permissive CORS is enabled.

## Transport lifecycle

Windows `Pc001Sink` owns all `sendall` calls inside its service thread. Producers
enqueue into a bounded queue only while a handshaken client is active; otherwise
they receive a drop/failure result. Disconnect clears transient queue entries,
increments counters, and posts a core event. Endpoint rebind is a core command:
disarm, disconnect, close, enter RECONFIGURING, attempt bind, then persist and
enter READY only on success.

Linux uses the existing can0 preparation and fixed helper. A restart command
requires standalone mode and explicit confirmation, disarms, closes the sink,
forces the helper transaction, verifies, rebinds, and publishes each state. The
normal startup path still skips mutation for a proven-ready interface.

## Logs and events

The core emits small structured event objects into two bounded queues: a
sequence ring for browsers and a writer queue. A background writer owns JSONL
disk I/O and rotating files. Overflow increments a visible dropped-record count
and must not block CAN emission. Per-message counters are aggregated in memory
and flushed once per second into both streams. Archive creation takes a
point-in-time file list and streams from the Web thread.

Use `platformdirs` for mutable configuration/log locations. Endpoint
persistence uses a schema-versioned JSON document written through temp-file,
flush, and atomic replace; failed rebinds never update it.
