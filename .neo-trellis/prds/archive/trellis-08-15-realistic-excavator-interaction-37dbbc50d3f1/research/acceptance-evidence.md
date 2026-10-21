# Interaction Acceptance Evidence

Date: 2026-08-19

## Automated Gates

The six-cell quality matrix used `pixi run soak-jolt-quality-matrix`. It ran the
same loaded cut/carry/dump/support/reset/reconnect scenario for both models at
low, balanced, and high quality. The v2 report passed all cells:

- SHA-256: `55B6E6FE900D5A0EED5EA0C5524DED5FFB9828F3F2A4446009E2AEEF073131AF`
- Report: `artifacts/benchmark/jolt-product-soak-quality-matrix.json`
- Every cell reported one runtime, matching requested/observed/applied quality,
  track and articulated-joint movement, cut/load/dump/support, reset/reconnect,
  zero telemetry drops, history no larger than 256, and memory growth below the
  existing 10% / 128 MiB limits.
- In the aggregate v2 report, `duration_seconds_per_cell` is 90 seconds and
  `duration_seconds_per_model` is 270 seconds because each model runs three
  quality cells. The release report has one balanced cell per model, so its
  per-model duration remains 900 seconds.

| Model | Quality | Fixed p95/peak ms | Render p95/p99 ms | Memory growth | Max payload kg | Cut/dump frames | Support frames | Telemetry accepted/dropped |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| SY205 | low | 0.348 / 0.716 | 2.960 / 5.035 | 2.39% | 1027.0 | 7 / 1307 | 9 | 854 / 0 |
| SY205 | balanced | 0.458 / 1.028 | 6.137 / 7.967 | 2.22% | 468.1 | 12 / 12 | 5 | 932 / 0 |
| SY205 | high | 0.380 / 0.775 | 8.180 / 11.487 | 2.06% | 679.5 | 15 / 12 | 6 | 932 / 0 |
| SY135 | low | 0.414 / 0.699 | 3.170 / 4.799 | 1.96% | 294.8 | 53 / 16 | 25 | 917 / 0 |
| SY135 | balanced | 0.436 / 1.868 | 5.530 / 7.217 | 2.13% | 291.3 | 9 / 18 | 26 | 974 / 0 |
| SY135 | high | 0.432 / 0.792 | 7.013 / 11.345 | 2.15% | 408.1 | 6 / 18 | 26 | 944 / 0 |

The documented release gate used `pixi run soak-jolt-release`, 900 seconds per
model at explicit balanced quality:

- SHA-256: `300F1D7C91EC49AAF458B4FBB826FBF80AC4B1A445786653BFF98104D78546E6`
- Report: `artifacts/benchmark/jolt-product-soak.json`
- SY205: fixed 0.371/1.313 ms, render 6.368/7.827 ms, memory growth 3.85%,
  payload 1479.9 kg, cut/dump 137/1886, support 37, telemetry 9013/0.
- SY135: fixed 0.423/1.783 ms, render 5.250/6.620 ms, memory growth 3.44%,
  payload 425.8 kg, cut/dump 42/68, support 224, telemetry 9303/0.

## Harness Regression

The second quality-matrix run exposed a real harness defect: test-only joint and
track commands were overwritten by the normal window-focus safety branch when a
benchmark window lost focus. The fix is an explicit opt-in
`set_test_input_focus_bypass_for_test(true)` used only by the benchmark and
standalone test scripts. Production input remains focus-gated and zeros commands
when unfocused. The chassis regression suite passes both default focus safety and
the explicit test bypass path.

## MCP Visual Review

Godot AI MCP session `client@8a2d` used Godot `4.7.1-stable`, with the live
`jolt_authoritative` path and fresh gateway sessions. Captures were collected for
SY205 and SY135 at low/balanced/high. The curated contact sheet is
`visual-contact-sheet.png` in this directory.

The six selected frames show:

| Cell | Frame | Observation | Numeric corroboration |
|---|---|---|---|
| SY205/low | carry | Brown soil is visibly retained in the bucket; excavator is in a raised carry pose. | Metadata reports `carry`, payload 1068.0 kg before the final recapture. |
| SY205/balanced | dump | Bucket is rotated forward into a dump/spill posture. | Metadata reports `spill`; payload decreases from 211.3 kg to 200.9 kg in the captured interval. |
| SY205/high | support | Bucket is down near the pad with a visible ground interaction pose. | Metadata contains a support wrench request; automated support frames are non-zero. |
| SY135/low | carry | Brown soil is visible inside the SY135 bucket during carry. | Metadata reports `carry`, payload 59.6 kg. |
| SY135/balanced | dump | SY135 bucket is visibly rotated into the dump posture. | Metadata reports `spill`; payload decreases from 56.0 kg to 49.0 kg. |
| SY135/high | support | Bucket is placed down against the pad; support pose is visually distinct. | Metadata contains a support wrench request; automated support frames are non-zero. |

Terrain scars and loose soil are primarily validated through `terrain_revision`,
payload, interaction classification, and the automated report. The grass/terrain
material is not sharp enough in every camera frame to claim that a specific scar
is visually identifiable. That is recorded as an observation limit, not hidden
by changing the acceptance threshold.

Raw captures and soak reports remain under ignored `artifacts/benchmark/`; only
this compact sheet and note are committed as reproducible review evidence.
