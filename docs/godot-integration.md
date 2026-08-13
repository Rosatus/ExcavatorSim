# Godot Integration Boundary

## Implemented client baseline

The current client targets Windows desktop with Godot Forward+. It loads the
combined SY205 excavator GLB visual skin and applies the authoritative
named-frame transforms received from Python through the Godot-Pinocchio motion
transport.

## Transport

The Godot client consumes the existing Godot-Pinocchio HTTP/WebSocket contracts
rather than inventing a second authority protocol. The implemented motion slice
covers:

- the realtime state handshake and authoritative motion snapshots;
- input sequence safety, command validation, acknowledgements, and lifecycle
  state;
- session, simulation-epoch, view-revision, reconnect, and stale-state guards.

The Godot-first client owns its local terrain and bucket-soil state, so it does
not mirror legacy Python terrain packets or recording/replay cursors. Those
terrain, recording, replay, and Return-to-Live contracts remain available only
where the legacy Python runtime profile is selected.

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

Python remains authoritative for joint state, input safety and lifecycle in
every profile. The `legacy` Python runtime profile remains authoritative for
terrain layers, bucket inventory, events, recording and replay. The
`motion-only` backend profile supplies the motion/input contract to the
Godot-first local-world client, which keeps deterministic-enough terrain/world
and convenience bucket state in Godot; it does not mirror Python terrain
packets or publish local terrain, physics transforms or replay cursors back to
Python. The two profiles coexist until the integration release-candidate
review selects one runtime contract.

The M5 excavation path keeps `BucketSoilState` as the one local inventory owner:
fixed-step cut/deposit commands use explicit bucket contact proxies and conserve
the changed grid-cell volume. `TerrainCollider` is a copied, generation-gated
static derivative and is disabled/fail-open when local physics is unavailable;
its failure cannot stop motion or terrain presentation.

The realistic visual pass uses Sky3D 2.1 behind the project-owned
`VisualEnvironment` seam, plus a generation-gated soil particle emitter and a
bounded camera/quality controller. The root node keeps the stable
`WorldEnvironment` path while Sky3D owns the actual sky shader, SunLight,
SkyDome, fog, and cloud resources. The scene is fixed at 10:30 using Sky3D's
SIMPLE celestial mode (19.5-degree polar angle, approximately 70.5-degree solar
elevation) with editor/game time progression, system synchronization, moon/deep
space calculations, and cloud wind disabled. The legacy root
`KeyLight` remains present but inactive so Sky3D's SunLight is the only daytime
directional light. Low disables clouds/fog/shadows, balanced restores restrained
atmosphere, and high raises the same visual features without altering the 60 Hz
simulation/transport contracts. These are disposable presentation resources;
changing their profile cannot alter motion cadence, terrain snapshots, bucket
volume, replay state, or any Python message. Profile-application failure is
propagated through `VisualQualityController`, and the running UI retains the
required ESO/S. Brunier Milky Way attribution.

Terrain3D's optional infinite world background is disabled in this composition;
its generated cliff shell would otherwise cover the Sky3D horizon. The bounded
64 m site terrain, official surface assets, rocks, grass, and logical excavation
contracts remain unchanged.

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

Godot builds a derived render mesh from its selected local surface snapshot.
`TerrainCollider` provides the optional chunked static-collider/contact seam and
is generation-gated, stale-safe, and disabled/fail-open by default. A disabled
or failed physics backend must leave the Python service and visual state usable.

The optional `Terrain3DAdapter` is another derived backend. It receives copied
`TerrainState.surface_snapshot()` data only after the fixed-step logical edit has
been accepted. `TerrainState` keeps the stable/loose Float32 layers, revision
and generation guards, while `BucketSoilState` remains responsible for bucket
capacity and grid-cell volume accounting. Terrain3D is therefore a rendering,
heightmap materialization, and optional collision provider; editor sculpting or
direct native height edits are not gameplay mutation paths. If its GDExtension,
map import, or collision mode is unavailable, the custom mesh/collider path
continues to provide the fail-open fallback.

Terrain3D 1.0.2 performs native setup on enter-tree. The adapter assigns
non-null assets/material before adding the node, then assigns `region_size=128`
and collision mask after it enters the tree because native initialization
restores those scalar defaults. Native activation hides both the custom terrain
mesh and `FoundationGround`; queued or failed native work restores both fallback
layers immediately.

The current temporary Terrain3D visual baseline intentionally reuses a minimal
production extraction of the official Terrain3D demo assets and material
configuration. A project-owned
`ConstructionSiteTerrainProfile` still builds the 64 m × 64 m derived
height/control map around the accepted 20 m logical patch, but its two material
IDs select the demo cliff/bare-ground and grass slots. The adapter loads the
extracted demo `Terrain3DMaterial`, including projection, dual scaling, macro
variation, auto-shader, and world-background parameters.

`TerrainState` algorithm `godot-terrain-state-v2-flat` initializes the logical
patch as a true zero-height plane, so the excavator starts on flat ground.
Official RockA/B/C meshes are placed outside that patch through bounded
`MultiMeshInstance3D` layers. The official grass particle scene is retained
outside a 12 m central exclusion radius. Demo height maps are never imported as
logical state, and these presentation objects add no collision authority.

When enabled, Terrain3D may generate static collision shapes. Jolt remains the
Godot 3D physics backend that queries and solves against those shapes; it does
not become an authority for terrain deformation, excavator motion, bucket
inventory, or Python state. The data flow is one-way:

```text
fixed-step command -> TerrainState/BucketSoilState -> snapshot -> Terrain3D -> Jolt query
```

The first soil presentation is not a per-grain rigid-body simulation. It combines the authoritative stable/loose heightfield and bucket volume with bounded visual particles or clumps. Those effects are disposable presentation state and must clear on historical seek, reset, reconnect, and authority-generation changes.

## Deferred model decisions

The current GLBs remain visual assets. URDF collision geometry, mass/inertia,
hydraulic forces, material contact parameters, bucket cavity calibration, and a
fully dynamic articulated excavator require a separate model contract and remain
deferred from this release candidate.
