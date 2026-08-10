# Technical Design

## Scope and boundary

This child task owns the supplied visual asset's placement, import validation, and adapter contract. It does not implement WebSocket transport or motion input. M2 consumes the adapter contract and drives the same five frame names already used by the Python protocol.

The GLB remains a presentation resource. Python owns authoritative joint state and frame transforms; Godot maps those transforms to imported visual pivots. No local physics, mesh node, or linkage simulation may publish state back to Python.

## Asset layout

```text
godot/client/
├── assets/visual/SY205_excavator_godot.glb  # exact supplied bytes
└── resources/visual/
    ├── README.md
    └── sy205_visual_manifest.json           # Godot-local mapping/calibration contract
```

The asset file keeps the user's original basename to make provenance and hash checks unambiguous. The Godot-local manifest is intentionally separate from `assets/visual/original/visual-model-v1.json`; the backend's five-file protocol manifest is not changed.

## Imported scene mapping

Instantiate the GLB as a single scene under the existing `PresentationRoot`. Preserve the GLB's mechanical hierarchy and use these pivot aliases:

```text
base_link             = CTRL_EXCAVATOR_ROOT
upper_structure_link  = CTRL_EXCAVATOR_ROOT/PIVOT_SLEW
boom_link             = CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE
arm_link              = CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT
bucket_link           = CTRL_EXCAVATOR_ROOT/PIVOT_SLEW/PIVOT_BOOM_BASE/PIVOT_ARM_JOINT/PIVOT_BUCKET_JOINT
```

The mapping is to pivot nodes rather than mesh nodes. That keeps the supplied linkage and downstream visual hierarchy intact and ensures a later pose update can set the five pivot globals without duplicating mesh instances. The four-bar linkage nodes remain attached to their imported parents and are marked visual-only.

## Calibration and frame parity

The adapter records an imported rest-pose transform for each mapped pivot and a single asset-root presentation calibration. M2 then computes target pivot transforms from the Python `frame_transforms` and applies them in parent-to-child order. The calibration process is:

1. Import the GLB in Godot and capture the actual `Transform3D` values after glTF-to-Godot conversion.
2. Compare the imported zero pose with `backend/tests/fixtures/frame-parity/baseline.json`.
3. Solve/store only the visual calibration needed to align the asset root and five pivot frames; do not alter wire matrix semantics.
4. Re-run zero and asymmetric pose fixtures. Interpolation is added by M2 only within one motion generation.

The first implementation must fail loudly in the test harness when a mapped node is missing, a calibration entry is malformed, or the imported bounds are outside the measured inspection envelope. It must not silently rename protocol frames.

## Validation and rollback

- Validate source and copied hashes before and after the copy.
- Use Godot MCP state/filesystem/scene inspection and a headless import script.
- Inspect editor logs for import errors and verify the five mapping targets.
- If import or parity fails, keep the placeholder foundation scene usable and disable the asset instance; do not modify backend or protocol files.
- Keep no generated `.godot` cache, export, or temporary texture files in the repository.
