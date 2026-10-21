# Implement godot-adapt-articulated-glb skill

## Checklist

1. [x] Initialize `.agents/skills/godot-adapt-articulated-glb` with skill-creator `init_skill.py`,
   including `scripts`, `references`, and deterministic `agents/openai.yaml` interface metadata.
2. [x] Implement the stdlib GLB inspector and skill-local tests for real-asset repeatability plus
   unreadable/truncated/header-length/JSON/root failures and hierarchy diagnostics.
3. [x] Write self-contained evidence/human-gate and Godot mechanical adapter references without
   linking or requiring the two external SY205 guides.
4. [x] Write concise `SKILL.md` routing that runs inspection first, separates observed/declared/
   validated/decision facts, consolidates human questions, and forbids premature asset/code writes.
5. [x] Run `quick_validate.py`, script unit/integration tests, two identical inspection runs with
   byte comparison, and assertions for the current GLB SHA/counts.
6. [x] Forward-test with a fresh default subagent given only the skill and a realistic adaptation
   request; revise if it overclaims mechanical semantics or skips the human gate.
7. [x] Run Trellis quality check, `pixi run verify`, task validation and `git diff --check`; commit,
   archive, and journal the scoped change while preserving unrelated dirty files.

## Validation commands

```powershell
python C:/Users/rosatus/.codex/skills/.system/skill-creator/scripts/quick_validate.py `
  .agents/skills/godot-adapt-articulated-glb
pixi run python -m unittest discover `
  -s .agents/skills/godot-adapt-articulated-glb/tests -p 'test_*.py'
pixi run python .agents/skills/godot-adapt-articulated-glb/scripts/inspect_mechanical_glb.py `
  godot/client/assets/visual/SY205_excavator_godot.glb
pixi run verify
python ./.trellis/scripts/task.py validate 08-11-godot-articulated-glb-skill
git diff --check
```

## Risky points

- The inspector must report raw evidence without turning naming/extras into inferred mechanics.
- The skill must request all unresolved human decisions before any project mutation, not one at a
  time after partial files have been written.
- The reference must not smuggle in SY205-only paths, five-part assumptions, or either external
  guide as a hidden dependency.
