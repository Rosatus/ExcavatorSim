# Technical Design

## Scene boundary

```text
Main (Node3D)
├── WorldEnvironment
├── KeyLight (DirectionalLight3D)
├── Camera3D
├── ExcavatorRig (Node3D)
│   └── base_link (Node3D)
│       └── upper_structure_link (Node3D)
│           └── boom_link (Node3D)
│               └── arm_link (Node3D)
│                   └── bucket_link (Node3D)
├── TerrainRoot (Node3D)
├── PresentationRoot (Node3D)
└── OperatorUI (CanvasLayer)
```

The five named nodes are stable attachment points, not simulation logic. Their hierarchy may later be adjusted if the authoritative frame relationship requires it, but names must remain compatible with the visual manifest and motion client.

## Placeholder policy

Use lightweight primitive meshes or visible markers only to make the scene inspectable. Do not encode excavator dimensions, collision behavior, terrain edits or input semantics in the placeholders. When the GLB arrives, replace visual children without changing the frame nodes.

## Validation boundary

This child validates project import, scene structure, MCP connectivity and a minimal run. It does not connect to Python, implement terrain, or establish the final visual look.
