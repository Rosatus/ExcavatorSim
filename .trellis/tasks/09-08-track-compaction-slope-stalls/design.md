# Design

Live run 3 measured 4 FPS, physics 67–71 ms, track script 0.42 ms. Temporarily pausing ExcavationWorld physics for two seconds yielded 60 FPS / 9.64 ms, then restored processing. Six individually admitted footprints had zero affected cells after the existing pure-mobile mask. Admission currently checks only a padded material AABB; repeated merged compaction subsequently fails `no_loose_material`.

Add a bounded, read-only compaction admission helper. Enumerate the real brush influence samples and require a changed sample that touches compactable solid mobile material and no protected solid neighbor. Use the existing solid-fraction calculation. Cache only derived cell classifications and sample eligibility (4096 each), plus 64 integer footprint candidate lists, keyed by authority generation, SDF data revision, material instance and material state revision; never cache SDF values or change the commit mask. Exact current brush geometry is checked even within cached integer bounds. The original exact executor remains final authority, so conservative false positives remain safe.

Expose rejected transaction timing separately: successful-commit windows currently hide the failing work. Preserve default-off diagnostics. No tuning of physics, rendering, soil mass, or compaction density.
