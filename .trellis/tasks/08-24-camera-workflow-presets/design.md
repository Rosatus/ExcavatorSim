# Design — camera workflow presets

## Single-camera mode controller

`CameraRig` remains the only product `Camera3D`. It owns four named modes:
`operator`, `chase`, `work_tool`, and `inspection`. Each mode resolves a semantic
anchor from `MotionPresentation` (`upper_structure_link`, `base_link`, or
`bucket_link`) and applies model-specific framing hints for SY205/SY135. Missing
anchors fall back to `base_link`; invalid/freed nodes are never followed.

The camera computes a desired focus/position every frame, then uses bounded
time-based smoothing. Chase orientation follows the projected base forward,
operator follows upper-structure heading, work-tool follows the live bucket
position while orienting relative to the machine, and inspection preserves free
orbit state. Reset/model/authority boundaries clear orbit and occlusion
transients and reapply the current mode's model preset.

## Input and discoverability

Runtime input registration adds 1/2/3/4 plus gamepad D-pad mode selection and C
plus right-stick-click reset. Existing middle-drag orbit and wheel zoom remain;
orbit adjustments are preserved only as mode-local transients. Because camera
handling stays in `_unhandled_input`, UI-consumed events do not reach it.

`MotionOperatorUI` exposes the active named mode, a selector, and Reset View.
The control guide centralizes mouse, keyboard, and gamepad camera instructions.

## Occlusion and clip safety

Before applying a desired position, `CameraRig` performs one read-only ray query
from outside the mode's minimum focus radius toward the camera using terrain and
machine masks. A hit shortens the camera to a clearance before the surface;
inward correction is immediate and outward recovery is smoothed. Missing/stale
collision data fails open to the bounded preset rather than mutating simulation
collision or blocking operation. Near clip is selected from the resolved safe
distance and held inside conservative limits.

The query has a deterministic override seam and publishes compact camera state
for tests and HUD; neither seam writes physics state.

## Quality and compatibility

Low/balanced/high continue to own the far plane and maximum camera distance.
All presets clamp to the active quality distance. The optional gateway and local
authority paths both reset camera transient state from their existing authority
signals. No model-specific visual child path is cached beyond the current
`model_activated` generation.

## Validation strategy

One focused headless contract runs four modes across both models, input/reset,
freed-node switching, finite framing, deterministic occlusion/recovery, near
clip safety, and quality clamping. Existing offline and visual state tests cover
main-scene integration. Screenshot composition review remains deferred to the
final human product-experience milestone.
