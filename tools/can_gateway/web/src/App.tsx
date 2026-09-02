import { AlertTriangle, Cable, CheckCircle2, Download, Gauge, LoaderCircle, Moon, RefreshCw, Router, Sun, Unplug } from "lucide-react";
import { useCallback, useEffect, useRef, useState } from "react";

import { eventSocketUrl, getCanConsoleSnapshot, restartCan0, updateTcp } from "./api";
import { CanConsole } from "./components/CanConsole";
import { Badge } from "./components/ui/badge";
import { Button } from "./components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "./components/ui/card";
import { Input } from "./components/ui/input";
import { Switch } from "./components/ui/switch";
import type { CanConsoleSnapshot, GatewayEvent, GatewayStatus } from "./types";
import {
  applyCanConsoleRuntimeDelta,
  applyGatewayRuntimeStatusDelta,
  decodeCanConsoleRuntimeDelta,
  decodeGatewaySocketMessage,
  GatewayApiError,
} from "./types";

const MAX_VISIBLE_EVENTS = 200;
const SNAPSHOT_EVENTS = new Set(["transport_reconfigured", "transport_error", "can_console_started", "can_console_stopped", "can_console_message_updated", "can_console_authority_updated", "can_console_authority_bulk_updated", "can_console_profile_imported", "pc001_connected", "pc001_disconnected"]);

function useTheme(): ["light" | "dark", () => void] {
  const [theme, setTheme] = useState<"light" | "dark">(() => {
    const saved = localStorage.getItem("gateway-theme");
    if (saved === "light" || saved === "dark") return saved;
    return window.matchMedia("(prefers-color-scheme: dark)").matches ? "dark" : "light";
  });
  useEffect(() => {
    document.documentElement.classList.toggle("dark", theme === "dark");
    localStorage.setItem("gateway-theme", theme);
  }, [theme]);
  return [theme, () => setTheme((value) => value === "dark" ? "light" : "dark")];
}

function StatusItem({ label, value, ok = true, neutral = false }: { label: string; value: string; ok?: boolean; neutral?: boolean }) {
  const indicator = neutral ? "bg-muted-foreground" : ok ? "bg-emerald-500" : "bg-amber-500";
  return <div className="rounded-lg border bg-background/60 p-3"><div className="text-[11px] uppercase tracking-wider text-muted-foreground">{label}</div><div className="mt-2 flex items-center gap-2 text-sm font-medium"><span className={`h-2 w-2 rounded-full ${indicator}`} /><span className="truncate">{value}</span></div></div>;
}

function RuntimeSummary({ status }: { status: GatewayStatus }) {
  const socketcan = status.transport_kind === "socketcan" || status.transport_kind === "vcan";
  return <Card><CardHeader><CardTitle>运行状态</CardTitle><CardDescription>状态、累计计数和平台传输来自 Gateway 原子快照。</CardDescription></CardHeader><CardContent className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4 xl:grid-cols-6">
    <StatusItem label="传输" value={`${status.transport_kind} · ${status.transport_state}`} ok={status.transport_state === "ready"} />
    <StatusItem label={status.transport_kind === "tcp" ? "PC001" : "接口"} value={status.transport_kind === "tcp" ? (status.pc001_handshake ? "已握手" : "等待客户端") : status.can_interface} ok={status.transport_kind !== "tcp" || status.pc001_handshake} />
    <StatusItem label="Godot" value={status.godot_connected === null ? "不适用（独立启动）" : status.godot_connected ? "已连接" : "未连接"} ok={status.godot_connected === true} neutral={status.godot_connected === null} />
    {socketcan ? <><StatusItem label="提交 / 发送" value={`${status.socketcan_submitted} / ${status.socketcan_sent}`} /><StatusItem label="拥塞丢弃 / 合并" value={`${status.socketcan_congestion_dropped} / ${status.socketcan_coalesced}`} ok={status.socketcan_congestion_dropped === 0} /><StatusItem label="终端错误" value={`${status.socketcan_terminal_errors}`} ok={status.socketcan_terminal_errors === 0} /></> : <><StatusItem label="PC001 队列" value={`${status.pc001_queued_frames}`} /><StatusItem label="发送 / 丢弃" value={`${status.pc001_sent_frames} / ${status.pc001_dropped_frames}`} ok={status.pc001_dropped_frames === 0} /><StatusItem label="日志丢弃" value={`${status.log_dropped_records}`} ok={status.log_dropped_records === 0} /></>}
  </CardContent></Card>;
}

