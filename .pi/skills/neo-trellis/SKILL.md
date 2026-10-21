---
name: neo-trellis
description: Navigate and maintain scoped knowledge in projects using .neo-trellis. Use when starting or resuming project work, entering a new code area, building the initial map, receiving an evidence-backed correction, or finishing changes that may affect recorded knowledge. Load only relevant module knowledge and contracts; keep map and routes consistent.
---

# Neo-Trellis

# Neo-Trellis Knowledge Maintenance

Follow this process whenever you work in this project. Do not expose it as
commands the user must invoke; it happens inside normal development.

## 1. Load by scope, not by habit

- On entering a code area you have not seen in this session, resolve which
  knowledge files apply: use the map's module table or
  `.neo-trellis/routes.json` prefix matching.
- Read only the module files for the scopes you will touch, plus linked
  specs that apply. Do not bulk-load all knowledge.
- Historical research is optional detail: open it when you need the *why*,
  not as routine reading.

## Initializing the map

When `map.md` is still a template or mostly empty, build it gradually:
explore top-level directories and entry points (manifests, main files,
index/exports) within a bounded pass — do not attempt a whole-repo read.
Record what you confirmed, mark gaps explicitly, and add rows to the module
table plus matching entries in `routes.json` as each module is identified.
Both must stay consistent: routes.json is the machine authority for
code-scope mapping; map.md is the navigation view over the same knowledge.
Optional helper CLIs (status/route commands) may exist but might not be
installed — never depend on them; read the files directly.

## 2. Facts vs contracts

- FACTS describe what the implementation currently is: entry points,
  data flow, dependencies. When code legitimately changes, update the facts.
- CONTRACTS state what the implementation must keep satisfying: compatibility
  promises, prohibited patterns, external agreements. If code drifts from a
  contract, treat it as a conflict — fix the code or escalate; never silently
  rewrite the contract to match the code.
- Keep each item's status visible: confirmed rule, observed fact, or
  unverified inference. Inferences never become contracts without evidence.

## 3. Recording corrections (the "mistake book")

Persist a lesson when:
- the user explicitly corrected your understanding or stated a requirement;
- a test or reproducible result exposed a non-obvious edge case;
- an approach was proven unsuitable for this project, with conditions.

Write it where it applies — the owning module's file or a spec — phrased as
"common misjudgment / correct behavior / evidence", not as a dated diary
entry. Check for an existing rule first and update it instead of duplicating.
Never persist typos, one-off tool failures, or your own unconfirmed guesses.
Record a correction at the scope the evidence actually covers — do not widen
a user correction into a broader rule than what was stated.

## Superseding old knowledge

When a new rule or fact replaces an old one, do not silently delete the old
record: mark it `superseded`, link it to the new rule, and keep its source
date and applicability range. Old dated research may stay untouched; what
must be marked is anything presented as *current* that is no longer true.

## 4. Updating after a change

- Near the end of a logical change, diff what you touched against the
  knowledge for that scope: update facts that shifted, keep contracts,
  flag any contract conflict you introduced.
- Verify every write: re-read the file you modified and confirm the content
  actually landed. A journal/log line is not proof of a knowledge update.
- Do not write a journal entry for every change. Only add a dated note when
  there is something worth handing off: blockers, partial progress, or
  evidence for a deferred verification.

## 5. Session boundaries

- startup: read map.md and the routes table; load scope knowledge lazily.
- compact/context loss: re-read map.md and the knowledge for scopes you were
  actively editing; the map is your recovery anchor.
- clear: load only the project knowledge entry points. Do NOT auto-resume a
  previous task; a clear may mean a fresh start. If a handoff note exists,
  mention it is available and let the user decide.

