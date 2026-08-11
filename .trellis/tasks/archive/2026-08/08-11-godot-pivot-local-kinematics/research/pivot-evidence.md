# Pivot evidence

## Guide and GLB

The user guide defines the imported parent-local positions: root `(0,.45,0)`,
slew `(0,.46,0)`, boom `(-.119,.713,-.075)`, arm `(.066,4.295,3.915)`,
D `(-.008,-3.026,-.630)`, B `(-.008,-2.682,-.548)`, A `(.002,-.617,.206)`,
C `(0,-.397,-.279)`, and side controller `(-.006,-3.299,-.342)`.
Slew rotates Godot local Y; boom/arm/bucket/B/side rotate local X.

Raw GLB inspection confirms the exact hierarchy and these transforms. The GLB
SHA-256 is `cf95534b31bcc156980afefef0a9f273e5c6f727547b3db1e9062ca5619b495a`.
No asset re-export is required.

## Reproduction of the defect

Current code captures per-frame global calibration offsets and applies:

```text
W_i(q) = A_i(q) * (A_i(0)^-1 * G_i(0))
```

This preserves a global delta test because the offset cancels, but it does not
preserve adjacent GLB local transforms when parent and child authority frames
have different origins/rotations. For the existing asymmetric fixture, the
computed `arm -> bucket` local translation is approximately
`(-.008,-6.153,-.649)` instead of the guide's `(-.008,-3.026,-.630)`.

## Intended correction

Use `R0 = P0^-1 C0`, `Rq = Pq^-1 Cq`, `Delta = R0^-1 Rq`; keep the imported
local origin and apply only a clean runtime-axis rotation. Then run the existing
Godot-only passive linkage solver from the corrected hierarchy.
