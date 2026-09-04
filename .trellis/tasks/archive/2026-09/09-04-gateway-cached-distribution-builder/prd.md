# Gateway-only cached distribution builder

## Goal

Add and document a preferred cached Gateway-only Windows/Linux distribution entry point with smoke validation and transactional replacement.

## Requirements

- Provide one PowerShell entry point for Windows, Linux, or both Gateway packages.
- Build the React production bundle once and reuse it across selected platforms.
- Reuse dependency and Linux PyInstaller caches when their inputs remain compatible.
- Stage, validate, smoke, manifest, and transactionally replace only the selected
  `dist/can_gateway*` directories; never rewrite `godot/dist`.
- Preserve the legacy platform builders as compatible lower-level entry points.
- Record in the Gateway Trellis spec that this builder is preferred for Gateway-only
  distribution; reserve the full release builder for requests that also export Godot.

## Acceptance Criteria

- [x] `tools/build_gateway_dist.ps1` supports `all`, `windows`, and `linux`.
- [x] A warm dual-platform build completes with one Web build and cached dependencies.
- [x] Windows frozen smoke verifies Web root, status API, assets, and adjacent DBCs.
- [x] Linux output verifies ELF artifacts, helper scripts, DBCs, and syntax/smoke checks.
- [x] Multi-package installation rolls back as one transaction on failure.
- [x] Focused tests, Ruff, mypy, Bash syntax, and real dual-platform build pass.
- [x] Usage and command-selection guidance are documented in README, release docs,
  and `.trellis/spec/backend/can-gateway-control.md`.

## Notes

- Work commit: `2c9b770`.
- Related already-pushed fixes included in the same push range: `854e471`, `573edc1`.
