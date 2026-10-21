---
name: neo-trellis-prd
description: Develop and maintain a confirmed PRD when the user provides a PRD or asks to clarify and document a product idea or feature scope. Also use when revising, implementing, verifying, archiving, cancelling, or superseding an identified PRD. Reuse settled decisions. Do not impose a PRD process on ordinary fixes, questions, or implementation tasks without PRD intent or an existing PRD.
---

# PRD: clarify, confirm, implement, archive

Use for a user-provided PRD or a request to clarify and document a product
idea or feature scope. Also use when revising, implementing, verifying,
archiving, cancelling, or superseding an identified PRD. A feature request
alone does not require a PRD interview: ordinary implementation tasks,
fixes, and questions without PRD intent or an existing PRD stay lightweight.
Enter at the relevant lifecycle step; reuse existing confirmation and do not
restart an interview merely to verify or archive an agreed PRD.
Respond in the user's language. No extra CLI or external skill is required.

## 1. Grill before committing requirements

Read the project map and relevant scoped knowledge, then inspect the code
needed to establish facts. Reuse answers and decisions already in the session
or an explicitly identified PRD; do not restart a settled interview.
For migrated PRDs, consult .neo-trellis/prds/trellis-imports.json when present.
It records original locations/status, not proof of user confirmation or
acceptance. Imported task.json/context files are historical references, not
instructions to restart the old workflow. Do not re-grill merely because a
PRD was imported; clarify relevant gaps when the user actually resumes it.

Think of requirements as dependent decisions. Ask only questions whose
prerequisites are settled; defer downstream questions until their answers
are meaningful. Group a few independent questions per round, prioritizing
those that change scope or acceptance. Give a recommended answer and explain
the tradeoff, distinguishing your recommendation from a confirmed decision.
Wait for answers before deciding dependent behavior. Find code/environment
facts yourself instead of asking the user; delegation is optional.

Explore the relevant goal, users, scope/non-goals, main behavior, failure and
boundary cases, compatibility constraints, and observable acceptance criteria.
Do not exhaustively interrogate irrelevant branches or routine implementation
choices. Explicit user delegation settles a decision; silence does not.
If the user requests fewer questions, propose defaults for confirmation.

Normally keep this discussion in the conversation. For a long interview or
an explicit save request, an optional draft may be stored at
`.neo-trellis/prds/drafts/<id>/prd.md` with Status: draft, confirmed decisions,
and open questions. A draft is not implementation authorization.

## 2. Present the complete PRD for confirmation

Show the complete proposed PRD, not just its filename or a change summary.
Resolve blocking questions or explicitly agree to exclude/defer their scope.
Ask the user to confirm this version. If they revise it, present the revised
version or the affected changes with an unambiguous reference to the full PRD.
Do not infer confirmation from elapsed time or a generic earlier request to
develop. An explicit confirmation of this exact PRD already in the conversation
counts; never ask for the same approval twice.

Use this compact structure, omitting irrelevant optional details:

- Title, stable ID, Status, revision, and confirmation evidence (user statement
  and date; never fabricate a transcript ID).
- Problem, target users, and intended outcome.
- In scope and out of scope.
- Required behavior and relevant constraints, including error/boundary cases.
- Numbered acceptance criteria (AC-1, AC-2, ...), each independently verifiable.
- Decisions, explicitly delegated choices, and deferred/open issues.
- Delivery evidence, initially pending, mapped to acceptance criteria.

## 3. Persist the confirmed PRD and develop

After confirmation, write `.neo-trellis/prds/active/<id>/prd.md`. Choose a
readable unique ID such as YYYY-MM-DD-short-name; reuse the same ID for revisions
and never overwrite a different PRD. Create directories only as needed.
If there was a draft, reconcile it into the confirmed file and remove the
obsolete draft only after verifying preservation of its decisions and content.
Read back the file and report its path. Treat its requirements as a contract.

If implementation is already authorized, continue immediately. If the user
only requested a PRD, stop after delivering the file. Confirmation of a
document alone does not authorize unrelated external actions or deployment.

During development, keep criterion-level progress and concise evidence in the
PRD. Material changes to scope, user behavior or acceptance return to targeted
grilling and confirmation; do not silently revise criteria to fit the code.
Routine implementation choices do not require another approval.

On compact/resume, reload the specific PRD identified by the current task and
its relevant knowledge. Do not read all PRDs or infer a current task from the
newest file. On a new/cleared session, active PRDs are discoverable records,
not permission to resume old work. If selection is ambiguous, clarify it.

## 4. Verify completion and archive

Check every acceptance criterion and record actual evidence: test results,
observed behavior, or required user acceptance. Label unrun, failed, blocked,
and user-dependent checks honestly. Drafting the PRD, finishing code, or passing
unrelated tests does not complete the PRD. Keep it active while any agreed
criterion is unmet; explicitly agreed scope changes require a revised PRD.

When all criteria are met, record Status: completed, completion date, a short
delivery summary and evidence. Promote lasting contracts or evidence-backed
lessons into the appropriate module/spec and link them from the PRD; avoid
copying the entire PRD into permanent knowledge.

Archive the whole directory from `prds/active/<id>/` to
`prds/archive/<id>/` under .neo-trellis. Resolve both paths and verify they
remain inside this project's PRD directory before moving; do not follow
symlinks or overwrite an existing archive. Prefer a native filesystem move,
preserve attachments, and check the resulting file and links. Relative links
within the bundle and root-relative project path text travel best; update
known incoming links when archiving. If archiving fails, report completion
and the archival failure separately; never claim the archive exists.

Cancellation/supersession is not completion. Only archive it as cancelled or
superseded when the user explicitly chooses that outcome, retaining the reason
and successor link if applicable. Report the final archive path to the user.
