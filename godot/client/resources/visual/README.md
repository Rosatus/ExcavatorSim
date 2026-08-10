# Godot visual adapter resources

This directory owns Godot-local visual mappings and calibration metadata. It does not replace the backend visual manifest or define simulator authority.

`sy205_visual_manifest.json` maps the five existing Python frame names to mechanical pivot nodes in the combined SY205 GLB. Python remains authoritative for motion; Godot applies received transforms to these presentation nodes.
