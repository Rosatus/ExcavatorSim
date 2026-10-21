# Design

User requested development against this task on 2026-09-08.

## Release and landing

Keep the 100 ms admission batch. Flushing a valid batch transfers bucket mass into an explicit in-flight account in the existing material field and publishes a release event. A bounded authority queue holds the immutable proposal and flight time, using the same gravity/initial speed as presentation. No SDF edit occurs at release. Gate closure cancels only unreleased batches; airborne releases finish independently of later bucket orientation. Generation reset clears the queue and account.

At arrival the existing surface executor samples the current ground, preserving intervening cuts. At most one arrival is committed per cadence and cutting retains priority. For reuse of the existing atomic deposit path, return the arrival's escrow into bucket stock immediately before synchronous commit; accepted mass transfers to mobile terrain, and rejected/unrepresented mass remains in the bucket. This deliberate failure policy preserves mass but may visibly restore fill after failed landing. Flight mass reserves capture capacity until resolved, so rejection cannot overflow the bucket. No particle owns mass or edits terrain.

Events identify released mass, not guaranteed deposited mass. Landing must not replay the release event. The single latest-event projection retains the existing cadence limitation; release flushes are limited to one per fixed step. Ground growth uses a representative flight arrival plus half the emission interval, not per-grain impact simulation. Render meshing can still lag the authoritative landing.

## Appearance

Generate deterministic low-poly irregular grain/clod meshes once, reuse them in the existing pools and keep particle budgets unchanged. Use texture-based triplanar StandardMaterial3D for voxel terrain and bucket fill with existing Ground037 albedo/normal assets; use object coordinates on moving fill to avoid texture swimming. Small airborne grains use inexpensive varied brown vertex colors rather than high-frequency texture samples. Dust gets a soft radial alpha mask to eliminate square edges. Do not alter Terrain3D presentation or voxel resolution.

## Validation

Agent: parser/import checks, focused flight mass/release/landing/reset/gate regression and presentation resource assertions; existing narrow cutting performance test for drift. Human: SY135 low/high dump, moving outlet, gate closure, reset and re-excavation; compare soil details at near/far range. Aesthetic acceptance remains pending user review.

## Follow-up: empty dump and lift exit

The user requested diagnosis and fixes after manual use. A 20-second headless continuous-dump reproduction found six new releases in the final two seconds, with only 8440 mass quanta (8.44 mg) cycling through flight. Retain stock below 0.01 voxel of loose volume (24.375 g at the current 0.125 m / SY135 density) in the bucket ledger instead of relaunching it. Remove the visual flow's 5% minimum intensity. Expose flight queue depth in the cheap visual snapshot; the transition to zero resets GPU flow and clod pool once. Never use legacy sticky flow fallback for voxel mode or replay a completed release to a late subscriber.

For SY135, retain bounded continuation of a previously engaged cut when upward movement still sweeps a residual original-surface roof under the inner shell. Sample at most three transforms × five width × five depth positions, requiring valid nonpositive SDF; zero represents the real quantized surface. This cannot initiate cutting, skips stationary/invalid/discontinuous motion, and stops when no residual surface remains. The lift continuation includes shallow roof columns previously excluded by the deep 1.5-voxel threshold, even while the ordinary leading gate still accepts. Five exit-depth strips overlap at product resolution. Native transform sampling now budgets translation plus the box corner rotation arc, with the same 12-sample cap. This remains the existing local roof-removal approximation, not a floating-component solver.

### Screenshot follow-up: volume gaps

The screenshot follow-up supersedes the fixed five-strip layout above. Circular lanes overlapping on each axis still leave diagonal holes in the cross-section. A dense independent interior test found 184 uncovered points out of 1425 before the fix. Inner occupancy now uses centered width/height lanes spaced by at most 1.2 brush radii; roof cleanup uses the same rule in width/depth, and lift contact uses that roof footprint. Preserve brush radii, floor layout, 0.92 depth endpoints and the 12-transform cap. Add the exact interpolated cutoff crossing to roof paths instead of dropping their final segment. Avoid duplicate consecutive points, which produced corrupted real SDF during development.

