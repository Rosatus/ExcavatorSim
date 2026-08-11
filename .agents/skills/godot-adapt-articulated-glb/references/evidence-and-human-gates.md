# Mechanical GLB Evidence And Human Gates

## Evidence levels

Use these levels consistently. Do not promote evidence because it looks plausible.

| Level | Meaning | Examples |
| --- | --- | --- |
| Observed | Directly encoded or measured | SHA, node indices, TRS, parents, mesh reference |
| Declared | Author/exporter assertion | `mechanical_role`, `rotation_axis`, node name |
| Validated | Reproduced by an independent check | PackedScene path, isolated-axis pose, measured pin |
| Decision | Project contract chosen by a human or authority owner | frame mapping, sign, zero offset, solver policy |

The GLB inspector reports observed evidence and preserves declared extras. It does not decode BIN
geometry, validate materials visually, or infer mechanics.

## Build candidate mechanics

Use node indices and full index paths as identity; names may be absent or duplicated.

Candidate pivot evidence may include:

- an empty transform node with rigid visual descendants;
- a continuous ancestor chain between visually separable rigid parts;
- a node extra describing a role/axis/pin;
- a stable local translation near visible pin geometry;
- a controlled pose where descendants rotate about that local origin.

These clues justify a candidate, not a final mapping. Never use a mesh AABB center as a joint center.
Do not assume an asset without skin/animation is correctly authored for pivot-driven motion.

## Resolve from project evidence first

Before asking the user, search for:

- authority frame/joint names and order;
- coordinate/matrix contracts and unit conventions;
- neutral and isolated-joint fixtures;
- existing visual manifests or calibration records;
- Godot import tests and scene ownership boundaries;
- CAD markers or explicit pivot/linkage extras.

Controlled isolated-joint poses are the strongest practical check: keep all but one joint at zero,
then verify the intended visual subtree rotates around the candidate pin on one local axis.

## Consolidated pre-write gate

Ask once, grouping only unresolved decisions:

1. Which exact candidate path maps to each semantic frame?
2. What are world up/forward, handedness, units, matrix layout, joint sign, and zero offset?
3. Are candidate local origins approved as real pin centers?
4. Which parts are driven, passive, fixed, or presentation-only?
5. For closed chains, what are the pins, solver plane, driven input, valid branch, and writable nodes?
6. May the supplied asset be copied unchanged, or is re-export/asset modification authorized?

Give a recommendation and evidence for every item. Do not write half a manifest and ask additional
questions later. If all items are already proven or contracted, record an empty gate and proceed.

## Confidence and failure rules

- Treat extras as declared metadata even when their wording is precise.
- Require unit scale or an explicit scale contract; reject hidden negative/non-uniform scale unless
  the project explicitly accepts it.
- Treat multiple parents, cycles, duplicate semantic candidates, unsupported required extensions,
  non-finite transforms, and missing scene roots as blocking evidence faults.
- Treat absent visual materials/textures, unexpected skeleton/animation/collision, and large import
  bounds changes as import-contract faults.
- Stop and request re-authoring when a mesh and pivot cannot be separated without moving vertices or
  when the true pin center cannot be validated.

## Manifest contents after approval

Record facts needed to detect drift:

- source SHA/bytes and import policy;
- observed resource counts and bounds;
- exact node-index/name paths and visual descendants;
- parent-local rest transforms and scale;
- semantic frame map and separately labelled runtime axes;
- coordinate conversion and matrix semantics;
- driven/passive ownership and failure policy;
- passive pin paths, rest lengths, solver plane, branch, and writable nodes when applicable.

Keep observed source metadata separate from validated runtime metadata. A Blender authoring axis may
use a different label than the post-conversion Godot runtime axis.