function TransportControl({ status, busy, mutate }: { status: GatewayStatus; busy: boolean; mutate: (action: () => Promise<void>) => void }) {
  const [host, setHost] = useState(status.tcp_host);
  const [port, setPort] = useState(String(status.tcp_port));
  const [confirm, setConfirm] = useState(false);
  useEffect(() => { setHost(status.tcp_host); setPort(String(status.tcp_port)); }, [status.tcp_host, status.tcp_port]);
  if (status.transport_kind === "tcp") {
    const numericPort = Number(port);
    const valid = host.trim().length > 0 && Number.isInteger(numericPort) && numericPort >= 1 && numericPort <= 65535;
    return <Card><CardHeader><CardTitle className="flex items-center gap-2"><Router className="h-4 w-4" /> PC001 TCP Server</CardTitle><CardDescription>Windows / Linux 默认一致；平台传输配置不会进入可移植 CAN console 配置。</CardDescription></CardHeader><CardContent className="flex flex-col gap-3 sm:flex-row sm:items-end"><label className="flex-1 text-xs text-muted-foreground">监听地址<Input className="mt-1" value={host} onChange={(event) => setHost(event.target.value)} /></label><label className="w-full text-xs text-muted-foreground sm:w-36">端口<Input className="mt-1" type="number" value={port} onChange={(event) => setPort(event.target.value)} /></label><Button disabled={!valid || busy} onClick={() => mutate(() => updateTcp(status, host, numericPort))}><Cable className="h-4 w-4" /> 应用端点</Button></CardContent></Card>;
  }
  return <Card><CardHeader><CardTitle className="flex items-center gap-2"><Router className="h-4 w-4" /> Linux can0</CardTitle><CardDescription>固定重配 250 kbit/s、restart-ms=100、txqueuelen=10。</CardDescription></CardHeader><CardContent className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between"><Switch checked={confirm} onChange={setConfirm} label="确认停发并重启 can0" /><Button variant="destructive" disabled={!confirm || busy} onClick={() => mutate(async () => { await restartCan0(status); setConfirm(false); })}><RefreshCw className="h-4 w-4" /> 重启 can0</Button></CardContent></Card>;
}

function EventLog({ events, gap }: { events: GatewayEvent[]; gap: string }) {
  return <Card><CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between"><div><CardTitle>运行事件</CardTitle><CardDescription className="mt-1">高频发送只发布合并后的实时行增量，不逐帧刷屏。</CardDescription></div><div className="flex gap-2"><Button asChild size="sm" variant="outline"><a href="./api/v1/logs/current"><Download className="h-3.5 w-3.5" /> 当前日志</a></Button><Button asChild size="sm" variant="outline"><a href="./api/v1/logs/archive"><Download className="h-3.5 w-3.5" /> 全部日志</a></Button></div></CardHeader><CardContent>{gap && <div className="mb-3 rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-xs text-amber-700 dark:text-amber-200">{gap}</div>}<div className="max-h-64 overflow-auto rounded-lg border bg-muted/35 font-mono text-xs">{events.length === 0 ? <div className="p-6 text-center text-muted-foreground">等待事件…</div> : events.map((event) => <div key={event.sequence} className="grid grid-cols-[62px_170px_1fr] gap-2 border-b px-3 py-2 last:border-0"><span className="text-muted-foreground">#{event.sequence}</span><span className="text-primary">{event.kind}</span><span className="break-all text-muted-foreground">{event.source} {JSON.stringify(event.detail)}</span></div>)}</div></CardContent></Card>;
}

