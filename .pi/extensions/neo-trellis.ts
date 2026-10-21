// neo-trellis Pi extension. Injects the short navigation entry once per
// agent start; it does not accumulate content on every turn.
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";

function findRoot(start: string): string | null {
  let dir = start;
  for (let i = 0; i < 20; i++) {
    if (existsSync(join(dir, ".neo-trellis"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
  return null;
}

const NAV_ENTRY = [
  "[neo-trellis] Project knowledge map is at .neo-trellis/map.md",
  "(machine routes: .neo-trellis/routes.json).",
  "Follow routes there before reading code broadly; read the module entry,",
  "then the constraints it links. Do not announce this message.",
].join("\n");

export default function neoTrellis(pi: {
  on?: (event: string, handler: (e: any, ctx: any) => any) => void;
}): void {
  pi.on?.("before_agent_start", (event: any, ctx: any) => {
    // Resolve the root per event via ctx.cwd so a session that changes
    // directory does not keep a stale project root.
    const base =
      ctx && typeof ctx.cwd === "string" ? ctx.cwd : process.cwd();
    const root = findRoot(base);
    if (!root) return;
    const cur = event?.systemPrompt ?? "";
    if (cur.includes(NAV_ENTRY)) return { systemPrompt: cur };
    return {
      systemPrompt: [cur, NAV_ENTRY].filter(Boolean).join("\n\n"),
    };
  });
}
