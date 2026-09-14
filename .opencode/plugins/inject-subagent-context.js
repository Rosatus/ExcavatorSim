/* global process */
/**
 * Trellis Context Injection Plugin
 *
 * Injects context when Task tool is called with supported subagent types.
 * Uses OpenCode's tool.execute.before hook.
 */

import { existsSync } from "fs"
import { join } from "path"
import { TrellisContext, debugLog } from "../lib/trellis-context.js"

// Supported subagent types
const AGENTS_ALL = ["implement", "check", "research"]
const AGENTS_REQUIRE_TASK = ["implement", "check"]

// Match `Active task: <path>` on the first non-empty line of the dispatch
// prompt. Mirrors the contract in workflow.md's [workflow-state:in_progress]
// breadcrumb so multi-window users can disambiguate which task is targeted.
const ACTIVE_TASK_HINT_RE = /^\s*Active task:\s*(\S+)\s*$/m

function extractActiveTaskHint(prompt) {
  if (typeof prompt !== "string" || !prompt) return null
  const match = prompt.match(ACTIVE_TASK_HINT_RE)
  return match ? match[1].trim() : null
}

/** Supply discovery paths, never the full contents of task artifacts. */
function getTaskContext(ctx, taskDir, agentType) {
  const parts = ["Read missing relevant sections only; these paths are not preloaded context."]
  if (!taskDir) return parts.join("\n")
  const full = ctx.resolveTaskDir(taskDir)
  if (!full) return parts.join("\n")
  parts.push(`Active task: ${taskDir}`)
  const names = ["prd.md", "design.md", "implement.md"]
  if (agentType === "check" || agentType === "implement") names.push(`${agentType}.jsonl`)
  for (const name of names) {
    if (existsSync(join(full, name))) parts.push(`- ${taskDir}/${name}`)
  }
  return parts.join("\n")
}

function buildPrompt(agentType, originalPrompt, context) {
  const compatibility = agentType === "implement"
    ? "Legacy implement role: return analysis and suggestions without edits.\n"
    : ""
  return `<!-- trellis-hook-injected -->
Only the main agent implements or fixes. Follow .trellis/delegation.md.
${compatibility}The dispatch supplies scope, goal and relevant acceptance.

${context}

## Assigned question
${originalPrompt}`
}

function shellQuote(value) {
  return `'${String(value).replace(/'/g, "'\\''")}'`
}

function powershellQuote(value) {
  return `'${String(value).replace(/'/g, "''")}'`
}

function envValue(env, key) {
  const value = env?.[key]
  return typeof value === "string" && value.trim() ? value.trim() : null
}

function shellBasename(value) {
  return value.replace(/\\/g, "/").split("/").pop()?.toLowerCase() || ""
}

function isWindowsPosixShell(env = process.env) {
  if (envValue(env, "MSYSTEM")) return true
  if (envValue(env, "MINGW_PREFIX")) return true
  if (envValue(env, "OPENCODE_GIT_BASH_PATH")) return true

  const ostype = envValue(env, "OSTYPE")?.toLowerCase() || ""
  if (/(msys|mingw|cygwin)/.test(ostype)) return true

  const shell = shellBasename(envValue(env, "SHELL") || "")
  return /^(bash|sh|zsh)(\.exe)?$/.test(shell)
}

function buildTrellisContextPrefix(contextKey, hostPlatform = process.platform, env = process.env) {
  if (hostPlatform === "win32" && !isWindowsPosixShell(env)) {
    return `$env:TRELLIS_CONTEXT_ID = ${powershellQuote(contextKey)}; `
  }

  return `export TRELLIS_CONTEXT_ID=${shellQuote(contextKey)}; `
}

function getBashCommandKey(args) {
  if (!args || typeof args !== "object") return null
  if (typeof args.command === "string") return "command"
  if (typeof args.cmd === "string") return "cmd"
  return null
}

function commandStartsWithTrellisContext(command) {
  const firstCommand = command.trimStart().split(/[;&|]/, 1)[0].trimStart()
  return (
    /^TRELLIS_CONTEXT_ID\s*=/.test(firstCommand) ||
    /^export\s+TRELLIS_CONTEXT_ID\s*=/.test(firstCommand) ||
    /^env\s+(?:(?:-\S+|[A-Za-z_][A-Za-z0-9_]*=\S*)\s+)*TRELLIS_CONTEXT_ID\s*=/.test(firstCommand) ||
    /^\$env:TRELLIS_CONTEXT_ID\s*=/i.test(firstCommand)
  )
}

