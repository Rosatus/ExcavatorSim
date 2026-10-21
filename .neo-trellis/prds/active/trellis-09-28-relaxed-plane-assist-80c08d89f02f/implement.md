# Relaxed plane assist implementation

2026-09-28 user request: constrain only cutting line to work plane, free pitch throughout, replace algorithm if needed.

Implemented by main agent only:
- GuidedProfileStage uses relaxed solve from first driven tick, preserves original level reference during stroke, mode changes relatch cleanly. Strict DLS/block policy remains.
- AssistRateSolver 27 active-set box/equality solve: normal task lexicographic priority, tangent least squares + small joint-centering cost; asymmetric cut/limit ceilings, acceleration/jerk reachable bounds, braking law. No uniform starvation fallback.
- EquipmentKinematicsContext exact plant response and bracket inversion, validated against real articulation through loaded acceleration reversals.
- Pipeline current-chassis FK, active tool contract/mount, outer teeth segment (same radius-offset geometry as soil samples), mounted point velocity feedforward, no-tool zero output. Runtime forwards tool/mount and converts COM velocity to chassis-origin velocity.
- Edge midpoint does not falsely claim line tangency on transverse roll/tilt: >2cm normal endpoint span emits edge_tilt diagnostic. Coplanar 3 joints cannot correct arbitrary transverse edge tilt.
- Updated menu tooltip and model-joint-semantics contract. Preserved unrelated preexisting dirty changes, no commit or export.

Agent automated:
- relaxed_surface_assist_test PASS final including 100 feasible bounded-solver cases, exact plant inverse 180 loaded reversal ticks, geometry/no-tool/fixed-target tests, moving chassis+pitching mount 360 ticks (max error .00165m), flat and +/-20deg strokes both directions + reversal 900 ticks each (max endpoint error .01342m).
- Shared bound 4s: strict .0326986m vs relaxed 2.34628m; max relaxed pitch step .0134604rad, no angle-wrap artifact (test correctly uses wrapped angular differences).
- assist_modes_test PASS including existing mode propagation/simple digging (before final COM/mount feedforward; these edits do not affect its static standalone/native cases).
- bucket_level_assist_test final PASS after COM fix, both existing model cases. Final relaxed_surface_assist_test PASS including added contact-bypass mount-history regression; no stderr. Logs TEMP/<test>.out/.err.
- Scoped git diff --check PASS.
- Read-only support_review found COM and moving-mount feedforward gaps; both fixed with moving-geometry regression. No QP or bracket inversion defect found.

Human manual: pending user control-feel assessment. Run source SY135, enable relaxed in Advanced, use level and +/-slope passes with W/S then reverse near endpoint; confirm longer usable stroke, stable line, no pitch snap. Exported client remains previous version.

Delivered source implementation and automated validation. Human control-feel review remains pending; no export/commit performed. Contact bypass has independent accepted assist-mount history so clearing solid sweep history cannot erase mount feedforward. Next: user tests source/newly exported client; investigate only concrete reported remaining symptoms.


## Exterior contact correction — 2026-09-28
User reported teeth-only tracking leaves the floor/back below the grading
surface. Main agent replaced relaxed support geometry with all solid semantic
samples (teeth/side cutters/floor/outer shell); excludes cavity/opening. Cached
on tool change, transformed with active mount each tick. Selected support point
owns Jacobian, chassis and mount feedforward. Flat latches lowest exterior;
slope evaluates each point on actual profile, including bench/knee.

Discriminating trajectory evidence: simply changing support at original speed
produced 3–13.5cm transient penetration from acceleration/jerk at contact changes.
Experimental multi-plane/smoothing solves were removed; final uses original
bounded normal-priority solver with precision travel 30% of configured speed
and milder joint centering (.036 vs .12). Tooltip and current joint contract
state this tradeoff. No new QP or smoothing approximation remains.

Agent automated: relaxed_surface_assist_test and assist_modes_test PASS final,
exit 0, stderr empty. Actual SY135 loaded flat/+20/-20 strokes both directions
900 ticks each with reversal: worst exterior penetration .00868m; continuous
pitch; flat cases prove teeth may lift >5cm. Moving mount/chassis max .00448m.
Geometry coverage compares mounted SY135/SY80U/GB12 exterior against soil tool
snapshot; bench/slope knee regression included. Bound stroke remains .349m vs
strict .0327m. Final strict bucket_level_assist_test PASS (SY135/SY205), exit 0 and empty stderr.
Logs TEMP/<test>-exterior.out/.err. git diff --check PASS.

Human manual still pending: source run relaxed level/slope with varied bucket
curl, inspect bottom/back contact and reduced precision speed. No export,
commit, or claimed universal zero-penetration guarantee. Uses existing semantic
solid geometry, not a new mesh collider. Preserved two pre-existing untracked
SY80U test UID sidecars. Next: human source control-feel/contact review; automatic validation complete.
