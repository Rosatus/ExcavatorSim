# ExcavatorSim Bootstrap and Reusable BabylonSim Migration

## Goal

Create a new, Godot-oriented `ExcavatorSim` project that is ready for a later agent to build a desktop excavator simulator with higher-fidelity rendering and integrated local physics, while preserving the proven Python authority from `BabylonSim`.

The first deliverable is project initialization plus a clean, documented migration boundary. The Godot client, visual scene, and physics adapters remain follow-up implementation work.

## Background and confirmed facts

- `BabylonSim` is currently a browser-first React/Babylon.js application. Python 3.11 and Pinocchio own authoritative excavator kinematics, input safety, terrain state, excavation history, replay, and reset/seek semantics (`E:/projects/BabylonSim/README.md:3-7,107-126,171-180`).
- The backend already contains deterministic terrain generation, layered stable/loose soil, bucket volume accounting, excavation/deposition events, replay contracts, HTTP/WebSocket protocol validation, and visual asset provenance.
- The intended product is now a Windows desktop simulator where visual quality, terrain presentation, and physics integration are more important than browser delivery.
- Existing excavator GLB assets are visual assets only. URDF collision, mass, inertia, hydraulics, and full dynamic excavator behavior are deferred until the model contract is agreed.
- The Godot client should use Forward+ on desktop. Godot's local physics is a presentation/contact layer in the first migration; Python remains the authority.

## Requirements

### R1 — New-project initialization

`E:/projects/ExcavatorSim` must be an independent Git repository with:

- Trellis initialized for Codex-driven future work;
- CodeGraph initialized and indexed;
- developer identity and workflow metadata recorded;
- no dependency on the source checkout's `.git`, `.trellis`, `.codegraph`, or frontend build output.

### R2 — Durable project context

Trellis task artifacts must record the product direction, architecture boundaries, migration scope, deferred model decisions, and acceptance criteria so a later agent can continue without relying on this conversation's context.

### R3 — Reusable backend migration

Migrate the reusable Python authority into a clearly owned backend package in `ExcavatorSim`, including:

- Pinocchio-based kinematics, control/input safety, runtime state, and lifecycle behavior;
- layered terrain generation and excavation/deposition algorithms;
- bucket volume accounting and deterministic replay/recording contracts;
- HTTP/WebSocket protocol schemas and validation support;
- backend unit tests and fixtures that exercise the migrated modules;
- only the scripts and documentation needed to run and verify the migrated backend.

The migrated package may be renamed from `babylon_sim` to a neutral `excavator_sim` namespace, but the wire protocol and serialized compatibility identifiers must remain explicit and documented.

### R4 — Asset and provenance migration

Migrate the existing visual excavator GLB set, calibration/provenance records, applicable licenses/notices, and GLB export guidance. Do not claim that these assets provide production collision, mass, inertia, or contact dynamics.

### R5 — Godot handoff boundary

Create a documented boundary for the future Godot client:

- Godot consumes authoritative pose/state and derived terrain snapshots/patches;
- Godot renders terrain and excavator visuals and may run local static-collider/contact presentation;
- Godot physics must not write authoritative transforms, terrain heights, bucket volume, or replay state back to the backend in the first release;
- the future client can run when physics is disabled or unavailable.

### R6 — Explicit exclusions

This bootstrap does not implement:

- the Godot scene or UI;
- Godot/Jolt physics adapters;
- dynamic articulated excavator motors, hydraulic forces, or collision reaction;
- per-grain sand rigid bodies or authoritative granular simulation;
- URDF-to-Godot collision/rigid-body mapping;
- replacement of Python by C++;
- removal of the BabylonSim repository.

## Acceptance criteria

- [x] `E:/projects/ExcavatorSim` has an independently initialized Git/Trellis/CodeGraph structure and CodeGraph reports a successful index; a final clean-worktree check remains before commit.
- [x] A future agent can find the product goal, authority boundary, migration map, deferred decisions, and next phases from `.trellis/tasks/08-06-excavator-sim-bootstrap/` without reading the original conversation.
- [x] The migrated Python backend imports from `backend/src` under the target-owned environment and starts without importing from `E:/projects/BabylonSim`; the internal `babylon_sim` namespace is intentionally retained for first-pass compatibility.
- [x] Migrated backend tests cover kinematics, terrain generation, layered excavation/deposition, replay, protocol validation, and lifecycle behavior.
- [x] GLB assets and provenance/license records are present and verified by the migrated asset checks.
- [x] The migration documentation identifies every intentionally excluded Babylon/React module and the Godot replacement seam.
- [x] The source repository remains unchanged by the migration except for any separately requested documentation or commit metadata.

## Risks and deferred decisions

- Godot desktop rendering improves the target platform's visual ceiling, but it does not automatically produce realistic soil; terrain and soil presentation remain domain code.
- Copying the Python backend before renaming the package reduces risk; namespace cleanup must not silently change protocol identifiers.
- C++ is deferred until profiling demonstrates a Python bottleneck. Godot C++ GDExtension is an option for isolated hot loops later.
- If browser delivery becomes mandatory again, Godot's Web export uses the Compatibility renderer and requires a separate visual-performance review.
