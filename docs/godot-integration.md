# Godot Integration Boundary

## Intended client

The future client targets Windows desktop with Godot Forward+. It should load the five-part excavator GLB visual skin and apply the authoritative named-frame transforms received from Python.

## Transport

The first Godot adapter should consume the Godot/Pinocchio HTTP/WebSocket contracts rather than inventing a second authority protocol. It needs equivalents of:

- realtime state handshake and state snapshots;
- input command validation and acknowledgements;
- terrain view snapshots and absolute-height patches;
- terrain epoch/revision identity and stale/gap recovery;
- recording/replay and Return-to-Live lifecycle semantics.

### Frame coordinate conversion

The Python Pinocchio/URDF authority publishes right-handed Z-up frame matrices,
while the supplied glTF scene is already exported for Godot's right-handed
Y-up space. The client converts each complete matrix once at the protocol
boundary:

```text
p_godot = (x_python, z_python, -y_python)
T_godot = C * T_python * inverse(C)
```

This maps Python +Z slew to Godot +Y and keeps the Python +X work-equipment
hinges on Godot +X. The SY205 import guide is the asset-side reference for this
mapping; do not add a second global ±90-degree scene rotation or per-pivot axis
swap. The imported GLB parent-local pivot origins are retained; adjacent
converted frame relations provide only the local single-axis joint rotations.

## Authority boundary

Python remains authoritative for joint state, input safety and lifecycle in every
profile. The Godot/Pinocchio profile remains authoritative for terrain
layers, bucket inventory, events, recording and replay. The approved Godot-first
local-world profile used by the realistic client instead keeps deterministic
terrain/world and convenience bucket state in Godot; it does not mirror Python
terrain packets or publish local terrain, physics transforms or replay cursors
back to Python. The two profiles coexist until the integration release-candidate
review selects one runtime contract.

The M5 excavation path keeps `BucketSoilState` as the one local inventory owner:
fixed-step cut/deposit commands use explicit bucket contact proxies and conserve
the changed grid-cell volume. `TerrainCollider` is a copied, generation-gated
static derivative and is disabled/fail-open when local physics is unavailable;
its failure cannot stop motion or terrain presentation.

The realistic visual pass uses a procedural sky/ambient environment, a
generation-gated soil particle emitter and a bounded camera/quality controller.
These are disposable presentation resources; changing their profile cannot
alter motion cadence, terrain snapshots, bucket volume or any Python message.

### SY205 passive four-bar linkage

The supplied SY205 import guide defines a Godot-only passive linkage because
the GLB intentionally contains no Blender drivers or animation tracks. After
the authoritative base delta and adjacent local pivots are updated, the client solves in
`PIVOT_ARM_JOINT` local Y-Z space using D=`PIVOT_BUCKET_JOINT`,
B=`PIVOT_LINKAGE_B_ARM`, A=`PIVOT_LINKAGE_A_COMMON` and
C=`PIVOT_LINKAGE_C_BUCKET`. AB and AC are captured from the imported zero pose;
the continuous circle-intersection branch gives A, B rotates around +X, and
`CTRL_LINKAGE_SIDE_LINKS` is positioned/rotated along A-C. A and C are never
written directly. Unreachable poses retain the last valid passive pose and
remain a visual diagnostic; no linkage result is sent back to Python. Nested
pivots must not be updated by independent calibrated world transforms because
that changes the parent-local pin positions and detaches boom/arm/bucket joints.

## Terrain and physics seam

Godot should build a derived render mesh from the selected surface snapshot. A later physics adapter may maintain chunked static terrain colliders and local probes. Collider updates must be generation-gated and stale-safe; a disabled or failed physics backend must leave the Python service and visual state usable.

The first soil presentation is not a per-grain rigid-body simulation. It combines the authoritative stable/loose heightfield and bucket volume with bounded visual particles or clumps. Those effects are disposable presentation state and must clear on historical seek, reset, reconnect, and authority-generation changes.

## Deferred model decisions

The current GLBs are visual assets. URDF collision geometry, mass/inertia, hydraulic forces, material contact parameters, bucket cavity calibration, and a fully dynamic articulated excavator require a separate model contract and are not part of this bootstrap.
