import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import App from "./App";
import type { DbcSnapshot, GatewayStatus } from "./types";
import webContract from "./test/web_contract.json";

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

const message = {
  key: "hash:CFDA800:1:layout",
  file_sha256: "abc123",
  name: "MSG_0CFDA800",
  frame_id: 0x0cfda800,
  frame_id_hex: "0xCFDA800",
  is_extended: true,
  length: 8,
  signals: [
    {
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
    },
  ],
};

const dbc: DbcSnapshot = {
  armed: false,
  catalog: {
    message_count: 1,
    notices: [],
    files: [{ sha256: "abc123", sources: ["resources/dbc/can4.sy135c.dbc"], messages: [message], parse_error: "" }],
  },
  messages: [{ message, values: { VelE: 0 }, enabled: true, frequency_hz: 50, generated_default: true, payload_hex: "00 00 00 00 00 00 00 00" }],
  notices: [],
  load: { bitrate: 250000, estimated_bits_per_second: 8000, percent: 72, level: "yellow", warning: true, caveat: "informational only" },
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

function installFetch(currentStatus: GatewayStatus, mutation?: (url: string, init: RequestInit) => Response) {
  vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (init?.method) {
      if (url.endsWith("/preview")) {
        const body = JSON.parse(String(init.body)) as { values?: Record<string, number>; payload_hex?: string };
        return mutation?.(url, init) ?? json({ request_id: "preview", result: { preview: body.payload_hex ? { values: { VelE: 1.23 }, payload_hex: "7B 00 00 00 00 00 00 00" } : { values: body.values ?? {}, payload_hex: "7B 00 00 00 00 00 00 00" } } });
      }
      return mutation?.(url, init) ?? json({ request_id: "test", result: { status: currentStatus } });
    }
    if (url.includes("/dbc")) return json({ status: currentStatus, dbc });
    return json({ status: currentStatus });
  }));
}

beforeEach(() => {
  MockWebSocket.instances = [];
  vi.stubGlobal("WebSocket", MockWebSocket);
});

afterEach(() => {
  cleanup();
  vi.unstubAllGlobals();
});

