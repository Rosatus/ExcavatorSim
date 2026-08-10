# Develop a Realistic Godot ExcavatorSim Client

## Goal

Build the first usable Windows desktop Godot Forward+ client for ExcavatorSim. The client should present a visually credible excavator and terrain experience using the GLB assets supplied by the user. Python should remain a small deterministic motion/input service; Godot should own the rest of the interactive world unless a later requirement proves that a concern must be shared.

## Confirmed Facts

- The repository already contains a tested Python motion/terrain/replay service, protocol schemas, five legacy visual GLBs, a visual manifest, calibration/provenance data, and a documented Godot boundary. The user has now supplied one combined SY205 GLB with an explicit mechanical hierarchy for the Godot client.
- `godot/client/` is a newly created Godot 4.7.1 Forward+ project with the Godot MCP plugin enabled, but it currently has no product scenes or scripts.
- Godot MCP is a development-time tool only. It may inspect and author the client, but it must not become a runtime dependency.
- Visual direction is “尽量拟真” (as realistic as practical for the first slice). Realism applies first to lighting, materials, scale, camera motion, authoritative pose presentation, terrain heightfield presentation, and bounded soil effects.
- Joint motion and input safety should remain deterministic and authoritative in Python.
- Terrain should be deterministic but does not need to depend on Python for the first Godot product. A Godot-owned seeded/fixed-step terrain controller is preferred if the required determinism level permits it.
- Godot terrain and bucket-volume determinism means repeatability on the same supported Windows/Godot runtime for the same seed and ordered command sequence. Cross-machine or cross-platform bitwise identity is not required.
- Bucket contents, soil volume accounting, soil particles/clumps, UI, camera, local physics/contact presentation, and lifecycle may be Godot-owned convenience state.
- Recording/replay is not a first-slice requirement.
- The first input layer supports keyboard/mouse and a generic Xbox-style gamepad through Godot action mappings; dedicated excavator hardware is a later mapping-only extension.
- The realistic Forward+ performance baseline is 1920×1080 at a target 60 FPS on a modern Windows desktop. Degraded graphics settings may be added later, but the first visual acceptance review uses this baseline.
- GLB authoring is user-owned. The delivered combined SY205 asset exposes five clearly identifiable, independently movable pivot groups corresponding to base, upper structure, boom, arm, and bucket; a Godot-side adapter calibrates names and local transforms before M2.
- The current `RuntimeController` still composes terrain and replay workers; implementation must introduce an optional motion-only boundary before removing or archiving those subsystems.

## Requirements

### R1 — Godot project foundation

- Keep the product project under `godot/client/` in the existing repository.
- Add a reproducible main scene, project settings, import settings, and a source/output directory convention without committing editor caches or generated exports.
- Keep Godot MCP usage documented and optional.

### R2 — Deterministic motion transport

- Consume the existing HTTP/WebSocket motion contracts without silently renaming protocol identifiers.
- Implement hello/hello-ack, session identity, authoritative pose snapshots, input/command acknowledgements, errors, reconnect, and lifecycle state handling.
- Keep a fixed-rate motion loop and explicit input sequence numbers; Godot may interpolate received pose only within the same motion generation.
- Do not make Godot terrain or local physics write transforms back to Python.

### R3 — Godot-owned deterministic world state

- Generate and edit the terrain in Godot using an explicit seed, fixed-step operation order, stable numeric representation, and deterministic command inputs.
- Keep the terrain representation separate from disposable render effects; visual particles/clumps must not be the terrain state store.
- Compute bucket interaction and bucket soil volume locally from the Godot terrain/world state unless a later model contract requires Python authority.
- Do not add recording/replay cursors or playback UI to the first slice.

### R4 — Realistic excavator visual skin

- Import and validate the supplied combined SY205 GLB through a Godot-local adapter manifest; keep the existing five-file backend visual manifest unchanged.
- Bind `base_link`, `upper_structure_link`, `boom_link`, `arm_link`, and `bucket_link` to authoritative `frame_transforms`.
- Preserve the existing transform composition and frame-parity fixture before adding visual polish.
- Add realistic scene lighting, materials, camera composition, scale, and presentation effects without changing Python authority.

### R5 — Terrain and soil presentation

- Build a render mesh from the Godot terrain state.
- Apply terrain edits incrementally and keep mesh/collider updates generation-gated.
- Represent bucket soil volume with bounded disposable mesh/particle/clump effects. These effects must never become a second terrain authority.

### R6 — Operator-facing vertical slice

- Provide the agreed first-slice input scheme and visible connection/authority/quality status.
- Provide basic start/pause/reset and the agreed local-world controls. Replay controls are intentionally excluded.
- Keep the client usable when local physics/collider presentation is disabled or fails.

### R7 — Quality and handoff

- Add focused Godot-side tests or deterministic fixtures for motion decoding, transform parity, seeded terrain repeatability, bucket-volume accounting, and lifecycle/generation cleanup.
- For cross-layer changes, run the backend `pixi run verify` gate and preserve the existing motion protocol compatibility.
- Use Godot MCP for repeatable read/author/inspect cycles and report any editor or game-run limitations.

## Out of Scope for the First Slice

- Replacing or redesigning the Python motion authority or wire protocol.
- Authoritative dynamic rigid-body excavator simulation, hydraulics, production contact calibration, or URDF-to-GLB collision mapping.
- Per-grain rigid-body soil simulation.
- C++/GDExtension optimization before profiling identifies a measured bottleneck.
- Recording/replay, multiplayer, or broad editor tooling.
- Authoring, remodeling, or repairing the user-supplied excavator GLB.

## Acceptance Criteria

- [x] Godot opens a reproducible main scene and renders the user-supplied excavator skin with the five manifest frames.
- [x] The displayed pose matches the Python `frame_transforms` and the existing frame-parity fixture within an agreed tolerance.
- [x] A connected client can receive state, show connection/authority status, send the agreed input/commands, and display acknowledgements/errors without writing authority state back to Python.
- [x] The same terrain seed and ordered edit command sequence reproduce the same terrain and bucket-volume result at the documented precision.
- [x] Terrain edits and derived mesh/collider updates are generation-gated and cannot overwrite newer world state.
- [x] Reset and reconnect clear stale visual soil/terrain work and adopt the new local-world generation.
- [x] The visual client remains usable when local physics/collider presentation is disabled or unavailable.
- [x] Focused client checks pass, and backend `pixi run verify` remains green for any backend/protocol changes.
- [x] A final human visual review accepts the realistic look, camera behavior, interaction feel, and performance on the target machine.

## Deferred Input

The supplied combined SY205 GLB is now available for the Godot client. The GLB-adaptation child milestone must copy and inspect it before the motion vertical slice; the placeholder frame nodes remain a rollback path. Asset names, local transform calibration, materials and optional collision proxies are adapted on the Godot side; this does not reopen the architecture because the five independently movable frame targets are identifiable.

The approved architecture is a split authority: Python owns deterministic excavator motion and input safety; Godot owns deterministic-enough terrain/world interaction plus all presentation and convenience state. The existing Python terrain/replay modules remain available as legacy compatibility code until the new boundary is validated; they are not required by the first Godot client.
