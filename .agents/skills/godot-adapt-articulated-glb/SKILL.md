---
name: godot-adapt-articulated-glb
description: "Inspect and adapt Blender-exported articulated or mechanical GLB assets for Godot while preserving pivot hierarchy, local joint origins, materials, and authority boundaries. Use when importing or replacing excavators, cranes, robot arms, vehicles, linkages, or other multi-part .glb models; diagnosing wrong rotation planes or orbiting pivots; mapping semantic frames to Godot Node3D paths; or rebuilding passive mechanical motion without reliable asset-specific documentation."
---

# Adapt Articulated GLB Assets To Godot

Treat the GLB as evidence, not as a complete mechanical specification. Derive only what the
container and Godot import prove. Collect every unresolved mechanical decision and ask once before
writing a manifest, scene, runtime adapter, or modified asset.

## 1. Preserve And Inspect The Input

1. Keep the supplied GLB bytes unchanged. Record its source location and intended repository
   destination, but do not copy, re-export, rename, or change import settings yet.
2. Run:

   ```text
   python <skill-dir>/scripts/inspect_mechanical_glb.py <asset.glb> --pretty
   ```

3. Read [evidence-and-human-gates.md](references/evidence-and-human-gates.md).
4. Build an evidence table with these labels:
   - `observed`: container, index graph, raw transforms, references, and exact extras;
   - `declared`: exporter names and metadata claims;
   - `validated`: measurements from the imported Godot `PackedScene` and controlled poses;
   - `decision`: semantic mapping, coordinates, zero offsets, writable nodes, and mechanism policy.

Never treat a node name, `rotation_axis` extra, mesh center, AABB center, or visual preview as a
validated joint center or runtime axis.

## 2. Resolve The Human Gate Before Writes

Inspect the authority model, protocol/schema, existing Godot project, tests, and neighboring
manifests first. Then consolidate unresolved decisions into one question set.

Pause before any project mutation when one or more of these remain ambiguous:

- authority frame to exact GLB node-index path mapping;
- world up/forward axes, handedness, units, matrix semantics, joint sign, or neutral offset;
- whether an empty/pivot node is located at the real mechanical pin;
- main-chain ordering, independently driven parts, or permitted local rotation axes;
- passive/closed-chain topology, solver plane, driven link, branch selection, or writable controls;
- need to re-export, alter, or replace the user-owned asset.

If repository evidence and controlled poses resolve every item, state that the human gate is empty
and why. Do not manufacture a question.

## 3. Validate The Godot Import

Use Godot MCP when connected; otherwise use the Godot CLI/headless scripts. MCP is optional and must
not become a runtime dependency.

1. Import the unchanged GLB as a `PackedScene` and instantiate it.
2. Inspect actual node-index paths, parent relations, local/global transforms, scale, mesh/material/
   texture survival, animations, skeletons, collisions, and aggregate bounds.
3. Keep embedded textures self-contained when required by the project; do not use
   `.godot/imported/` as source material.
4. Capture imported rest-local transforms as regression values.
5. Write a project manifest only after the semantic and coordinate decisions are resolved.

Read [godot-mechanical-adapter.md](references/godot-mechanical-adapter.md) before implementing motion
or a passive mechanism.

## 4. Implement The Presentation Adapter

- Convert authority coordinates exactly once at the transport/adapter boundary.
- Apply the whole-machine root delta first.
- For each child joint, derive the adjacent parent-child authority rotation delta, clean it to the
  validated runtime axis, and apply it to the imported rest-local basis.
- Preserve the imported local origin and scale. Never independently calibrate every nested pivot by
  overwriting its world transform.
- Update authoritative/driven pivots parent-to-child; solve optional passive linkages afterward.
- On missing, non-finite, non-rigid, origin-drifting, materially off-axis, or unreachable input,
  retain the last valid visual pose and emit a stable diagnostic.
- Keep Godot visual/physics derivations presentation-only unless the project explicitly assigns
  authority elsewhere.

## 5. Verify Before Handoff

Automate all applicable checks:

- source bytes and SHA identity;
- import paths, parents, local origins, scales, materials/textures, bounds, and unexpected resources;
- zero plus one isolated pose per joint, at least one asymmetric pose, and zero restore;
- coordinate conversion, joint axis/sign, parent-to-child ordering, reconnect/stale/reset behavior;
- passive-link lengths, continuous branch selection, unreachable retention, and no NaN/Inf;
- project lint, tests, headless Godot import/runtime checks, and a human visual review.

For a Trellis-managed repository, follow its task/spec/check/commit workflow in addition to this
skill. Report separately what was observed, declared, validated, decided by the user, changed, and
still deferred.
