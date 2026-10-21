# Extend optional map view distance

User request: distant scenery disappears too early in urban and construction.

Set a 1500 m camera far-plane floor for loaded optional maps across quality
profiles, preserving training defaults and camera orbit zoom limits. Extend
construction's authored small/mid prop ranges from 110/160 m to 400/600 m,
including its authoring tool. Rebuild the construction pack copies.

Acceptance: actual packed map startup and profile changes retain 1500 m far
planes, camera orbit limits remain unchanged, loaded construction props have
the extended ranges, returning to training restores its profile defaults.
Subjective visibility/performance review remains with the user.

Progress: implementation and objective validation complete; uncommitted.
Existing unrelated worktree edits preserved.

- Client optional-map floor is 1500 m; training and orbit limits unchanged.
- Updated all 48 construction prefabs plus authoring constants to 400/600 m.
- Rebuilt both construction pack copies with the pinned local editor and
  `tools/build_construction_pack.ps1 -SkipImport`; texture budget check passed.
- `map_view_distance_test.gd`: PASS against real urban/construction packs,
  all quality profiles and subsequent training startup. No script/engine errors.
- `git diff --check` passed for affected source scope.
- Logs: `artifacts/construction-map/view-distance-test{,.err}.log`.

Next: user restarts the client from `godot/client` and reviews distant scenery
and frame rate on both maps. Rendered appearance/performance has not been
claimed as verified; no release executable was rebuilt.
