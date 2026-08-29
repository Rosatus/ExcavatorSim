# Terrain3D restoration roadmap

Parent/child links do not enforce execution order. The following gates are
mandatory and repeated in each child PRD.

| Phase | Task | Deliverable | Exit gate |
|---|---|---|---|
| 0 | `08-29-terrain3d-forwardplus-render-spike` | Godot 4.7 Forward+ compatibility proof | Stable non-black native frame and bounded failure diagnosis |
| 1 | `08-29-terrain3d-material-visual-parity` | Terrain3D-compatible procedural soil material | Approved worksite-soil look; no demo vegetation/dressing/background |
| 2 | `08-29-terrain3d-snapshot-lifecycle-fallback` | Ordered native lifecycle and fail-open presentation | Incremental/full paths, no stale replace, one visible surface, tests restored |
| 3 | `08-29-terrain3d-authority-collider-regression` | Native-vs-fallback authority equivalence | Identical terrain/ledger/payload/Jolt truth; project collider remains sole query surface |
| 4 | `08-29-terrain3d-product-cutover-export-validation` | Product default and release evidence | Full gates plus editor/export rendered parity and rollback proof |

## Parent integration acceptance

- Native Terrain3D is the visible production terrain renderer.
- The project procedural soil look and existing environmental composition remain.
- Terrain3D is never gameplay, soil, payload, physics, or collision authority.
- The old renderer remains a synchronized, explicit, tested fallback.
