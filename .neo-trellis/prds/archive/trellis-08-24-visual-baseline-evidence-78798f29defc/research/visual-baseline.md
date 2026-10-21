# Visual baseline result

## Frozen run

- Run: `20260824T025647Z-a6045418`
- Commit: `a60454186832626f900545f3ba4b94623a90be2e`
- Runtime: Godot 4.7.1-stable, Windows, Ryzen 7 9700X, Radeon RX 9070 XT
- Authority: `jolt_authoritative`; soil authority: `legacy_analytic_parcel`
- Matrix: 34/34 nonblank 1920x1080 artifacts, six model/profile entries,
  clean Godot logs, zero artifact-integrity errors
- Scenario result: 20/34 achieved. The 14 expected baseline failures are carry
  and dump for every model/profile plus controls-visible for both balanced
  profiles.
- Performance: the 34 checkpoint samples span 56.85-95.68 mean render FPS;
  p95 mean frame time is 17.566 ms. The two controls-visible samples have only a
  0.052 s window and are retained for traceability, not performance claims.

The tracked manifest is
`research/evidence/before/manifest.json` (SHA-256
`f07e27acb7f73730e99f618656e67c3bbce6368aa1a2ec2bfb442f1b091d27be`).
The 107.8 MB PNG set remains under the ignored artifact directory at
`artifacts/benchmark/visual-baseline-before-raw/20260824T025647Z-a6045418/`;
the manifest records every absolute path, SHA-256 digest, scenario result,
performance sample, and error-log outcome.

## Baseline scorecard

Scores are 1 (blocking) through 5 (release quality). They freeze the review
already completed for the baseline; later code tasks do not repeatedly rescore
screenshots.

| Dimension | SY205 | SY135 | Evidence and reason |
|---|---:|---:|---|
| Control discoverability | 1 | 1 | `balanced-controls-visible`: checkpoint explicitly fails because essential controls are absent. |
| HUD hierarchy | 1 | 1 | `balanced-startup`: large diagnostic-first overlay dominates the player view and supplies no concise operator journey. |
| Camera usability/framing | 2 | 2 | `balanced-startup/dig/carry`: fixed framing makes stages look similar; SY205 linkage frequently occludes the work area. |
| Site composition/scale | 2 | 2 | `balanced-startup/terrain`: sparse repeated vegetation/rocks and abrupt horizon provide weak construction-site scale cues. |
| Lighting/material readability | 3 | 1 | SY205 remains readable but flat; SY135 is a beige/blocky placeholder with weak material separation. |
| Machine-ground contact | 2 | 2 | `balanced-support` reaches the support contract, but the rendered contact/load transfer is difficult to read. |
| Soil feedback | 1 | 1 | `balanced-dig/carry/dump`: no nonzero payload; scattered clods do not form a coherent cut, carried mass, or deposit. |
| Audio feedback | 1 | 1 | Production baseline has no digging/load/dump audio feedback. |
| Recovery clarity | 2 | 2 | `balanced-reset` reaches reset, but the player receives no concise recovery/re-arm confirmation. |

## Prioritized ownership backlog

Every P0/P1 item has one owner. A child may consume several findings, but no
finding is jointly implemented across competing authorities.

| Priority | Finding / user impact | Evidence / repository anchor | Observable acceptance target | Owner |
|---|---|---|---|---|
| P0 | Point/parcel semantics cannot express cutting, scraping, pushing, support, and release over the whole bucket. | `balanced-dig`; `bucket_soil_interaction.gd`, physics-rig bucket frames | Both models publish one versioned, full-bucket semantic contract with teeth, lip, floor, sidewalls, back/shell and opening regions. | `08-24-full-bucket-soil-tool-contract` |
| P0 | Terrain response is visually discontinuous and does not form a readable trench or pushed mound. | `balanced-dig/terrain`; `terrain_state.gd`, terrain renderer | One 3-5 m bucket-following active patch produces a coherent cut/push/deposit result while the persistent terrain remains authoritative. | `08-24-local-active-soil-patch-prototype` |
| P0 | All six carry/dump cells have zero payload, so the core excavator loop is absent. | manifest `scenario_failure_count=14`; `bucket_soil_interaction.gd`, terrain commit path | SY205 and SY135 scripted journeys capture nonzero soil, carry it without double counting, release it, and reconcile terrain/patch/bucket/spill/deposit within tolerance. | `08-24-conservative-soil-material-lifecycle` |
| P0 | Legacy parcel fallback can conflict with the new active authority during migration. | every checkpoint records `legacy_analytic_parcel`; ProductSession generation seams | `legacy -> shadow -> active_patch` is generation-safe, never double-writes material, and falls back cleanly on reset/model switch/disable. | `08-24-soil-authority-migration-validation` |
| P1 | Digging has no legible load response, making contact feel weightless even when state changes. | `balanced-dig/support`; arm controller and soil telemetry | Bounded normalized load slows working joints smoothly, never stalls them, recovers predictably, and drives read-only presentation cues without hydraulic simulation. | `08-24-game-feel-digging-response` |
| P1 | Essential controls and reset state are undiscoverable. | both `balanced-controls-visible=false`; diagnostic HUD scene | First-run guidance shows movement/work-tool/reset/model controls, then collapses into a compact HUD with visible recovery state. | `08-24-operator-onboarding-hud` |
| P1 | The work area is easily occluded and journey stages lack distinct framing. | `balanced-startup/dig/carry/reset`; camera rig | Presets frame travel, digging, carry/dump and recovery for both models, with collision/occlusion handling and deterministic reset. | `08-24-camera-workflow-presets` |
| P1 | Site scale, horizon, fallback-terrain parity, and SY135 material presentation break visual cohesion. | `balanced-startup/terrain`; environment and terrain presentation nodes | A bounded construction site supplies readable scale layers, coherent ground/horizon/materials, and comparable fallback/Terrain3D presentation on both models. | `08-24-construction-site-visual-polish` |
| P1 | Contact, load, material flow, and dump have no coordinated audio/VFX language. | `balanced-dig/carry/dump/support`; `SoilEffects` | Bounded particles, hero clods, dust and layered audio respond only to read-only soil/load states; mute preserves all required state cues. | `08-24-soil-effects-audio-feedback` |
| P2 | Low/balanced/high are hard to distinguish in core compositions. | all profile core cells | Final validation demonstrates intentional profile differences without changing simulation state. | `08-24-product-experience-validation` |

## Automation versus human review

Automation owns capture completeness, dimensions, nonblank output, hashes,
metadata, scenario state, logs, and performance windows. It may fail a code task
for those objective conditions without asking for visual inspection.

Composition, realism, material appeal, animation feel, legibility, and audio
mix remain human judgments. Per the current development policy, implementation
children prioritize code and deterministic tests; they do not trigger repeated
assistant-led screenshot review. A minimal representative before/after set is
prepared only at a declared visual milestone, then handed to a human reviewer.
No pixel threshold is introduced because Sky3D, particles, GPU/driver state and
render timing can vary without a product regression.

## Regeneration

From the repository root:

```powershell
& 'godot/client/tests/capture_visual_baseline.ps1' `
  -GodotExe 'E:\applications\Godot_v4.7.1-stable_mono_win64\Godot_v4.7.1-stable_mono_win64_console.exe' `
  -Model all `
  -QualityProfile all
```

The command writes a timestamped ignored directory. A complete run must report
34 artifacts, six entries, zero integrity errors, clean logs, and exact
1920x1080 dimensions. Scenario failures remain product evidence rather than
artifact failures.
