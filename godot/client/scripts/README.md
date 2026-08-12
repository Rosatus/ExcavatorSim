# Godot scripts

Runtime and editor-facing GDScript for the ExcavatorSim client belongs here. Keep motion transport, world state, presentation and UI concerns in separate modules.

`TerrainState` and `BucketSoilState` own deterministic excavation semantics;
`Terrain3DAdapter` is a disposable, snapshot-driven rendering/collision backend
with the custom terrain renderer and collider retained as fail-open fallbacks.
`ConstructionSiteTerrainProfile` expands accepted snapshots into a project-owned
64 m presentation site while preserving the logical patch point-for-point.