/**
 * OpenCode TUI may not expose OPENCODE_RUN_ID to Bash. The plugin hook still
 * receives session identity, so inject it into Bash commands before execution.
 */
function injectTrellisContextIntoBash(ctx, input, output, hostPlatform, env) {
  const args = output?.args
  const commandKey = getBashCommandKey(args)
  if (!commandKey) return false

  const command = args[commandKey]
  if (!command.trim()) return false
  if (commandStartsWithTrellisContext(command)) return false

  const contextKey = ctx.getContextKey(input, { allowEnvironmentContext: false })
  if (!contextKey) return false

  args[commandKey] = `${buildTrellisContextPrefix(contextKey, hostPlatform, env)}${command}`
  return true
}

// OpenCode plugin factory: `export default async (input) => hooks`.
// OpenCode 1.2.x iterates every module export and invokes it as a function
// (packages/opencode/src/plugin/index.ts — `for ([_, fn] of Object.entries(mod)) await fn(input)`);
// the previous `{ id, server }` object shape failed with
// `TypeError: fn is not a function` in 1.2.x.
export default async ({ directory, platform: hostPlatform = process.platform, env = process.env }) => {
  const ctx = new TrellisContext(directory)
  debugLog("inject", "Plugin loaded, directory:", directory)

  return {
      "tool.execute.before": async (input, output) => {
        try {
          if (process.env.TRELLIS_HOOKS === "0" || process.env.TRELLIS_DISABLE_HOOKS === "1") {
            return
          }
          debugLog("inject", "tool.execute.before called, tool:", input?.tool)

          const toolName = input?.tool?.toLowerCase()
          if (toolName === "bash") {
            if (injectTrellisContextIntoBash(ctx, input, output, hostPlatform, env)) {
              debugLog("inject", "Injected TRELLIS_CONTEXT_ID into Bash command")
            }
            return
          }

          if (toolName !== "task") {
            return
          }

          const args = output?.args
          if (!args) return

          const rawSubagentType = args.subagent_type
          // Strip "trellis-" prefix added by v0.5.0-beta.5 agent rename migration
          const subagentType = (rawSubagentType || "").replace(/^trellis-/, "")
          const originalPrompt = args.prompt || ""

          debugLog("inject", "Task tool called, subagent_type:", rawSubagentType)

          if (!AGENTS_ALL.includes(subagentType)) {
            debugLog("inject", "Skipping - unsupported subagent_type")
            return
          }

          // Resolve active task in this priority order (only later steps
          // run when earlier ones miss):
          //   1. Exact session runtime context lookup for input.sessionID
          //   2. `Active task: <path>` hint in the dispatch prompt
          //      (explicit scope when this session has no task)
          // No single-session inference: never borrow another window's task.
          let taskDir = null

          const contextKey = ctx.getContextKey(input, { allowEnvironmentContext: false })
          if (contextKey) {
            const context = ctx.readContext(contextKey)
            const exactRef = ctx.normalizeTaskRef(context?.current_task || "")
            if (exactRef) {
              taskDir = exactRef
            }
          }

          if (!taskDir) {
            const hintRef = extractActiveTaskHint(originalPrompt)
            if (hintRef) {
              const hintNormalized = ctx.normalizeTaskRef(hintRef)
              if (hintNormalized) {
                const hintDir = ctx.resolveTaskDir(hintNormalized)
                if (hintDir && existsSync(hintDir)) {
                  taskDir = hintNormalized
                  debugLog("inject", "Resolved task from Active task: hint:", hintNormalized)
                }
              }
            }
          }

          // Agents requiring task directory
          if (AGENTS_REQUIRE_TASK.includes(subagentType)) {
            // subagentType is already stripped of "trellis-" prefix above
            if (!taskDir) {
              debugLog("inject", "Skipping - no current task")
              return
            }
            const taskDirFull = ctx.resolveTaskDir(taskDir)
            if (!taskDirFull || !existsSync(taskDirFull)) {
              debugLog("inject", "Skipping - task directory not found")
              return
            }
          }

          const context = getTaskContext(ctx, taskDir, subagentType)
          const newPrompt = buildPrompt(subagentType, originalPrompt, context)

          // Mutate args in-place — whole-object replacement does NOT work for the task tool
          // because the runtime holds a local reference to the same args object.
          args.prompt = newPrompt

          debugLog("inject", "Injected context for", subagentType, "prompt length:", newPrompt.length)

        } catch (error) {
          debugLog("inject", "Error in tool.execute.before:", error.message, error.stack)
        }
      }
    }
}
