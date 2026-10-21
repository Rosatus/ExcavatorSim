# Implementation

- [x] Capture current scene and isolate soil update cost.
- [x] Implement bounded revision-aware exact-support admission.
- [x] Add focused regressions for halo-only material, protected samples, valid compaction and invalidation.
- [x] Verify parser and focused compaction tests; compare retained live scene after script reload.
- [x] Record evidence and contract, preserving unrelated working-tree changes.

Code is ready and applied to the retained live run. Git commit/archive remain pending; no unrelated changes were staged. Subjective driving review remains user-owned.

Agent automated: admission oracle/counters, existing material-cycle compaction test, same-scene objective FPS/timing sample. Human manual: drive across the retained slope and judge responsiveness.
