# Research summary

- `.agents/skills/` is the shared Codex/Gemini/Pi project skill root. A new non-`trellis-*` sibling
  absent from `.trellis/.template-hashes.json` is user-owned and not refreshed by Trellis.
- Existing GLB parsing in `backend/src/babylon_sim/visual_assets.py` proves a stdlib
  `hashlib/json/struct` implementation is sufficient for container identity and JSON extraction.
- `godot/client/tests/sy205_glb_test.gd` demonstrates the second evidence layer: instantiate the
  imported `PackedScene` and validate actual paths, transforms, resources and AABB.
- Archived `08-11-godot-pivot-local-kinematics/research/pivot-evidence.md` demonstrates why
  independent calibrated global transforms are insufficient: they can pass global parity while
  moving visual pin origins. The reusable adapter must preserve imported local origins.
- The two external SY205 guides were not needed to derive the generic workflow. They remain useful
  authoring evidence for that one asset, but the skill's contract instead requires raw GLB evidence,
  authority contracts, controlled pose tests, and a human gate for unresolved semantics.

## Verification evidence

- A fresh default agent received only the skill path, the GLB path and a read-only adaptation request.
  It ran the inspector, kept node extras at `declared` confidence, separated missing Godot runtime
  verification from product decisions, and produced a consolidated gate without modifying files.
- Independent quality review found three inspector-contract gaps: missing non-fatal cross-reference
  diagnostics, missing 4-byte chunk alignment checks, and an absolute-path leak in argparse errors.
  All were fixed and covered by regression tests.
- Final checks: official `quick_validate.py` passed in an isolated PyYAML environment; skill-local
  Ruff, strict mypy and 8 unittest cases passed; `pixi run verify` passed all 124 backend tests plus
  provenance/standalone paths; Trellis validation and `git diff --check` passed.
