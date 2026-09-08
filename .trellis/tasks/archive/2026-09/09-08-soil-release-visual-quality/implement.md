# Implementation

1. Add shared ballistic timing and explicit material flight transfers; integrate bounded release/arrival queue and prevent arrival event replay.
2. Replace box visuals with reusable irregular meshes, add triplanar soil material and soft dust alpha.
3. Add focused regression for mass lifecycle and release-before-ground, gate closure/reset, and resource reuse.
4. Run narrow Godot checks, inspect whole task diff, update boundary contract and result.
5. Follow-up: reproduce long empty-bucket dump, suppress sub-visual residue relaunch, connect final flight retirement, and remove voxel flow fallback.
6. Follow-up: add bounded engaged-lift contact continuation and rotation-aware sampling; prove native surface roof changes from solid/surface to air while retaining unengaged rejection tests.
7. Screenshot follow-up: replace gapped circular-lane cross-sections with radius-derived coverage, preserve cutoff intersections, align lift contact footprint, and validate the entire inner volume through exit. Results: `research/lift-volume-followup.md`.
8. Second screenshot follow-up: replace the local +Y roof face with the actual world-vertical lower envelope; validate shallow rotated roof projection and a 12-step native lift with exterior ground control. Results appended to `research/lift-volume-followup.md`.
9. Repeated manual failure: reproduce partial-cell credit blocking native recuts; separate zero-credit geometry transactions from ledger deduplication, preserve world publication/readiness, and test normal/full capacity and no repeated credit. Results: `research/residual-credit-followup.md`.
10. Continuous lift follow-up: separate retained excavation episode from this-frame contact; commit entry before hold and scan the entire historical footprint at real cadence. Results: `research/lift-episode-followup.md`.
11. Live field diagnosis: save native SDF and user-operated motion; replay the actual residual, cover the tooth-to-floor working lip and its roof, preserve path boundaries, verify recorded targets and exterior controls. Results: `research/live-residual-evidence.md`.

Agent checks: Godot custom Voxel Tools executable at E:/applications/godot_voxel/godot.windows.editor.x86_64.exe; headless focused scripts under godot/client/tests. Preserve unrelated addon/worldbuilding/config edits. No commit or push requested in this turn.

Human manual: SY135 scoop, high/low stationary and moving dump, close bucket mid-flow, reset, re-excavate; inspect surface detail and smoothness. Record pending until user reports outcome.
