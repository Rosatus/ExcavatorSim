# Workflows

Use these patterns after selecting channel for cross-tool processes or durable records. Ordinary one-shot or multi-turn delegation uses native tools. Follow the project delegation policy for role permissions.

## Pattern A: Multi-round Brainstorm

Use when deliberation needs a cross-tool peer process or a durable shared record.

```bash
trellis channel create brainstorm-storage-layer --by main \
  --task .trellis/tasks/05-XX-storage-adapter

trellis channel spawn brainstorm-storage-layer \
  --agent architect --provider codex \
  --as cx-arch --timeout 30m

trellis channel send brainstorm-storage-layer \
  --as main --to cx-arch --text-file /tmp/brainstorm-r1.md

trellis channel wait brainstorm-storage-layer \
  --as main --kind done --from cx-arch --timeout 10m
```

Read the response and continue only for unresolved material questions. Stop when the decision has sufficient evidence. Depending on the task, useful probes include scope boundaries, contracts, alternatives, operational risks and verification; there is no minimum round structure. Request concrete sources where precision matters.

The discussion brief supplies the current goal, relevant acceptance, known evidence and source paths. Attach full documents only if necessary for this assignment.

## Pattern B: Channel Reviewer

Use when review specifically needs a channel peer process or durable findings. Supply a bounded brief with the current goal, relevant acceptance, exact task path, scope and existing evidence.

```bash
TASK=.trellis/tasks/05-12-foo
trellis channel create cr-foo --task "$TASK" --by main

trellis channel spawn cr-foo \
  --agent check \
  --cwd "$PWD" --timeout 15m

trellis channel send cr-foo --as main --to check --text-file /tmp/cr-brief.md
trellis channel wait cr-foo --as main --kind done --from check --timeout 15m
trellis channel messages cr-foo --kind message --from check --tag final_answer
```

Include the exact diff scope, relevant spec paths and validation already run in the brief. The worker reads missing relevant sections on demand. Only attach files or manifests when their full contents are useful for this bounded assignment.

## Pattern C: Parallel Reviewers

When a channel is needed, use one channel and distinct worker names.

```bash
trellis channel create cr-feature --by main --ephemeral

trellis channel spawn cr-feature --agent check \
  --timeout 15m

trellis channel spawn cr-feature --agent check --provider codex --as check-cx \
  --timeout 15m

trellis channel send cr-feature --as main --to check --text-file /tmp/cr-brief.md
trellis channel send cr-feature --as main --to check-cx --text-file /tmp/cr-brief.md
trellis channel wait cr-feature --as main --kind done --from check,check-cx --all --timeout 15m
```

`--all` means every listed worker must emit a matching event.

## Pattern D: One-shot Worker

```bash
trellis channel run --provider codex --message "say hi in 3 words" --timeout 1m
trellis channel run --agent plan --message-file /tmp/plan-question.md --timeout 10m
```

On success, `run` removes the ephemeral channel. On error/timeout/killed, it
keeps the channel and prints the path for inspection.

## Pattern E: Forum Channel

Use for issue forums, topic-style feedback, release todos, agent findings, and
internal changelogs. Read `forum.md` for the full model.

## Pattern F: Take Over Existing Thread

If the user gives a forum/thread name, restore context yourself:

```bash
trellis channel forum <board> --scope global
trellis channel thread <board> <thread> --scope global --raw
trellis channel context list <board> --scope global --thread <thread>
trellis channel messages <board> --scope global --raw --thread <thread>
```

Output a constraint summary, not a transcript dump:

- user-level problem
- context files that affect this repo
- current-version versus future-version requirements
- whether current code/design satisfies it
- next action or comment to append