describe("Gateway console capabilities", () => {
  it("keeps the typed status fixture aligned", () => {
    expect(Object.keys(status).sort()).toEqual(webContract.status_keys);
    expect(Object.keys(dbc).sort()).toEqual(webContract.dbc_root_keys);
  });

  it("omits every mutation control in Godot-managed mode", async () => {
    installFetch({ ...status, mode: "godot-managed" });
    render(<App />);
    expect(await screen.findByText("Godot 托管只读模式")).toBeInTheDocument();
    expect(screen.queryByText("DBC 周期发送")).not.toBeInTheDocument();
    expect(screen.queryByText("Windows PC001 服务端")).not.toBeInTheDocument();
    expect(screen.getByRole("link", { name: /当前日志/ })).toBeInTheDocument();
  });

  it("shows only the Windows transport control and validates integer frequency", async () => {
    installFetch(status);
    render(<App />);
    expect(await screen.findByText("Windows PC001 服务端")).toBeInTheDocument();
    expect(screen.queryByText("Linux can0")).not.toBeInTheDocument();
    expect(screen.getByText("72.00%")).toHaveClass("text-amber-300");
    const frequency = screen.getByLabelText("频率 (1–100 Hz)");
    fireEvent.change(frequency, { target: { value: "50.5" } });
    expect(screen.getByRole("button", { name: /保存报文/ })).toBeDisabled();
    expect(screen.getByText(/频率只接受 1–100 的整数/)).toBeInTheDocument();
  });

  it("previews payload into values but commits only after explicit save", async () => {
    installFetch(status);
    render(<App />);
    const payload = await screen.findByLabelText("Payload（8 字节）");
    const fetchMock = vi.mocked(fetch);
    const putCountBefore = fetchMock.mock.calls.filter(([, init]) => init?.method === "PUT").length;
    fireEvent.change(payload, { target: { value: "7b00000000000000" } });
    await waitFor(() => expect(screen.getByLabelText(/^VelE/)).toHaveValue(1.23));
    expect(payload).toHaveValue("7B 00 00 00 00 00 00 00");
    expect(fetchMock.mock.calls.some(([input]) => String(input).endsWith("/preview"))).toBe(true);
    expect(fetchMock.mock.calls.filter(([, init]) => init?.method === "PUT")).toHaveLength(putCountBefore);
    await userEvent.click(screen.getByRole("button", { name: /保存报文/ }));
    await waitFor(() => expect(fetchMock.mock.calls.filter(([, init]) => init?.method === "PUT")).toHaveLength(putCountBefore + 1));
    const saveCalls = fetchMock.mock.calls.filter(([, init]) => init?.method === "PUT");
    const saveCall = saveCalls[saveCalls.length - 1]!;
    expect(JSON.parse(String(saveCall[1]!.body))).toMatchObject({ payload_hex: "7B 00 00 00 00 00 00 00" });
    expect(JSON.parse(String(saveCall[1]!.body))).not.toHaveProperty("values");
  });

  it("does not preview or save incomplete payload", async () => {
    installFetch(status);
    render(<App />);
    const payload = await screen.findByLabelText("Payload（8 字节）");
    const fetchMock = vi.mocked(fetch);
    const previewsBefore = fetchMock.mock.calls.filter(([input]) => String(input).endsWith("/preview")).length;
    fireEvent.change(payload, { target: { value: "7B 00" } });
    expect(await screen.findByText(/恰好包含 8 字节/)).toBeInTheDocument();
    await new Promise((resolve) => setTimeout(resolve, 350));
    expect(fetchMock.mock.calls.filter(([input]) => String(input).endsWith("/preview"))).toHaveLength(previewsBefore);
    expect(screen.getByRole("button", { name: /保存报文/ })).toBeDisabled();
  });

  it("preserves unsaved edits across background snapshot refresh", async () => {
    installFetch(status);
    render(<App />);
    const payload = await screen.findByLabelText("Payload（8 字节）");
    fireEvent.change(payload, { target: { value: "7B 00" } });
    MockWebSocket.instances.at(-1)!.emit({
      type: "event",
      event: {
        sequence: 1,
        timestamp: "2026-08-28T00:00:00",
        monotonic_s: 1,
        kind: "socketcan_transmission_aggregate",
        source: "godot",
        detail: { family: "imu", sent: 10 },
      },
    });
    await waitFor(() => expect(vi.mocked(fetch).mock.calls.filter(([input]) => String(input).includes("/dbc")).length).toBeGreaterThan(1));
    expect(payload).toHaveValue("7B 00");
  });

  it("shows only confirmed can0 restart on Linux", async () => {
    installFetch({
      ...status,
      platform: "linux",
      transport_kind: "socketcan",
      socketcan_submitted: 120,
      socketcan_sent: 100,
      socketcan_congestion_dropped: 8,
      socketcan_coalesced: 12,
      socketcan_pending: 0,
    });
    render(<App />);
    expect(await screen.findByText("Linux can0")).toBeInTheDocument();
    expect(screen.queryByText("Windows PC001 服务端")).not.toBeInTheDocument();
    expect(screen.getByText("120 / 100")).toBeInTheDocument();
    expect(screen.getByText("8 / 12")).toBeInTheDocument();
    const fetchMock = vi.mocked(fetch);
    const callsBeforeAggregate = fetchMock.mock.calls.length;
    MockWebSocket.instances.at(-1)!.emit({
      type: "event",
      event: {
        sequence: 1,
        timestamp: "2026-08-28T00:00:00",
        monotonic_s: 1,
        kind: "socketcan_transmission_aggregate",
        source: "godot",
        detail: { family: "imu", sent: 10 },
      },
    });
    await waitFor(() => expect(fetchMock.mock.calls.length).toBeGreaterThan(callsBeforeAggregate));
    const restart = screen.getByRole("button", { name: /重启 can0/ });
    expect(restart).toBeDisabled();
    await userEvent.click(screen.getByText("我确认停发并重启 can0"));
    expect(restart).toBeEnabled();
  });

  it("surfaces stale revision errors and event sequence gaps", async () => {
    installFetch(status, () => json({ error: { code: "stale_revision", message: "snapshot is stale", request_id: "x", recoverable: true } }, 409));
    render(<App />);
    await screen.findByText("DBC 周期发送");
    await userEvent.click(screen.getByRole("button", { name: /开始发送/ }));
    expect(await screen.findByRole("alert")).toHaveTextContent("stale_revision");
    const socket = MockWebSocket.instances.at(-1)!;
    socket.emit({ type: "gap", earliest_sequence: 42 });
    await waitFor(() => expect(screen.getByText(/最早可用序列为 42/)).toBeInTheDocument());
  });
});
