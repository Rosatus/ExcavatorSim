# Godot visual adapter resources

This directory owns Godot-local visual mappings and calibration metadata. It does not replace the backend visual manifest or define simulator authority.

`sy205_visual_manifest.json` maps the five existing Python frame names to mechanical pivot nodes in the combined SY205 GLB. Python remains authoritative for motion; Godot derives local presentation rotations for these nodes without replacing their imported pin origins.

The asset is already exported as glTF Y-up. The Python Z-up frame matrices are
converted once by `MotionProtocol.rows_to_transform()` using
`(x, y, z) -> (x, z, -y)` and full-transform conjugation. The manifest's source
`pivot_axis` values preserve Blender authoring metadata; its `coordinate_system`
section records the Godot runtime axes. Do not add a compensating rotation to
the imported scene.

The manifest's `local_kinematics` section records the guide-backed parent-local
pivot positions and runtime axes. `MotionPresentation` derives adjacent-frame
rotation deltas after the one protocol coordinate conversion, preserving those
origins. Its `passive_linkage` section mirrors the supplied import guide's
visual-only A/B/C/D contract: it solves AB/AC in the arm local Y-Z plane and
rotates only the B rocker and `CTRL_LINKAGE_SIDE_LINKS`. The GLB remains static
and no passive linkage transform becomes Python, terrain, tooth or physics
authority.
