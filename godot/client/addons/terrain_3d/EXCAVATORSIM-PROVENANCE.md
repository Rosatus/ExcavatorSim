# Terrain3D provenance

- Upstream: https://github.com/TokisanGames/Terrain3D
- Local package version: 1.0.2 (`plugin.cfg`)
- License: MIT (`LICENSE.txt`)
- Integration role: derived Godot terrain rendering and optional collision
- Logical authority: `TerrainState` / `BucketSoilState`, not Terrain3D

The package was supplied locally by the project user. The current temporary
visual baseline intentionally reuses the official demo's four ground textures,
RockA/B/C meshes, grass particle scene, and extracted material configuration.
Unrelated demo gameplay, UI, navigation, and height data are not packaged.
ExcavatorSim still owns the height/control maps and logical terrain; demo terrain
heights are not imported into `TerrainState`.

Godot may create temporary hot-reload DLL copies named `~*.TMP` in `bin/`.
Those files are editor runtime artifacts and are excluded from source control.
