# Jolt Product Soak Evidence

Date: 2026-08-18

The rendered quick gate ran for 90 seconds per model against a fresh
`gateway-only` backend. The dedicated benchmark process disabled VSync so frame
percentiles measured renderer throughput rather than display refresh waiting.
Both models completed track movement, articulated motion, loaded excavation,
dump, capped support wrench, reset, reconnect, model identity, and single-runtime
checks.

| Metric | SY205 | SY135 | Budget |
|---|---:|---:|---:|
| Fixed-step p95 | 0.300 ms | 0.357 ms | <= 4 ms |
| Fixed-step peak | 0.545 ms | 0.963 ms | <= 10 ms |
| Render p95 | 4.374 ms | 4.449 ms | <= 16.7 ms |
| Render p99 | 4.895 ms | 5.987 ms | <= 33.3 ms |
| Memory growth | 7,307,264 B / 1.25% | 15,069,184 B / 2.58% | <= 128 MiB and <= 10% |
| Accepted telemetry batches | 925 | 946 | > 0 |
| Telemetry drops | 0 | 0 | 0 |
| Maximum history | 256 | 256 | <= 256 |
| Cut / dump / support observations | 5 / 4 / 8 | 8 / 15 / 27 | each > 0 |
| Maximum payload | 318.35 kg | 453.47 kg | > 0 |

Command:

```powershell
pixi run python backend/scripts/jolt_product_soak.py --mode quick `
  --models sy205 sy135 `
  --output artifacts/benchmark/jolt-product-soak-quick.json
```

Result: `SY205: PASS`, `SY135: PASS`.

Additional gates:

- `pixi run verify`: 172 backend tests, Ruff, mypy, provenance, and standalone
  path verification passed.
- `pixi run backend-smoke`: gateway isolation and legacy compatibility passed.
- Godot 4.7.1 standalone matrix: 18/18 scripts passed. Existing Terrain3D
  deprecation and headless resource-exit warnings remain non-blocking.
- Godot AI MCP: default SY205 reported one body, four kinematic frames, four
  joints, valid terrain identity, and no contract error. A 60-frame dual-track
  command moved the chassis about 0.71 m with four contacts per side and no
  runtime quality flag.

The 15-minute-per-model `pixi run soak-jolt-release` command remains the explicit
pre-release endurance gate and was not run as part of this development quick
acceptance.
