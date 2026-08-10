# Godot Integration Boundary

## Intended client

The future client targets Windows desktop with Godot Forward+. It should load the five-part excavator GLB visual skin and apply the authoritative named-frame transforms received from Python.

## Transport

The first Godot adapter should consume the existing BabylonSim HTTP/WebSocket contracts rather than inventing a second authority protocol. It needs equivalents of:

- realtime state handshake and state snapshots;
- input command validation and acknowledgements;
- terrain view snapshots and absolute-height patches;
- terrain epoch/revision identity and stale/gap recovery;
- recording/replay and Return-to-Live lifecycle semantics.

## Authority boundary

Python remains authoritative for joint state, input safety and lifecycle in every
profile. The legacy BabylonSim profile also remains authoritative for terrain
layers, bucket inventory, events, recording and replay. The approved Godot-first
local-world profile used by the realistic client instead keeps deterministic
terrain/world and convenience bucket state in Godot; it does not mirror Python
terrain packets or publish local terrain, physics transforms or replay cursors
back to Python. The two profiles coexist until the integration release-candidate
review selects one runtime contract.

## Terrain and physics seam

Godot should build a derived render mesh from the selected surface snapshot. A later physics adapter may maintain chunked static terrain colliders and local probes. Collider updates must be generation-gated and stale-safe; a disabled or failed physics backend must leave the Python service and visual state usable.

The first soil presentation is not a per-grain rigid-body simulation. It combines the authoritative stable/loose heightfield and bucket volume with bounded visual particles or clumps. Those effects are disposable presentation state and must clear on historical seek, reset, reconnect, and authority-generation changes.

## Deferred model decisions

The current GLBs are visual assets. URDF collision geometry, mass/inertia, hydraulic forces, material contact parameters, bucket cavity calibration, and a fully dynamic articulated excavator require a separate model contract and are not part of this bootstrap.
