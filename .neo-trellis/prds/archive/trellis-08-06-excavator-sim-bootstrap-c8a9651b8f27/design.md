# Technical Design

## Repository layout

```text
ExcavatorSim/
├── .trellis/                         # project and task knowledge
├── .codegraph/                       # source graph/index metadata
├── .codex/                           # Codex integration
├── pyproject.toml                    # backend project/test/type configuration
├── pixi.toml                         # isolated Python environment and tasks
├── backend/
│   ├── src/babylon_sim/              # migrated authority; neutral ownership boundary
│   ├── tests/                        # migrated backend tests/fixtures
│   └── scripts/                      # backend-only verification tools
├── protocol/                         # shared wire schemas and manifest
├── assets/                           # visual GLBs, calibration, provenance, notices
├── docs/                             # migration and Godot integration notes
└── godot/                            # reserved for the future Godot client
```

The source `BabylonSim` checkout remains independent. No source checkout is added as a submodule, editable install, symlink, or runtime import path.

## Authority and data flow

```text
Godot client ──WebSocket/HTTP──> Python authority
     │                              │
     │ derived poses/terrain         │ Pinocchio + layered terrain + replay
     │ local render/contact only     │ authoritative events and snapshots
```

The current JSON wire contracts remain the compatibility boundary. A future Godot adapter should consume the same state, terrain snapshot, and terrain patch semantics before any protocol redesign is considered.

## Migration mapping

| Source area | Migration decision | Future consumer |
|---|---|---|
| `src/babylon_sim/{calibration,control,input_router,model,simulation,state,runtime}.py` | Migrate to backend authority | Python service |
| `src/babylon_sim/{terrain,terrain_excavation,terrain_controller}.py` | Migrate unchanged in behavior | Python terrain authority |
| `src/babylon_sim/{protocol,exchange,recording,replay,replay_contract,rrd,series}.py` | Migrate and preserve serialized contracts | Python service and Godot adapter |
| `src/babylon_sim/{cli,web,production,paths,constants}.py` | Migrate with paths/startup adapted to `ExcavatorSim` | Backend runtime |
| `tests/backend/**` | Migrate and update imports | Backend CI |
| `protocol/**` | Copy as shared contracts | Python + Godot |
| `assets/visual/original/**`, calibration, provenance, notices | Copy and validate | Godot visual client |
| `frontend/**` | Do not migrate as executable code | Reference only; replace with Godot |
| Babylon-specific scene/renderer/Havok work | Do not migrate | New Godot renderer/physics adapters |
| URDF dynamic/collision metadata | Keep deferred | Future model task |

The initial implementation may retain the `babylon_sim` Python import namespace inside `backend` to minimize mechanical risk, but the target packaging and documentation must expose a neutral `excavator_sim` ownership boundary. A namespace rename is allowed only with import/test/protocol parity checks.

## Godot boundary

The future Godot project should own:

- GLB scene assembly and node transforms;
- desktop Forward+ rendering, camera, lighting, materials, particles, and UI;
- a transport client and local state cache;
- derived terrain mesh and chunked static collider presentation;
- optional local physics probes and bucket visual effects.

It must not own authoritative excavation volume, terrain history, replay timestamps, or backend pose decisions in the first release.

## C++ evolution seam

Python remains the initial service. If profiling later identifies a hot loop, isolate that algorithm behind a pure interface so it can be replaced by a C++ service or Godot C++ GDExtension without changing the wire protocol or Godot client contract.

## Rollback

The migration is additive. If a migrated module fails validation, remove or disable only the new `backend/` package and keep the source `BabylonSim` project operational. Do not modify source files in the original checkout as part of this task.
