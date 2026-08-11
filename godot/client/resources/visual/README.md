# Godot visual adapter resources

This directory owns Godot-local visual mappings and calibration metadata. It does not replace the backend visual manifest or define simulator authority.

`sy205_visual_manifest.json` maps the five existing Python frame names to mechanical pivot nodes in the combined SY205 GLB. Python remains authoritative for motion; Godot applies received transforms to these presentation nodes.

The asset is already exported as glTF Y-up. The Python Z-up frame matrices are
converted once by `MotionProtocol.rows_to_transform()` using
`(x, y, z) -> (x, z, -y)` and full-transform conjugation. The manifest's source
`pivot_axis` values preserve Blender authoring metadata; its `coordinate_system`
section records the Godot runtime axes. Do not add a compensating rotation to
the imported scene.
