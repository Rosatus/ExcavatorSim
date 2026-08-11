# GLB-to-URDF Evidence

## Source Evidence

- Source GLB: `godot/client/assets/visual/SY205_excavator_godot.glb`
- Bytes: `4,904,884`
- SHA-256: `cf95534b31bcc156980afefef0a9f273e5c6f727547b3db1e9062ca5619b495a`
- Container: glTF 2.0, 20 nodes, 11 meshes, 9 materials, 2 embedded images, no skin,
  animation, or collision resources.
- Main hierarchy and parent-local pivots are validated by
  `godot/client/tests/sy205_glb_test.gd` and recorded in
  `godot/client/resources/visual/sy205_visual_manifest.json`.

## Coordinate Derivation

The project conversion is `p_g=(x_p,z_p,-y_p)`, therefore `p_p=(x_g,-z_g,y_g)`.

| Semantic frame | Godot local | Python local | Runtime axis |
| --- | --- | --- | --- |
| GLB root | `(0,.45,0)` | `(0,0,.45)` | none |
| slew | `(0,.46,0)` | `(0,0,.46)` | +Z after conversion |
| boom | `(-.119,.713,-.075)` | `(-.119,.075,.713)` | +X |
| arm | `(.066,4.295,3.915)` | `(.066,-3.915,4.295)` | +X |
| bucket | `(-.008,-3.026,-.630)` | `(-.008,.630,-3.026)` | +X |

The new URDF keeps `base_link` at world identity and folds root plus slew height into a
`swing_joint` Z origin of `0.91 m`.

## Geometry Findings

- POSITION accessor decoding can produce exact deterministic link-local vertex bounds.
- Decoding the bucket POSITION accessor through the complete node relation
  `inverse(bucket_pivot_world) * bucket_mesh_world` and then applying the Godot-to-Python basis
  produces bucket-local bounds `x=[-.649909,.661457]`, `y=[-.108453,1.115756]`,
  `z=[-.433944,1.159777]`. Godot MCP independently reproduced these bounds from the imported
  `PackedScene` AABB and the same parent-local transform on 2026-08-11.
- The earlier planning estimate `y=[-.841777,.751944]`, `z=[-.797756,.426453]` omitted the bucket
  mesh node's local rotation/translation and is superseded by the imported-scene check above.
- The deterministic tooth rule selects the outer clusters in a 20 mm maximum-`+Y` front band and
  defines the center marker as their midpoint. The generated center is approximately
  `(0.000955,1.114953,0.216117)` and remains an estimate for later ordinary Godot inspection.
- Visual mesh volume is not physical mass: wall thickness, material density, counterweights,
  hydraulics, and hidden components are absent. Mass, center of mass, inertia, and collision proxies
  must be labelled provisional.

## Backend And Compatibility Findings

- Backend validation requires four named active joints, eleven required frames, and exactly four
  velocity coordinates (`backend/src/babylon_sim/model.py:75-119`).
- Terrain consumes the three tooth frames (`backend/src/babylon_sim/runtime.py:434-452`).
- `docs-urdf-v3` is hard-coded in backend, protocol manifest/schema, Godot constants, and tests.
- Backend parity fixtures compare matrices at `1e-12` tolerance.
- RRD import already rejects a different model version. No recording migration work is needed for
  this model replacement.
- Provenance currently describes the URDF as an upstream verbatim generated asset. A GLB-derived
  URDF needs a new generated relationship and source-hash chain.

## Resolved Decisions

- Human mapping gate is empty: exact pivot paths, hierarchy, axes, units, handedness, neutral pose,
  and writable driven/passive nodes are already validated in repository contracts.
- User approved reasonable estimates for missing URDF fields.
- Protocol message shape remains v3; model identity changes to `sy205-glb-urdf-v4`.
- The old URDF is retained only as a future SY135 reference, not as an SY205 compatibility model.
