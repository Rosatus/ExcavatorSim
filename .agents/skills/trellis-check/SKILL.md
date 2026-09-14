---
name: trellis-check
description: "Verify cumulative affected behavior with focused checks and reusable evidence."
---

# Check
Use `.trellis/validation.md`; do not reload it if available.
1. Establish the actual task diff including earlier edits/relevant untracked files. Distinguish pre-existing/concurrent work; the entire dirty tree is not automatically this task.
2. Compare acceptance and applicable contracts against actual code. The implementation plan can evolve; it is not an immutable prescription.
3. Select checks disproving relevant failure modes. Reuse valid evidence and fill gaps. No test per function, shared constant for coincidentally equal values, or unrelated full suites.
4. The main agent fixes concrete in-scope issues and reruns affected checks; a delegated reviewer returns findings without edits. Do not silently fix unrelated baseline failures or expand scope.
5. Report verified behavior, real findings and material limitations. A clean check requires no second reviewer, approval, spec update or commit ceremony.
Final coverage includes every affected task contract. Evidence survives compaction/unrelated edits; explicit acceptance/domain gates still apply.
