# Granular Soil Options Assessment

## Revised Decision

Deterministic replay and exact global volume conservation are not product goals.
Visual excavation quality is the priority. The selected design is therefore a
visual-first solid-to-dynamic-to-settled hybrid:

- global `TerrainState` remains a low-frequency coarse scar/pile representation;
- a bounded active-soil episode represents material released by the current cut;
- a bucket-local cellular occupancy solver defines actual carried payload;
- a smoothed fill mesh and continuous GPU grains derive from that occupancy;
- a small pooled Jolt clod set adds near-field impact and rolling behavior;
- settled local material is reconciled back into coarse terrain without requiring
  exact per-cell conservation or replay parity.

Nominal/heaped bucket capacity remains a model calibration and safety envelope, not
the fill algorithm. Actual mass and center of mass come from occupied bucket cells.

## Why Not Pure Jolt Grains

Removing determinism does not make thousands of CPU rigid bodies a good granular
solver. Dense small-body contacts and stacks are expensive and visually unstable;
Jolt soft bodies are deformable meshes rather than interacting soil grains. Jolt is
appropriate for a few dozen hero clods, rocks, contact cues, and bucket/terrain
queries, not the continuous carried-soil field.

## Why GPU Particles Are Still Derived

Godot GPU particles can provide thousands of continuous grains, dust, spill arcs,
and collision against GPU-specific heightfield/SDF/primitive colliders. They do not
access or push the normal Jolt physics world. Therefore the CPU bucket occupancy is
the common source for visible retained soil and payload feedback, while GPU particles
are a scalable presentation of transfers into and out of that state.

## Mature Architecture Evidence

AGX Terrain uses a 3D cell grid plus a heightfield surface, converts excavated solid
cells into dynamic particle mass through a shovel active zone, computes shovel
resistance, reports soil mass/bulk volume inside the shovel, and merges dynamic soil
back into terrain when it settles. The project will adopt this architecture pattern,
not the proprietary solver's industrial fidelity.

RoadCraft's developers describe custom terrain/sand work and explicit depth/pile
limits driven by memory and performance. Noita likewise demonstrates that falling
material behavior comes from a chosen domain solver, not from ordinary rigid bodies.

## Evaluated Alternatives

| Option | Visual ceiling | Project fit | Decision |
|---|---|---|---|
| Scalar payload + burst particles | Low-medium | Easy | Rejected as primary experience |
| Thousands of Jolt grains | Medium | Poor CPU/contact scaling | Rejected |
| Bucket cellular occupancy + GPU flow + hero clods | High | Incremental and bounded | Selected |
| Local native/GPU PBD brick | Very high | New solver/integration subsystem | Conditional prototype |
| Global PBD/MPM/DEM or external CUDA solver | Highest/research-grade | Platform, tooling, and scope mismatch | Separate future task only |

## Initial Profiling Hypotheses

These are measurement gates, not established guarantees:

- balanced: 1,000-2,000 active GPU grains, 24-48 awake Jolt clods;
- high: 3,000-5,000 active GPU grains, at most 64 awake clods;
- bucket fill below roughly 500 visible triangles;
- terrain scar/pile commits at no more than 10-15 Hz unless profiling supports more;
- soil presentation target below roughly 1 ms CPU and 2 ms GPU.

## Primary Sources

- AGX Terrain solid/dynamic soil and shovel model:
  https://www.algoryx.se/documentation/complete/agx/tags/latest/doc/UserManual/source/agxTerrain.html
- Godot GPU particle collision boundary:
  https://docs.godotengine.org/en/4.7/tutorials/3d/particles/collision.html
- Godot Jolt integration and contact caveats:
  https://docs.godotengine.org/en/stable/tutorials/physics/using_jolt_physics.html
- Jolt architecture and soft-body limitations:
  https://github.com/jrouwe/JoltPhysics/blob/master/Docs/Architecture.md
- NVIDIA FleX/PBD integration model:
  https://nvidiagameworks.github.io/FleX/1.2/lib_docs/manual.html
- Godot compute-shader constraints:
  https://docs.godotengine.org/en/stable/tutorials/shaders/compute_shaders.html
- RoadCraft engine devblog:
  https://community.focus-entmt.com/focus-entertainment/roadcraft/blogs/195-roadcraft-devblog-building-the-engine
- Noita GDC technical talk:
  https://www.gdcvault.com/play/1025695/Exploring-the-Tech-and-Design
