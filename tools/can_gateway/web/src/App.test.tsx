import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import App from "./App";
import type { CanConsoleMessage, CanConsoleSnapshot, GatewayStatus } from "./types";

const status: GatewayStatus = {
  revision: 4,
  mode: "standalone",
  platform: "windows",
  web_url: "http://127.0.0.1:29777",
  transport_kind: "tcp",
  transport_state: "ready",
  transport_detail: "tcp:127.0.0.1:5678",
  recording: false,
  timed_can_active: false,
  ict_active: true,
  periodic_armed: false,
  tcp_host: "127.0.0.1",
  tcp_port: 5678,
  can_interface: "can0",
  pc001_handshake: true,
  pc001_queued_frames: 0,
  pc001_sent_frames: 12,
  pc001_dropped_frames: 0,
  socketcan_submitted: 0,
  socketcan_sent: 0,
  socketcan_congestion_dropped: 0,
  socketcan_coalesced: 0,
  socketcan_terminal_errors: 0,
  socketcan_pending: 0,
  event_sequence: 0,
  event_earliest_sequence: 1,
  log_dropped_records: 0,
};

const signal = {
  key: "vel-e",
  name: "VelE",
  start: 0,
  length: 16,
  byte_order: "little_endian",
  is_signed: true,
  scale: 0.01,
  offset: 0,
  minimum: -327.68,
  maximum: 327.67,
  unit: "m/s",
  is_multiplexer: false,
  multiplexer_signal: null,
  multiplexer_ids: [],
};

const row: CanConsoleMessage = {
  key: "eff:0CFDA800",
  message: {
    key: "eff:0CFDA800",
    file_sha256: "abc",
    name: "MSG_0CFDA800",
    frame_id: 0x0cfda800,
    frame_id_hex: "0xCFDA800",
    is_extended: true,
    length: 8,
    channel: "ch2",
    signals: [signal],
    descriptor_fingerprint: "fingerprint",
    kind: "dbc",
    dbc_key: "legacy-key",
  },
  values: { VelE: 0 },
  payload_hex: "00 00 00 00 00 00 00 00",
  frequency_hz: 50,
  authority: "custom",
  expected_frequency_hz: 50,
  simulation_capable: true,
  simulation_available: false,
  runtime: {
    last_payload_hex: "7B00000000000000",
    last_egress_monotonic_s: 99.95,
    actual_frequency_hz: 49.875,
    sample_count: 10,
    source: "web",
    authority: "custom",
    values: { VelE: 1.23 },
  },
};

const consoleSnapshot: CanConsoleSnapshot = {
  catalog_fingerprint: "catalog",
  custom_armed: false,
  server_monotonic_s: 100,
  messages: [row],
  notices: [],
  load: { bitrate: 250000, estimated_bits_per_second: 8000, percent: 72, level: "yellow", warning: true, caveat: "informational" },
};

class MockWebSocket {
  static instances: MockWebSocket[] = [];
  onopen: (() => void) | null = null;
  onclose: (() => void) | null = null;
  onerror: (() => void) | null = null;
  onmessage: ((message: MessageEvent) => void) | null = null;
  constructor(readonly url: string) { MockWebSocket.instances.push(this); }
  close() {}
  emit(value: unknown) { this.onmessage?.({ data: JSON.stringify(value) } as MessageEvent); }
}

function json(value: unknown, statusCode = 200): Response {
  return new Response(JSON.stringify(value), { status: statusCode, headers: { "Content-Type": "application/json" } });
}

function installFetch(currentStatus = status, currentConsole = consoleSnapshot) {
  vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (!init?.method) return json({ status: currentStatus, console: currentConsole });
    if (url.endsWith("/preview")) {
      const body = JSON.parse(String(init.body)) as { payload_hex?: string; values?: Record<string, number> };
      return json({ request_id: "preview", result: { preview: body.payload_hex ? { values: { VelE: 1.23 }, payload_hex: "7B 00 00 00 00 00 00 00" } : { values: body.values, payload_hex: "7B 00 00 00 00 00 00 00" } } });
    }
    return json({ request_id: "mutation", result: { status: currentStatus } });
  }));
}

beforeEach(() => {
  localStorage.clear();
  MockWebSocket.instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
  vi.stubGlobal("matchMedia", vi.fn(() => ({ matches: false, addEventListener: vi.fn(), removeEventListener: vi.fn() })));
  Object.defineProperty(window, "matchMedia", { configurable: true, value: vi.fn(() => ({ matches: false })) });
});

afterEach(() => { cleanup(); vi.unstubAllGlobals(); });

