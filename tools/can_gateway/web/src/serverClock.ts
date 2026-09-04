const TICK_MS = 50;

let anchorServer = 0;
let anchorClient = 0;
let currentServerNow = 0;
const listeners = new Set<() => void>();
let timer: number | undefined;

function tick() {
  currentServerNow = anchorServer + (performance.now() - anchorClient) / 1000;
  listeners.forEach((listener) => listener());
}

function ensureTimer() {
  if (timer !== undefined) return;
  timer = window.setInterval(tick, TICK_MS);
}

export function setServerAnchor(serverMonotonic: number) {
  anchorServer = serverMonotonic;
  anchorClient = performance.now();
  tick();
}

export function getServerNow(): number {
  return currentServerNow;
}

export function subscribeServerClock(listener: () => void): () => void {
  ensureTimer();
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}
