import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

describe("server clock lifecycle", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.resetModules();
  });

  afterEach(() => {
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it("shares one timer and releases it after the final unsubscribe", async () => {
    const setIntervalSpy = vi.spyOn(window, "setInterval");
    const clearIntervalSpy = vi.spyOn(window, "clearInterval");
    const { subscribeServerClock } = await import("./serverClock");

    const unsubscribeFirst = subscribeServerClock(() => undefined);
    const unsubscribeSecond = subscribeServerClock(() => undefined);

    expect(setIntervalSpy).toHaveBeenCalledTimes(1);
    unsubscribeFirst();
    expect(clearIntervalSpy).not.toHaveBeenCalled();

    unsubscribeSecond();
    expect(clearIntervalSpy).toHaveBeenCalledTimes(1);

    const unsubscribeThird = subscribeServerClock(() => undefined);
    expect(setIntervalSpy).toHaveBeenCalledTimes(2);
    unsubscribeThird();
    expect(clearIntervalSpy).toHaveBeenCalledTimes(2);
  });
});
