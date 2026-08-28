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
  messages: [{ message, values: { VelE: 0 }, enabled: true, frequency_hz: 50, generated_default: true, payload_hex: "0000000000000000" }],
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

function installFetch(currentStatus: GatewayStatus, mutation?: () => Response) {
  vi.stubGlobal("fetch", vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
    const url = String(input);
    if (init?.method) return mutation?.() ?? json({ request_id: "test", result: { status: currentStatus } });
    if (url.includes("/dbc")) return json({ dbc });
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

  it("shows only confirmed can0 restart on Linux", async () => {
    installFetch({ ...status, platform: "linux", transport_kind: "socketcan" });
    render(<App />);
    expect(await screen.findByText("Linux can0")).toBeInTheDocument();
    expect(screen.queryByText("Windows PC001 服务端")).not.toBeInTheDocument();
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
