// Run: node --test .trellis/tests/opencode-context.test.mjs
import assert from "node:assert/strict"
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs"
import { tmpdir } from "node:os"
import { join, dirname, basename, resolve } from "node:path"
import { test } from "node:test"
import workflowPlugin from "../../.opencode/plugins/inject-workflow-state.js"
import subagentPlugin from "../../.opencode/plugins/inject-subagent-context.js"

// Prevent the runner's live task identity from contaminating isolated fixtures.
for (const name of ["TRELLIS_CONTEXT_ID", "OPENCODE_RUN_ID", "OPENCODE_NON_INTERACTIVE", "TRELLIS_HOOKS", "TRELLIS_DISABLE_HOOKS"]) delete process.env[name]

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), "trellis-plugin-test-"))
  t.after(() => {
    assert.equal(dirname(resolve(directory)), resolve(tmpdir()))
    assert.ok(basename(directory).startsWith("trellis-plugin-test-"))
    rmSync(directory, { recursive: true, force: true })
  })
  const task = ".trellis/tasks/fixture"
  mkdirSync(join(directory, task), { recursive: true })
  mkdirSync(join(directory, ".trellis/.runtime/sessions"), { recursive: true })
  writeFileSync(join(directory, ".trellis/.runtime/sessions/opencode_owner.json"), JSON.stringify({ current_task: task }))
  writeFileSync(join(directory, task, "task.json"), JSON.stringify({ id: "fixture", status: "in_progress" }))
  writeFileSync(join(directory, ".trellis/workflow.md"), "[workflow-state:in_progress]\nResume current checkpoint; main implements.\n[/workflow-state:in_progress]\n")
  return { directory, task }
}

test("no-task turns never borrow the only other session; active turns survive recovery", async t => {
  const { directory } = fixture(t)
  const hooks = await workflowPlugin({ directory })
  for (const input of [{ sessionID: "other" }, {}]) {
    const output = { parts: [{ type: "text", text: "hello" }] }
    await hooks["chat.message"](input, output)
    assert.equal(output.parts[0].text, "hello")
  }
  for (let turn = 0; turn < 2; turn++) {
    const output = { parts: [{ type: "text", text: "continue" }] }
    await hooks["chat.message"]({ sessionID: "owner" }, output)
    assert.match(output.parts[0].text, /fixture \(in_progress\)/)
    assert.ok(output.parts[0].text.endsWith("continue"))
  }
  const child = { parts: [{ type: "text", text: "review" }] }
  await hooks["chat.message"]({ sessionID: "owner", agent: "trellis-check" }, child)
  assert.equal(child.parts[0].text, "review")
})

test("review injection preserves assignment and lists paths without copying large artifacts", async t => {
  const { directory, task } = fixture(t)
  const marker = "DO_NOT_INJECT_TASK_CONTENT"
  for (const name of ["prd.md", "design.md", "implement.md", "check.jsonl"]) writeFileSync(join(directory, task, name), marker.repeat(10000))
  const hooks = await subagentPlugin({ directory })
  for (const role of ["trellis-check", "trellis-research", "trellis-implement"]) {
    const args = { subagent_type: role, prompt: "Review only the requested boundary." }
    const output = { args }
    await hooks["tool.execute.before"]({ tool: "task", sessionID: "owner" }, output)
    assert.equal(output.args, args)
    assert.match(args.prompt, /Only the main agent implements or fixes/)
    assert.ok(args.prompt.includes(`${task}/prd.md`))
    assert.ok(args.prompt.includes("Review only the requested boundary."))
    assert.ok(!args.prompt.includes(marker))
    assert.ok(args.prompt.length < 1500)
  }
})

test("taskless dispatch does not pick another window; explicit task hint remains available", async t => {
  const { directory, task } = fixture(t)
  const hooks = await subagentPlugin({ directory })
  const output = { args: { subagent_type: "trellis-check", prompt: "Review one file." } }
  await hooks["tool.execute.before"]({ tool: "task", sessionID: "other" }, output)
  assert.equal(output.args.prompt, "Review one file.")
  output.args.prompt = `Active task: ${task}\nReview one file.`
  await hooks["tool.execute.before"]({ tool: "task", sessionID: "other" }, output)
  assert.ok(output.args.prompt.includes(".trellis/delegation.md"))
})

test("shell identity prefix retains Windows and POSIX behavior without double prefix", async t => {
  const { directory } = fixture(t)
  for (const [platform, env, prefix] of [
    ["win32", {}, "$env:TRELLIS_CONTEXT_ID = 'opencode_owner'; "],
    ["win32", { MSYSTEM: "MINGW64" }, "export TRELLIS_CONTEXT_ID='opencode_owner'; "],
    ["linux", {}, "export TRELLIS_CONTEXT_ID='opencode_owner'; "],
  ]) {
    const hooks = await subagentPlugin({ directory, platform, env })
    const output = { args: { command: "python task.py current" } }
    await hooks["tool.execute.before"]({ tool: "bash", sessionID: "owner" }, output)
    assert.equal(output.args.command, prefix + "python task.py current")
    await hooks["tool.execute.before"]({ tool: "bash", sessionID: "owner" }, output)
    assert.equal(output.args.command, prefix + "python task.py current")
  }
})

test("interactive hook identity wins over another session in the process environment", async t => {
  const { directory, task } = fixture(t)
  const otherTask = ".trellis/tasks/other"
  mkdirSync(join(directory, otherTask), { recursive: true })
  writeFileSync(join(directory, otherTask, "task.json"), JSON.stringify({ id: "other", status: "in_progress" }))
  writeFileSync(join(directory, ".trellis/.runtime/sessions/opencode_other.json"), JSON.stringify({ current_task: otherTask }))
  process.env.TRELLIS_CONTEXT_ID = "opencode_other"
  process.env.OPENCODE_RUN_ID = "other"
  t.after(() => {
    delete process.env.TRELLIS_CONTEXT_ID
    delete process.env.OPENCODE_RUN_ID
  })
  const workflow = await workflowPlugin({ directory })
  const output = { parts: [{ type: "text", text: "continue" }] }
  await workflow["chat.message"]({ sessionID: "owner" }, output)
  assert.match(output.parts[0].text, /fixture \(in_progress\)/)
  assert.ok(!output.parts[0].text.includes("Task: other"))
  const dispatch = await subagentPlugin({ directory, platform: "win32", env: {} })
  const child = { args: { subagent_type: "trellis-check", prompt: "Inspect boundary." } }
  await dispatch["tool.execute.before"]({ tool: "task", sessionID: "owner" }, child)
  assert.ok(child.args.prompt.includes(`Active task: ${task}`))
  assert.ok(!child.args.prompt.includes(otherTask))
  const shell = { args: { command: "python task.py current" } }
  await dispatch["tool.execute.before"]({ tool: "bash", sessionID: "owner" }, shell)
  assert.equal(shell.args.command, "$env:TRELLIS_CONTEXT_ID = 'opencode_owner'; python task.py current")
  const unknown = { parts: [{ type: "text", text: "hello" }] }
  await workflow["chat.message"]({}, unknown)
  assert.equal(unknown.parts[0].text, "hello")
})