describe("CAN console", () => {
  it("renders egress payload, frequency, freshness and expanded physical values", async () => {
    installFetch();
    render(<App />);
    expect(await screen.findByText("0xCFDA800")).toBeInTheDocument();
    expect(screen.getByText("7B 00 00 00 00 00 00 00")).toBeInTheDocument();
    expect(screen.getByText("49.875 Hz")).toBeInTheDocument();
    expect(screen.getByText(/ms$/)).toHaveClass("text-emerald-500");
    await userEvent.click(screen.getByRole("button", { name: "展开物理量" }));
    expect(screen.getByText("1.230000")).toBeInTheDocument();
  });

  it("toggles and persists light/dark theme", async () => {
    installFetch();
    render(<App />);
    const toggle = await screen.findByRole("button", { name: "切换明暗主题" });
    expect(document.documentElement).not.toHaveClass("dark");
    await userEvent.click(toggle);
    expect(document.documentElement).toHaveClass("dark");
    expect(localStorage.getItem("gateway-theme")).toBe("dark");
  });

  it("previews raw payload and saves only after explicit confirmation", async () => {
    installFetch();
    render(<App />);
    await userEvent.click(await screen.findByRole("button", { name: /编辑/ }));
    const payload = screen.getByLabelText("Payload");
    fireEvent.change(payload, { target: { value: "7b00000000000000" } });
    await waitFor(() => expect(screen.getByLabelText(/^VelE/)).toHaveValue(1.23));
    const fetchMock = vi.mocked(fetch);
    expect(fetchMock.mock.calls.filter(([, init]) => init?.method === "PUT")).toHaveLength(0);
    await userEvent.click(screen.getByRole("button", { name: /^保存$/ }));
    await waitFor(() => expect(fetchMock.mock.calls.filter(([, init]) => init?.method === "PUT")).toHaveLength(1));
  });

  it("closes the editor with Escape and restores trigger focus", async () => {
    installFetch();
    render(<App />);
    const trigger = await screen.findByRole("button", { name: /编辑/ });
    await userEvent.click(trigger);
    expect(screen.getByRole("dialog")).toBeInTheDocument();
    await userEvent.keyboard("{Escape}");
    expect(screen.queryByRole("dialog")).not.toBeInTheDocument();
    expect(trigger).toHaveFocus();
  });

  it("keeps managed row overrides while hiding standalone-only controls", async () => {
    installFetch(
      { ...status, mode: "godot-managed", pc001_handshake: false, pc001_dropped_frames: 456822 },
      { ...consoleSnapshot, messages: [{ ...row, authority: "simulation", simulation_available: true }] },
    );
    render(<App />);
    expect(await screen.findByText("Godot 托管会话")).toBeInTheDocument();
    expect(screen.queryByText("Windows PC001 Server")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /导出/ })).not.toBeInTheDocument();
    expect(screen.getByRole("radio", { name: "自定义" })).toBeEnabled();
    await userEvent.click(screen.getByRole("radio", { name: "关闭" }));
    await waitFor(() => expect(vi.mocked(fetch).mock.calls.some(([url, init]) => String(url).endsWith("/authority") && init?.method === "PUT")).toBe(true));
  });

  it("applies typed realtime deltas without a snapshot fetch", async () => {
    installFetch();
    render(<App />);
    await screen.findByText("49.875 Hz");
    const fetchCount = vi.mocked(fetch).mock.calls.length;
    MockWebSocket.instances.at(-1)!.emit({ type: "event", event: { sequence: 1, timestamp: "2026-08-31T00:00:00", monotonic_s: 101, kind: "can_console_runtime", source: "transport", detail: { server_monotonic_s: 101, rows: { [row.key]: { ...row.runtime, actual_frequency_hz: 25, last_egress_monotonic_s: 101 } } } } });
    expect(await screen.findByText("25.000 Hz")).toBeInTheDocument();
    expect(vi.mocked(fetch).mock.calls).toHaveLength(fetchCount);
  });

  it("updates the runtime summary from the realtime status delta", async () => {
    installFetch();
    render(<App />);
    await screen.findByText("12 / 0");
    const fetchCount = vi.mocked(fetch).mock.calls.length;
    MockWebSocket.instances.at(-1)!.emit({ type: "event", event: { sequence: 1, timestamp: "2026-08-31T00:00:00", monotonic_s: 101, kind: "can_console_runtime", source: "transport", detail: { server_monotonic_s: 101, rows: {}, status: { transport_state: "ready", transport_detail: "tcp:127.0.0.1:5678", recording: false, timed_can_active: false, ict_active: true, periodic_armed: false, pc001_handshake: false, pc001_queued_frames: 0, pc001_sent_frames: 13, pc001_dropped_frames: 456823, socketcan_submitted: 0, socketcan_sent: 0, socketcan_congestion_dropped: 0, socketcan_coalesced: 0, socketcan_terminal_errors: 0, socketcan_pending: 0, log_dropped_records: 0 } } } });
    expect(await screen.findByText("13 / 456823")).toBeInTheDocument();
    expect(screen.getByText("等待客户端")).toBeInTheDocument();
    expect(vi.mocked(fetch).mock.calls).toHaveLength(fetchCount);
  });

  it("falls back to a full snapshot for an invalid realtime row", async () => {
    installFetch();
    render(<App />);
    await screen.findByText("49.875 Hz");
    const fetchCount = vi.mocked(fetch).mock.calls.length;
    MockWebSocket.instances.at(-1)!.emit({ type: "event", event: { sequence: 1, timestamp: "2026-08-31T00:00:00", monotonic_s: 101, kind: "can_console_runtime", source: "transport", detail: { server_monotonic_s: 101, rows: { [row.key]: { ...row.runtime, sample_count: "bad" } } } } });
    await waitFor(() => expect(vi.mocked(fetch).mock.calls.length).toBeGreaterThan(fetchCount));
  });

  it("surfaces profile export failures through the shared error banner", async () => {
    installFetch();
    render(<App />);
    const exportButton = await screen.findByRole("button", { name: /导出/ });
    vi.mocked(fetch).mockImplementationOnce(async () => json({
      error: {
        code: "export_failed",
        message: "profile unavailable",
        request_id: "test",
        recoverable: true,
      },
    }, 500));
    await userEvent.click(exportButton);
    expect(await screen.findByText(/export_failed: profile unavailable/)).toBeInTheDocument();
  });
});