This increases geometry/coverage work: final narrow benchmark commit was 9.892 ms versus the earlier roughly 6.5 ms. Sparse accounting calibration/stencil is unchanged, but more covered geometry can change captured mass. It remains a bounded brush approximation with sub-voxel expansion, not exact box clipping. Human screenshot reproduction remains pending.

### Second screenshot follow-up: continuous surface wall

Manual feedback still failed: a continuous thin wall remained at the pit rim. The prior changes addressed real lane gaps but did not establish the correct roof footprint. The contract's local +Y face (aligned with outward normal) is not the world lower boundary. A shallow 25-degree real-contract fixture had submerged cavity points while every old roof lane was airborne: admission rejected and all 27 surface projections were uncovered.

Replace that face-based geometry with a world X/Z grid and vertical-ray/oriented-box slab intersection. The lower ray intersection defines each cleanup column and lift-contact probe. Grid spacing remains 1.2 brush radii; columns use the same native radii, original-surface cap, bounded transform samples, and prior leading-front authorization. No component-wide erosion or unrelated ground deletion is added. This supersedes the previous face-lane/cutoff-intersection algorithm above. Tests now include the surface above the submerged cavity, not only its interior.

### Repeated manual failure: separate credit from geometry execution

The next screenshot still showed thin residual sheets, so the geometry-only diagnosis was insufficient. A new native executor reproduction found that the first partial cut credits solid stencil cells outside its removed brush; eleven following paths through that residual reject as `no_accounted_material`. Actual SDF remains negative throughout. This is independent of the cutter's projected coverage.

Preserve the sparse mass calibration and per-cell receipt. Permit an existing authorized native proposal to execute with zero new mass only when all current coverage cells have receipts, the ledger balances, and current solid coverage intersects the brush strictly. Collect inclusion candidates within the existing bounded coverage loop, with a small quantization margin. Geometry-only transactions bypass material mutation but advance revision/readiness and the normal world `changed` publication. `native_geometry_only` identifies this special cut; other zero-mass operations remain rejected. Empty air does not repeatedly commit. Details and evidence: `research/residual-credit-followup.md`.

### Directional user evidence: lift fails, curl/down succeeds

User reports down/curl recuts remove the sheet while direct lifting does not. Two gate defects were reproduced: a stationary frame unconditionally returned engaged=false, disabling the next lift's continuation; and lift contact sampled only the original surface even when the remaining sheet was below it. Stationary SY135 motion now retains existing engagement only with current solid column contact and still submits no cut. Contact scans the same lower-envelope-to-surface column at voxel spacing, capped at 32 intervals per lane, early-exiting on valid solid. Unengaged stationary/air and invalid history still reject. Native geometry and mass receipts are unchanged in this round.

### Subsequent reproduction: retain episode through cleared intervals

The preceding solid-contact retention rule is superseded: a committed cut clears
its own probes and then destroys its continuation on the next frame. Separate
episode retention from current-frame contact. Stationary/upward frames may keep
an established episode while the current inner box remains partly below the
original surface with valid data; actual lift cuts still require solid contact.
Full geometric exit, invalid history/data, discontinuities and non-upward motion
rejected in air end retention. Real 60 Hz / 20 Hz traces reproduce the old
failure and validate the repair; see `research/lift-episode-followup.md`.

### Live recorded residual: tooth-to-floor working lip

Live SDF confirms a real sheet, with air on both sides. Recorded user motion
reproduces five underside target values in a fresh headless zone. They never
intersect a native brush: the tooth line and short wear plate leave a working
span outside the inner cavity. Add a ruled surface from the tooth edge to the
nearest floor end, with matching width endpoints, radius-spaced lanes and
the existing brush radii. Include its vertical columns in overburden and
actual lift contact, and include the lip in episode exit. Preserve separate
native paths to prevent an off-surface connector to old floor lanes; this
raises the normal native path count from four to six. Alternate temporal
traversal and suppress degenerate consecutive points. No live SDF cleanup,
component erosion or mass-calibration change. See `research/live-residual-evidence.md`.
