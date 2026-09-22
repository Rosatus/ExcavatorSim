# Physical CAN socket bridge low latency

## Goal

Move physical SocketCAN transmission responsibility to the ICT-side PC001 TCP
bridge without reintroducing multi-second stale-frame playback. Under physical
CAN congestion, prefer fresh telemetry and observable frame loss over latency.

## Background

- The Gateway now sends only PC001 TCP batches. Each frame is already encoded
  as `can_frame(16B) + channel(i32)`; the bridge must not reinterpret payloads.
- The existing bridge reads each batch and synchronously sends every frame to
  vcan, so physical CAN backpressure would stop TCP draining and accumulate old
  data across userspace, TCP, and the kernel queue.
- The earlier direct-Gateway fix bounded physical latency with
  `txqueuelen=10`, non-blocking SocketCAN, and per-ID latest-value coalescing.
- Physical CAN bitrate and controller configuration are now owned externally.

## Requirements

- Preserve PC001 framing and every CAN ID, DLC, payload byte, flag, and channel.
- Route physical output exactly as `ch0 -> can1`, `ch2 -> can4`, and
  `ch3 -> can3`. Drop other channels without fallback and count them.
- Keep TCP reception independent from physical CAN service so congestion cannot
  stop the bridge from draining incoming batches.
- Use non-blocking CAN_RAW sockets and a bounded latest-value queue keyed by
  physical interface plus full CAN identity. A newer pending value supersedes
  the older value instead of forming a FIFO history.
- Service channels and IDs fairly with a finite per-turn budget.
- Treat `ENOBUFS`, `EAGAIN`, and `EWOULDBLOCK` as recoverable congestion loss.
  Treat device/interface failures as terminal and report them clearly.
- Limit each mapped physical interface to `txqueuelen=10`, without changing
  bitrate, restart-ms, controller type, or link up/down state.
- Keep the existing `setup_can0.sh` entry point for operator compatibility; it
  becomes the physical bridge launcher despite its legacy name.
- Emit bounded aggregate diagnostics for received, sent, coalesced,
  congestion-dropped, unmapped, and terminal-error outcomes.
- Preserve before and after trees and generate an application-ready binary Git
  patch plus hashes and application instructions.

## Acceptance Criteria

- [x] Fragmented PC001 batches retain exact wire bytes and route the three
  supported channels to their approved physical interfaces.
- [x] Unknown channels are never sent and increment an unmapped counter.
- [x] Repeated pending frames for one interface/CAN identity leave only the
  newest payload; pending memory is bounded and low-rate channels make progress.
- [x] Recoverable SocketCAN congestion never disconnects TCP or busy-spins and
  never produces a long historical replay after recovery.
- [x] Physical sockets are non-blocking; terminal interface errors stop the
  bridge with an actionable diagnostic.
- [x] Startup only verifies mapped interfaces and applies `txqueuelen=10`; no
  bitrate, restart-ms, down, or up mutation is issued.
- [x] Existing replay, CSV parsing, PC001 packing, and virtual-CAN behavior
  remain compatible.
- [x] `changes.patch` passes plain `git apply --check` from a project root, and
  applying it to a clean original snapshot reproduces the modified snapshot.

## Out of Scope

- Gateway changes, PC001 protocol changes, CAN construction/DBC/cadence changes,
  CAN receive behavior, bitrate selection, restart-ms, driver setup, or lossless
  delivery during overload.
