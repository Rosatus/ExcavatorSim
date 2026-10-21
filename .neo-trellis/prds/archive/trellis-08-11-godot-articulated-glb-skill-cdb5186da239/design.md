# Design: godot-adapt-articulated-glb skill

## Skill layout

```text
.agents/skills/godot-adapt-articulated-glb/
├── SKILL.md
├── agents/openai.yaml
├── scripts/inspect_mechanical_glb.py
├── tests/test_inspect_mechanical_glb.py
└── references/
    ├── evidence-and-human-gates.md
    └── godot-mechanical-adapter.md
```

`SKILL.md` stays below 500 lines and owns routing/order. Detailed inference limits and Godot
implementation patterns live one level below in `references/`. The script is deterministic and
stdlib-only; tests create malformed containers in a temporary directory and use the repository's
real SY205 GLB only for the positive integration case.

## Workflow and gates

1. **Preserve input**: hash the GLB; do not copy/re-export/edit until scope and destination are known.
2. **Inspect raw evidence**: run the bundled inspector and retain node identity by indices and full
   paths, not names alone.
3. **Classify confidence**:
   - `observed`: container, graph, raw transforms/references/extras;
   - `declared`: exporter extras and naming conventions;
   - `validated`: Godot PackedScene measurements and controlled pose tests;
   - `decision`: authority mapping, coordinate contract, joint semantics, closed-chain policy.
4. **Consolidated human gate**: collect unresolved `decision` items and ask once before writing
   manifest/scene/runtime files. No questions are needed when authority contracts and controlled
   pose tests uniquely validate the mapping.
5. **Godot import contract**: capture actual imported local transforms, paths, resources and AABB;
   store them in a project manifest as regression data, not as a replacement for inspection.
6. **Runtime adapter**: convert coordinate systems once; apply root world delta, then parent-to-child
   local rotation deltas while preserving imported origins/scales; solve passive mechanisms last.
7. **Verification**: test zero, isolated joints, asymmetric pose, restore/reconnect, invalid input,
   optional linkage geometry, visual review and project quality gates.

## Inspector contract

Command:

```text
python inspect_mechanical_glb.py <path.glb> [--pretty]
```

Success writes schema `mechanical-glb-inspection-v1` JSON to stdout and exits `0`. Array/index order
matches the source; object keys are sorted. The report contains content identity, all chunks, asset
metadata/counts, scene roots, node parent/children/index paths, raw matrix/TRS/extras, and compact
mesh/material/image/skin/animation declarations. It does not decode BIN geometry or claim that a
declared axis/pivot is mechanically correct.

Failures also write stable JSON without filesystem paths or traceback:

- `3 INPUT_UNREADABLE`
- `4 GLB_CONTAINER_INVALID`
- `5 GLB_JSON_INVALID`
- `6 GLTF_ROOT_INVALID`

Cross-reference and graph anomalies remain exit `0` diagnostics so the inspector can still deliver
partial evidence; it is not a substitute for a full Khronos validator.

## Compatibility and ownership

- The skill is project-local because it is absent from `.trellis/.template-hashes.json`; ordinary
  `trellis update` must not overwrite it.
- `agents/openai.yaml` adds only interface fields and implicit invocation policy. It declares no MCP
  dependency because the workflow must still function with the Godot CLI when Godot MCP is absent.
- The current SY205 asset is an integration fixture, not a template to copy and not a source of
  hard-coded node names in the skill.

## Rollback

The feature is isolated under one new skill directory. Rollback removes that directory and the task
artifacts; no product runtime or asset migration is coupled to it.
