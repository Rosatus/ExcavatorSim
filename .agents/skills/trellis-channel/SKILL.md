---
name: trellis-channel
description: Use Trellis channel for cross-tool peer processes, durable shared collaboration records, or inspecting/debugging an existing channel. Ordinary subagent delegation uses native tools.
---

# trellis-channel

`trellis channel` supplies cross-tool peer processes and durable collaboration records. Use it when those capabilities are needed or when inspecting an existing channel. Native subagents are the default for bounded exploration and review. Multiple turns, progress inspection, interrupts and waiting alone do not require a channel.

Typical signals: "use a persistent channel", "compare Codex and Claude through peer processes", "open a shared issue forum", "inspect this channel/thread", "debug a stuck channel worker". A generic "let an agent review" is not a channel request.

This skill is an index. Load only the reference file for the current job — do not preload all of them.

## Discover Commands When Needed

Use help for unknown syntax; list only the scope relevant to the request. These are alternatives, not a startup checklist.

```bash
trellis --version
trellis channel --help
trellis channel list --all
trellis channel list --scope global --all
```

If the user names a channel or thread, inspect it before asking for background:

```bash
trellis channel forum <board> --scope global
trellis channel thread <board> <thread> --scope global
trellis channel context list <board> --scope global --thread <thread>
```

## Route By User Intent

| User intent | Read |
|---|---|
| Cross-tool peer discussion or durable shared deliberation | `references/workflows.md` |
| A reviewer specifically needs a channel peer process | `references/workflows.md`, then `references/workers.md` |
| "开 issue 区 / topic 群 / changelog / board", "make a forum" | `references/forum.md` |
| "看看这个 thread / linked context", "inspect a thread" | `references/forum.md` |
| "channel 卡住了 / 没输出 / progress 被截断", "worker stalled" | `references/progress-debugging.md` |
| "具体命令怎么写", "what flags does X take" | `references/command-reference.md` |

## Core Rules

- New forum channels use `--type forum`. A `thread` is one item inside a forum channel.
- Use `--context-file` / `--context-raw` and `trellis channel context add/delete/list`. `--linked-context-*` is deprecated terminology.
- Use `--stdin` or `--text-file` for long messages. Do not put long mixed Chinese/English text in the positional shell argument.
- Pretty `messages` output is an operator dashboard and may truncate progress. Use `--raw` for audit.
- `--as` is the speaker or worker handle, depending on the command. Use explicit, stable names when multiple agents or sessions are involved.
- `--scope project` (default) operates on the current cwd's project bucket; `--scope global` operates on the shared `__global__` bucket. Pick scope deliberately — a global board is invisible from project listings unless `--scope global` is passed.
- For brainstorm, continue only while a material uncertainty, disagreement or evidence gap remains. There is no minimum number of rounds.
- **Dispatcher wait pattern**: use `--kind done` / `--kind turn_finished` (trellis-emitted system events), NOT a user `--tag` as the completion signal. CLI help lists `phase_done` / `question` as `--tag` examples but only `interrupt` is a reserved tag with hardcoded trellis behavior; the others are opaque user labels. Relying on a worker to run `send --tag <my_signal>` is unreliable — LLM workers commonly write the tag string into prose instead of running the actual CLI command. See `references/command-reference.md` "tag vs kind".
- Forum channels are event-sourced. Do not parse `events.jsonl` first; use `forum`, `thread`, `messages --thread`, and `context list`.
- `@mindfoldhq/trellis-core` owns reusable channel/thread state, event append, seq allocation, context/title projection, reducers, and task helpers. The CLI owns flags, terminal rendering, prompts, worker lifecycle, and process exits.

## Reference Files

- `references/workflows.md` — canonical collaboration patterns A–F (peer brainstorm, spawned review, dispatch-and-wait, forum issue capture, interrupt-and-redirect, one-shot run).
- `references/forum.md` — forum channels, context, title, rename, changelog forums, thread filtering.
- `references/workers.md` — spawn, agent cards, context injection (`--file` / `--jsonl`), interrupts, kill semantics.
- `references/progress-debugging.md` — progress/raw inspection, stalled worker diagnosis, OOM guard, exit codes.
- `references/command-reference.md` — current CLI command reference (every subcommand, every flag, output conventions, scope/type model).

## Not For

- Ordinary native subagent work, including multi-turn review and progress inspection.
- Replacing normal tool calls with self-logging.
- Long-term memory retrieval. Use durable forum channels for actionable issues, and `trellis mem` (the `trellis-session-insight` skill) for session/history search.
