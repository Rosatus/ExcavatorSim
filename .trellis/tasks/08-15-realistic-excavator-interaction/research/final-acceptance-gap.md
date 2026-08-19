# Final acceptance gap assessment

Date: 2026-08-19

## Observed lineage

The original interaction children are complete and archived:

| Child | Implementation | Archive |
|---|---|---|
| tracked chassis locomotion | `07301c768254ab1480de382e7150386c30ae70a0` | `fa65a19` |
| automatic soil interaction | `864bd7e945f22015b298a48163f00adc467dd350` | `19fa691` |
| bucket ground lift reaction | `98c0ccee855bf36b119361534d4f620948da5a9e` | `e931ec2` |

The archived `08-17-jolt-authoritative-simulation` parent (`9be0d35`) and its six
archived children supersede the old parent authority design. Current product
authority is the hybrid path documented in `docs/architecture/engineering.md`:
one dynamic Jolt chassis, one fixed-step kinematic work-equipment state, local
TerrainState/BucketSoilState semantics, and Python gateway/telemetry services.

## Observed accepted evidence

- The 90-second rendered quick soak passed SY205 and SY135 at the current default
  settings (`217f7a8`).
- Fixed-step/render percentiles, memory growth, telemetry loss/history, selected
  model, one runtime, track/articulation, cut/load/dump/support, reset, and
  reconnect are already enforced by the current evaluator.
- Standalone tests cover both models and isolated low/high visual-quality control.

## Observed missing evidence

1. The documented `pixi run soak-jolt-release` gate, 15 minutes per model, has not
   been run. This is explicitly recorded in the archived quick-soak evidence.
2. The loaded product scenario has not been run across low, balanced, and high
   quality for both models. Existing quality tests validate settings and budgets,
   not the full interaction/lifecycle path.
3. Automated counters do not prove that carried soil, dump flow/deposit, terrain
   change, and support response remain visually readable in all six model/tier
   cells. The prior MCP evidence is a default SY205 composition smoke.

## Decision

Use this parent for final evidence only. Run one two-model balanced release
endurance gate, one shorter six-cell quality matrix, and one six-cell MCP visual
review. Do not reopen the archived children or change authority. A significant
visual/physics tuning need becomes a separate task; this parent remains open until
that follow-up is approved and resolved.
