# Map/window, tilt bucket and urban wind fixes

User request: preserve window size on map switch; eliminate missed soil with tilted/rotated GB12; rename construction to 土方工地 and urban to 市政施工; remove camera-motion-dependent foliage/flag jitter.

Preserve existing HUD and voxel edge/release uncommitted changes. Main agent implements; urban_wind_review performs read-only shader/pack investigation.

Agent automated: focused video/map, GB12 cutter geometry/admission and native transaction tests; shader source and real pack checks. Human manual: maximized/resized map switch, tilted/rotated digging and moving-camera urban wind appearance.

Progress: implementation complete; pending representative human review.
- Window mode apply is idempotent: windowed/maximized OS geometry survives scene/UI recreation.
- Menu labels, tooltip and map errors use 土方工地 / 市政施工.
- GB12 probes tooth + both side segments at voxel spacing, rather than three tooth taps; native swept occupancy/lift exit follow tool fill_profile_id across hosts. Shared floor lane spacing covers full width. Sync/prepared authority admission and accounting share the same capability.
- Fixed all four Foliage VisualShader INV_VIEW_MATRIX occurrences to MODEL_MATRIX. Existing Flag/tarp graphs and actual flag prefab material were already correct. Read-only urban_wind_review found no additional flag source defect; flag-specific runtime symptom remains unconfirmed.
- Build now requires wind graph check before publishing. Built both urban PCK copies, SHA256 dbffdf8fb660396bd1a88b4282202eecb2a53ee9e4d8be54c4b3a89fdefc42ac. Client restart required to load replaced pack.

Agent automated PASS with C:/apps/godot_voxel/godot.windows.editor.x86_64.exe:
voxel_bucket_cutter_test (including tilted GB12 isolated tooth/side ridges and full transverse floor coverage on SY135/SY80U), voxel_excavation_authority_test (real GB12 native cut + exact mass ledger), video_settings_test, map_switch_test, voxel_cut_preparation_test (including GB12 sliced preparation on SY80U; failures=0), urban_pack_test (actual packed shader matrices, load/driving, failures=[]), build wind shader gate and git diff --check. No full export/visual pass run.
Logs TEMP/tilt-cutter.{log,err}, tilt-authority.{log,err}, tilt-video_settings_test.{log,err}, tilt-final-{map_switch_test,voxel_cut_preparation_test,urban_pack_test}.{log,err}; artifacts/urban-map build/wind logs. First map run failed a new label assertion because it omitted the existing 地图： prefix; corrected exact visible strings, final run passed. Existing engine deprecation and map UID path-fallback warnings remain; final tests exit 0.

Human manual pending: restart client, maximize/rescale window and switch training / 土方工地 / 市政施工; preserve window size/position. On SY135 + XTR13/GB12, tilt both directions and rotate while cutting a narrow ridge, then lift; inspect residual soil. In 市政施工 drive and stop while watching leaves/flags; leaves should no longer react to camera motion. If flags still shake, capture exact prop/view/operating conditions for focused diagnosis; current static/source check cannot establish visual resolution.
No commit or standalone client export requested. Pre-existing HUD/voxel-edge-release changes preserved. Next: user runtime review, especially flag-specific symptom. Keep task open pending that feedback.

2026-09-28 repository housekeeping: user authorized grouped commits of current workspace changes. Implementation and existing validation records are retained; pending human review or unreproduced symptoms remain pending. Build outputs/caches stay under existing ignore rules.
