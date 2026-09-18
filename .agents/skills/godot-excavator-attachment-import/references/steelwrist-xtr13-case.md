# Worked Example: Steelwrist XTR13 + GB12

Concrete data for the `xtr13_gb12` / `xtr13_bare` catalog entries, as validated against the GLB
`AnimationPlayer` playback. Use these numbers as a sanity reference when importing similar
tiltrotator attachments.

## Source

- Blender dir: `E:\projects\blender\Excavator\Attachments\Steelwrist_Animated`
- Docs: `装配与动画说明.md`
- GLBs: `godot/client/assets/visual/XTR13_Tiltrotator_Animated.glb`,
  `godot/client/assets/visual/GB12_S50_Bucket.glb`

## Authored hierarchy

```text
XTR13_ROOT                      (mount root → parents to PIVOT_BUCKET_JOINT/AttachmentMount)
└─ UPPER_FIXED
   ├─ CYLINDER_L_PIVOT          (passive: rotation)
   ├─ CYLINDER_R_PIVOT          (passive: rotation)
   ├─ Tilt cylinder | chrome piston        (passive: rotation + translation)
   ├─ Tilt cylinder | chrome piston.001    (passive: rotation + translation; imports as _001)
   ├─ <hose meshes>              (passive: 18-target morph weights)
   └─ TILT_Y                    (driven: local +Z, ±45°)
      └─ ROTATE_Z               (driven: local +Y, wraps ±180°)
         └─ S50_TOOL_SOCKET
            └─ GB12_ROOT        (tool mount, identity transform)
```

Note the passive pistons live under `UPPER_FIXED`, not under `TILT_Y` — bake paths from the glTF
node graph.

## Animation clips

`Tilt_45` is the tilt authority: non-monotonic `0 → +45 → 0 → -45 → 0`, 193 uniform keys shared
across all channels. Tracks encode **absolute local TRS**. `Rotate_360` moves only `ROTATE_Z` —
passive tilt nodes do not respond to rotation, so a single tilt-keyed table suffices.

Passive channel set per tilt key:

- `CYLINDER_L_PIVOT`, `CYLINDER_R_PIVOT` — rotation
- both `Tilt cylinder | chrome piston*` — rotation + translation
- hose meshes — `weights` channel, flat `193 × 18` scalars (targets `TILT_M45…M05`, `TILT_P05…P45`)

## Verified values

- At −45°: `CYLINDER_L_PIVOT` q.z ≈ −0.2296, `CYLINDER_R_PIVOT` q.z ≈ −0.1994
- Morph one-hot: `TILT_P45 = 1.0` at −45°, `TILT_M45 = 1.0` at +45° (target naming is inverse to
  joint sign in the authored data — trust the baked table, not the name)
- Rod-end ↔ bracket-pin distance stays constant across ±45° (rigid-rod invariant)
- E2E parity vs `AnimationPlayer` at +45°: position diff < 1.1 mm, rotation diff < 0.08°,
  weight diff < 0.005

## Catalog entries (v2 schema)

The catalog splits **couplers** (mount platform) from **tools** (socket payload). Tools declare
`supported_couplers`; switching either side auto-resolves the other to the first compatible
entry. `coupler_id "none"` = direct pin mount. `kind: "native"` tools are the host model's own
bucket mesh — they show only with a direct-pin coupler.

```json
{
  "couplers": [
    { "coupler_id": "none", "display_name": "无（直接销接）", "kind": "direct_pin" },
    {
      "coupler_id": "xtr13", "kind": "tiltrotator",
      "mount": {"parent_frame": "bucket_link"},
      "rotator_glb_path": "res://assets/visual/XTR13_Tiltrotator_Animated.glb",
      "rotator_root_node": "XTR13_ROOT",
      "socket_node_path": "XTR13_ROOT/UPPER_FIXED/TILT_Y/ROTATE_Z/S50_TOOL_SOCKET",
      "tilt_rig_path": "res://resources/attachments/xtr13_tilt_rig.json",
      "joints": {
        "tilt_node_path": "XTR13_ROOT/UPPER_FIXED/TILT_Y",
        "tilt_local_axis": "z", "tilt_range_deg": [-45, 45], "tilt_rate_dps": 60,
        "rotate_node_path": "XTR13_ROOT/UPPER_FIXED/TILT_Y/ROTATE_Z",
        "rotate_local_axis": "y", "rotate_rate_dps": 90
      },
      "controls": {
        "tilt":   {"modifier_key": "KEY_Q", "negative_action": "operator_bucket_curl",
                   "positive_action": "operator_bucket_dump", "masked_axis": 3},
        "rotate": {"modifier_key": "KEY_O", "negative_action": "operator_swing_left",
                   "positive_action": "operator_swing_right", "masked_axis": 0}
      },
      "hidden_frame": "bucket_link"
    }
  ],
  "tools": [
    {"tool_id": "standard_bucket", "kind": "native", "supported_couplers": ["none"]},
    {"tool_id": "gb12", "kind": "bucket", "supported_couplers": ["xtr13"],
     "tool_glb_path": "res://assets/visual/GB12_S50_Bucket.glb",
     "tool_root_node": "GB12_ROOT",
     "soil_contract_path": "res://resources/attachments/gb12_s50_soil_contract.json"},
    {"tool_id": "no_tool", "kind": "none", "supported_couplers": ["xtr13"]}
  ]
}
```

`masked_axis` indexes the base command tuple `(swing, boom, arm, bucket)`: tilt borrows index 3
(bucket curl/dump), rotate borrows index 0 (swing). `kind: "native"` tools render the host
model's own bucket mesh — they appear only with a direct-pin coupler and carry no GLB.
