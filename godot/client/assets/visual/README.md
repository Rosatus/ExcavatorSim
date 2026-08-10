# SY205 visual asset

`SY205_excavator_godot.glb` is the exact user-supplied combined excavator scene used by the Godot client.

- Source: `E:/projects/blender/Excavator/SY205/export/godot/SY205_excavator_godot.glb`
- Copied: 2026-08-10
- Size: 4,904,884 bytes
- SHA-256: `cf95534b31bcc156980afefef0a9f273e5c6f727547b3db1e9062ca5619b495a`
- Format: glTF 2.0 binary; Blender glTF I/O v5.2.39
- Textures: embedded in the GLB; no external texture files are required
- Godot import: `gltf/embedded_image_handling=2` keeps the embedded images in the imported scene using Basis Universal instead of generating source-adjacent PNG sidecars

Do not re-export or rewrite this file during client development. Replace it only through a reviewed asset update with a new hash and adapter validation.

Track the adjacent `.glb.import` file because it owns this reproducible embedded-texture policy. Do not track generated `.godot/` cache files or extracted texture sidecars.

This combined asset is independent of the legacy five-file backend visual manifest under `assets/visual/original/`. Godot uses the local mapping contract in `res://resources/visual/sy205_visual_manifest.json`; the Python protocol identifiers remain unchanged.