export default function App() {
  const [theme, toggleTheme] = useTheme();
  const [status, setStatus] = useState<GatewayStatus | null>(null);
  const [consoleSnapshot, setConsoleSnapshot] = useState<CanConsoleSnapshot | null>(null);
  const [events, setEvents] = useState<GatewayEvent[]>([]);
  const [online, setOnline] = useState(false);
  const [gap, setGap] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const lastSequence = useRef(0);
  const refreshGeneration = useRef(0);

  const refresh = useCallback(async () => {
    const generation = ++refreshGeneration.current;
    try {
      const snapshot = await getCanConsoleSnapshot();
      if (generation !== refreshGeneration.current) return;
      setStatus(snapshot.status); setConsoleSnapshot(snapshot.console);
      lastSequence.current = Math.max(lastSequence.current, snapshot.status.event_sequence); setError("");
    } catch (reason) { if (generation === refreshGeneration.current) setError(reason instanceof Error ? reason.message : "无法读取 Gateway 状态"); }
  }, []);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    let socket: WebSocket | null = null; let timer: number | undefined; let disposed = false; let retry = 500;
    const connect = () => {
      socket = new WebSocket(eventSocketUrl(lastSequence.current));
      socket.onopen = () => { setOnline(true); retry = 500; };
      socket.onmessage = (message) => {
        let decoded; try { decoded = decodeGatewaySocketMessage(JSON.parse(String(message.data))); } catch { decoded = null; }
        if (!decoded) { void refresh(); return; }
        if (decoded.type === "gap") { setGap(`事件序列存在缺口；最早可用序列 ${decoded.earliest_sequence ?? "未知"}，已恢复完整快照。`); void refresh(); return; }
        const event = decoded.event; if (event.sequence <= lastSequence.current) return;
        lastSequence.current = event.sequence; setEvents((current) => [...current, event].slice(-MAX_VISIBLE_EVENTS));
        if (event.kind === "can_console_runtime") {
          const delta = decodeCanConsoleRuntimeDelta(event);
          if (!delta) { void refresh(); return; }
          setConsoleSnapshot((current) => current ? applyCanConsoleRuntimeDelta(current, delta) : current);
          const runtimeStatus = delta.status;
          if (runtimeStatus) setStatus((current) => current ? applyGatewayRuntimeStatusDelta(current, runtimeStatus) : current);
        }
        else if (SNAPSHOT_EVENTS.has(event.kind)) void refresh();
      };
      socket.onclose = () => { setOnline(false); if (!disposed) { timer = window.setTimeout(connect, retry); retry = Math.min(retry * 2, 5000); } };
      socket.onerror = () => socket?.close();
    };
    connect(); return () => { disposed = true; if (timer) window.clearTimeout(timer); socket?.close(); };
  }, [refresh]);
  const mutate = useCallback((action: () => Promise<void>) => {
    setBusy(true); setError("");
    void action().then(refresh).catch(async (reason: unknown) => { if (reason instanceof GatewayApiError && reason.code === "stale_revision") await refresh(); setError(reason instanceof GatewayApiError ? `${reason.code}: ${reason.message}` : reason instanceof Error ? reason.message : "操作失败"); }).finally(() => setBusy(false));
  }, [refresh]);

  if (!status || !consoleSnapshot) return <main className="grid min-h-screen place-items-center bg-background text-foreground"><div className="flex items-center gap-3 text-sm text-muted-foreground"><LoaderCircle className="h-5 w-5 animate-spin" /> 正在连接本机 Gateway…</div></main>;
  return <main className="min-h-screen bg-background text-foreground"><div className="mx-auto max-w-[1700px] space-y-5 px-4 py-6 md:px-8">
    <header className="flex flex-col gap-4 border-b pb-5 md:flex-row md:items-end md:justify-between"><div><div className="flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.2em] text-primary"><Gauge className="h-4 w-4" /> ExcavatorSim / CAN Gateway</div><h1 className="mt-3 text-3xl font-semibold">本机 CAN 实时控制台</h1><p className="mt-2 text-sm text-muted-foreground">逐 ID 单一发送权威 · 共享编码核心 · 按当前传输能力控制 TCP / can0</p></div><div className="flex flex-wrap items-center gap-2"><Badge>{online ? "事件流在线" : "事件流重连"}</Badge><Badge>{status.mode === "standalone" ? "独立启动" : "Godot 托管"}</Badge><Badge>{status.platform}</Badge><Badge>rev {status.revision}</Badge><Button variant="outline" size="icon" onClick={toggleTheme} aria-label="切换明暗主题">{theme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}</Button></div></header>
    {error && <div role="alert" className="flex gap-3 rounded-lg border border-red-500/35 bg-red-500/10 p-4 text-sm text-red-600 dark:text-red-200"><AlertTriangle className="h-5 w-5 shrink-0" /><div><strong>操作未完成</strong><div className="mt-1 font-mono text-xs">{error}</div></div></div>}
    {status.mode === "godot-managed" && <div className="rounded-lg border border-primary/30 bg-primary/10 p-4 text-sm"><strong>Godot 托管会话</strong><p className="mt-1 text-xs text-muted-foreground">可仿真报文默认处于“仿真”。本页允许逐 ID 临时切换关闭或自定义；传输、导入导出和全局 arm 仍由服务端禁止。</p></div>}
    <RuntimeSummary status={status} />
    {status.mode === "standalone" && <TransportControl status={status} busy={busy} mutate={mutate} />}
    <CanConsole status={status} consoleSnapshot={consoleSnapshot} busy={busy} mutate={mutate} />
    <EventLog events={events} gap={gap} />
    <footer className="flex flex-wrap items-center justify-between gap-3 border-t py-5 text-xs text-muted-foreground"><span>127.0.0.1 only · {status.web_url}</span><span className="flex items-center gap-2">{online ? <CheckCircle2 className="h-3.5 w-3.5 text-emerald-500" /> : <Unplug className="h-3.5 w-3.5 text-amber-500" />}{status.transport_detail || "无传输详情"}</span></footer>
  </div></main>;
}
