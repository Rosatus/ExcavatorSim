<!-- NEO-TRELLIS:START -->
# Neo-Trellis

This project keeps durable knowledge in `.neo-trellis/`. Use it before
exploring code broadly; it exists to prevent context rot and repeated mistakes.

## How to navigate

1. Read `.neo-trellis/map.md` — the project map: modules, responsibilities,
   code ranges, and links to module knowledge files.
2. Load knowledge by scope: when working in a module, read its knowledge file
   (linked from the map, or resolved via `.neo-trellis/routes.json` which maps
   code path prefixes to knowledge files).
3. The map only tells you where to look. Verify against the actual code before
   changing behavior — the code is the current implementation truth.

## Maintaining knowledge

Follow the neo-trellis internal knowledge-maintenance skill
(`.neo-trellis/skills/knowledge.md` if installed as a file, otherwise the
skill shipped with the neo-trellis tooling) for how to update what you find:
keep facts and contracts distinct, record evidence-backed corrections where
they apply, and keep `map.md` and `routes.json` consistent — routes.json
is the machine authority for code-scope mapping, the map is the human/agent
navigation view over the same knowledge.

## Product requirements

When receiving a PRD or a request to clarify and document product scope, follow
`.neo-trellis/skills/prd.md` (the neo-trellis-prd skill): grill first,
present the complete PRD for user confirmation, then persist and implement
authorized work. Archive only after verifying its acceptance criteria.
PRDs live in `.neo-trellis/prds/`; load only the one relevant to the current
task. Also use this skill to revise, implement, verify or archive an identified
PRD, reusing settled decisions and confirmation. Ordinary fixes, questions and
implementation tasks without PRD intent or an existing PRD do not require it.

## Knowledge layers

For requested Trellis migration, post-import cleanup or retirement audits,
follow the neo-trellis-migrate
skill at `.neo-trellis/skills/migrate.md`. Normal development uses map.md
directly; import reports are provenance, not an additional knowledge hierarchy.

- `.neo-trellis/modules/` — per-module: purpose, key entry points, code paths,
  local constraints, and counter-intuitive traps.
- `.neo-trellis/spec/` — cross-module contracts and stable rules.
- `.neo-trellis/research/` — evidence, experiments, and decision rationale.
<!-- NEO-TRELLIS:END -->
