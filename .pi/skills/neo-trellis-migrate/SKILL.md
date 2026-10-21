---
name: neo-trellis-migrate
description: Use when the user requests migration from original Trellis, post-import knowledge cleanup, a migration completeness audit, or assessment of whether .trellis can be retired. Handle import prerequisites before semantic cleanup. Do not trigger merely because legacy files exist, during ordinary development, or to resume imported tasks.
---

# Migrate and review a Trellis project

Use for a requested original Trellis migration, post-import cleanup,
completeness audit, or assessment of whether .trellis can be retired.
Legacy files alone do not trigger this skill. Do not resume imported PRDs.

## Choose the entry point

Determine the target project and whether the user requests changes or only
preview/audit. For read-only requests, report findings without importing,
reorganizing files, or writing review notes.

- Before import: the map and migration report may not exist. Inspect the
  original .trellis and host configuration to identify the project and needed
  supported integrations (Codex, Claude, Pi); do not install all by default.
  Use the available neo-trellis CLI, or npx neo-trellis if not installed.
  Run neo-trellis migrate --cwd <project> with the selected --codex, --claude,
  and/or --pi flags to preview. Review its removals, backups and warnings.
  If applying migration is already authorized, rerun with --yes; otherwise
  deliver the preview. Do not use init as a substitute for migration.
- After import: read .neo-trellis/migration/trellis-report.json, map.md and
  routes.json, then perform the requested cleanup or audit below. Do not
  rerun import merely to review existing results. If a report is missing in
  an apparently migrated project, inspect the ledgers and current files;
  report the evidence gap instead of assuming a fresh import is needed.

If the CLI fails, resolve or report that failure before claiming import
success. A preview-only request ends with the preview; it does not proceed
to semantic edits. Ask only for unresolved choices, not authorization already
given in the conversation.

## Review imported knowledge

CLI copying is not semantic completion. Source paths and import ledgers are
provenance, never a second set of rules to maintain.

Inspect imported module/spec indexes and their relevant code entry points in
bounded passes. Standard backend/frontend scopes and declared packages were
placed in modules/<scope>/; other specs kept their original names under spec/.
Review ambiguous scopes. Rename only with evidence, such as frontend to
godot-client when its index and actual entry points establish that identity.
Keep useful document splits; do not flatten a module into a giant document.

Put module facts and local constraints under modules/, cross-module contracts
under spec/, research under research/, and old journals/task evidence under
history/. General thinking guides are not automatically global contracts.
Do not invent, broaden, or weaken requirements while reclassifying them.
Keep logs and binary evidence intact regardless of size. Unknown material may
remain at a normal destination with a review note, not a source-branded inbox.

Retire old workflow/delegation/validation machinery rather than porting it.
In current knowledge, remove obsolete execution instructions and replace their
links with applicable current contracts only when justified. Preserve domain
acceptance requirements. Historical commands may stay explicitly historical;
do not rewrite experimental evidence to imply it was produced by the new CLI.

Update map.md and routes.json together. Path references are discovery evidence,
not proof of ownership. Confirm affected modules and shared-contract coverage;
keep unknown scope explicit. Users should navigate from map.md directly to
normal knowledge without opening migration reports during everyday work.

When moving files, verify source/target containment and collisions, preserve
attachments, repair incoming/outgoing Markdown and JSON/JSONL references, and
update destinations in migration ledgers as well as report mappings. Preserve
source hashes. Never overwrite edited files or move/delete an unchecked path.

Verify routes and relevant links against saved files. Record findings and any
remaining gaps in migration/semantic-review.md with status pending or complete.
Separate current dependencies from historical mentions and source provenance.
Inspect references outside migrated files (project instructions, host configs,
scripts and external tool entry points) before claiming .trellis is removable.
Old unsupported integrations need retirement, not compatibility reimplementation.
Only delete the original directory when that deletion is explicitly authorized,
the dependency audit is resolved, and needed evidence is preserved. Otherwise
report that it remains. No automatic commits, publishing or old-task execution.
