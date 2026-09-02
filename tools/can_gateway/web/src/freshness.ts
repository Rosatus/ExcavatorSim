import type { CanConsoleMessage } from "./types";

export function formatFreshness(
  row: CanConsoleMessage,
  serverNow: number,
): { text: string; tone: string } {
  const sentAt = row.runtime.last_egress_monotonic_s;
  if (sentAt === null) return { text: "—", tone: "text-muted-foreground" };
  const ageMs = Math.max(0, (serverNow - sentAt) * 1000);
  if (ageMs > 999_000) return { text: ">999s", tone: "text-red-500" };
  const text = ageMs < 1000
    ? `${ageMs.toFixed(3)} ms`
    : `${(ageMs / 1000).toFixed(3)} s`;
  return {
    text,
    tone: ageMs < 100
      ? "text-emerald-500"
      : ageMs < 1000
        ? "text-amber-500"
        : "text-red-500",
  };
}
