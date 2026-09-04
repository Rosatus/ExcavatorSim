import type { DbcSignal } from "./types";

const MAX_DECIMALS = 10;

function decimalsFor(step: number): number {
  if (!Number.isFinite(step) || step === 0) return 0;
  const magnitude = Math.abs(step);
  for (let decimals = 0; decimals <= MAX_DECIMALS; decimals += 1) {
    const scaled = magnitude * 10 ** decimals;
    if (Math.abs(scaled - Math.round(scaled)) < 1e-6 * Math.max(1, scaled)) return decimals;
  }
  return MAX_DECIMALS;
}

export function formatSignalValue(signal: DbcSignal | undefined, value: number): string {
  if (signal === undefined) return String(value);
  if (signal.integer_only) return Math.round(value).toString();
  const decimals = Math.max(decimalsFor(signal.scale), decimalsFor(signal.offset));
  return value.toFixed(decimals);
}
