# Fine dirt 03

User-provided Fab texture set: Military Trenches Ground Dirt Fine 03,
asset ID `yd0jchk`. Source directory:
`C:/Users/Administrator/Downloads/military_trenches_ground_dirt_fine_03_yd0jchk_4k`.
The source asset's license continues to apply; this is not a CC0 declaration.

Generated with `tools/import_fine03_soil.py SOURCE_DIRECTORY` (Pillow).
Runtime images are 2048 square, downsampled from the supplied 4096 JPGs:
- `albedo.png`: Basecolor RGB, imported as color.
- `normal_roughness.png`: OpenGL Normal RGB, Roughness in alpha, linear data.

Keep normal-map compression disabled for this packed RGBA texture so roughness
alpha survives. Use high-quality VRAM compression and mipmaps. Source normal
orientation was checked against Displacement gradients at 1024 square:
R vs image X gradient -0.846; G vs image Y gradient +0.847, consistent with
OpenGL Y+. Metadata gives a 2 x 2 metre scan. No plant-removal edits were made.

Voxel layers share these images and use original-surface depth with a 0.18–0.42 m
transition and +/-0.06 m irregularity. This does not track the source depth of
redeposited soil. Bucket/release visuals reuse the images with a moderate tint.
