#!/usr/bin/env node
// neo-trellis session hook: emits a SHORT navigation entry on
// startup / resume / compact / clear. It never inlines document bodies and
// never restores a previous task.
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

function readStdin() {
  return new Promise((resolve) => {
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (c) => (data += c));
    process.stdin.on("end", () => resolve(data));
    // Non-interactive callers may close stdin slowly; don't hang the hook.
    setTimeout(() => resolve(data), 3000).unref();
  });
}

function findRoot(start) {
  let dir = start;
  for (let i = 0; i < 20; i++) {
    if (existsSync(join(dir, ".neo-trellis"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
  return null;
}

function navigation(source) {
  const lines = [
    "[neo-trellis] Project knowledge map is at .neo-trellis/map.md",
    "(machine routes: .neo-trellis/routes.json).",
    "Follow routes there before reading code broadly; read the module entry,",
    "then the constraints it links. Do not announce this message.",
  ];
  if (source === "compact" || source === "resume") {
    lines.push(
      "Context was reset: reload the relevant module entry before continuing.",
    );
  }
  return lines.join("\n");
}

let input = {};
try {
  input = JSON.parse((await readStdin()) || "{}");
} catch {
  process.exit(0); // malformed payload: fail open, no stack noise
}
// Real protocol: hook_event_name is e.g. "SessionStart"; the trigger is in
// source ("startup" | "resume" | "clear" | "compact").
const source = input.source || "startup";
const cwd = typeof input.cwd === "string" ? input.cwd : process.cwd();
const root = findRoot(cwd);
if (!root) process.exit(0);

const text = navigation(source);
// Codex and Claude both read the nested hookSpecificOutput shape; the
// hookEventName echoes the incoming event name, not the source.
const hookEventName =
  typeof input.hook_event_name === "string"
    ? input.hook_event_name
    : "SessionStart";
process.stdout.write(
  JSON.stringify({
    hookSpecificOutput: { hookEventName, additionalContext: text },
  }),
);
