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
- **the authority zero pose** — URDF/authority FK frames at zero, or the contract's pivot/link
  convention — because under rest+delta mapping it defines what the GLB rest must encode;
- neutral and isolated-joint fixtures;
- existing visual manifests or calibration records;
- Godot import tests and scene ownership boundaries;
- CAD markers or explicit pivot/linkage extras;
- a proven sibling asset of the same family (manifest, rig, fixture) — its contract values are the
  cheapest independent cross-check for the new model's zero.

Controlled isolated-joint poses are the strongest practical check: keep all but one joint at zero,
then verify the intended visual subtree rotates around the candidate pin on one local axis.

Fixtures generated *from the asset under test* (rest transforms composed into expected frames)
prove only internal consistency — classify them `declared` for zero-pose correctness, not
`validated`.

## Consolidated pre-write gate

Ask once, grouping only unresolved decisions:

1. Which exact candidate path maps to each semantic frame?
2. What are world up/forward, handedness, units, matrix layout, joint sign, and zero offset?
3. **Does the authority zero pose match the asset's rest pose, or must the exporter normalize
   (re-pose) the assembly to the contract zero?** Under rest+delta mapping the GLB rest encodes the
   semantic zero — this is the highest-impact single decision.
4. Are candidate local origins approved as real pin centers?
5. Which parts are driven, passive, fixed, or presentation-only?
6. For closed chains, what are the pins, solver plane, driven input, valid branch, and writable nodes?
7. May the supplied asset be copied unchanged, or is re-export/asset modification authorized?
8. Do overlay/decal meshes authored against another model's surfaces transfer, or should they be
   dropped? (Verify pivot-local vertex bounds numerically before grafting.)

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
- After any re-export, regenerate every derived artifact and refresh every `sha256` pin in the
  project catalog — stale pins fail activation with a contract-mismatch error that looks like an
  asset bug. A running editor caches the old `PackedScene`; restart it fully before judging the new
  asset visually.

## Manifest contents after approval

Record facts needed to detect drift:

- source SHA/bytes and import policy;
- observed resource counts and bounds;
- exact node-index/name paths and visual descendants;
- parent-local rest transforms and scale;
- semantic frame map and separately labelled runtime axes;
- coordinate conversion and matrix semantics;
- **semantic-zero provenance**: which authority zero the rest pose encodes, and the normalization
  (re-pose) transform the exporter applied to reach it — so a later re-export cannot silently
  re-anchor the zero to an authored pose;
- driven/passive ownership and failure policy;
- passive pin paths, rest lengths, solver plane, branch, and writable nodes when applicable.

Keep observed source metadata separate from validated runtime metadata. A Blender authoring axis may
use a different label than the post-conversion Godot runtime axis.
