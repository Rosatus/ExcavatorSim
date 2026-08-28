import {
  AlertTriangle,
  Cable,
  CheckCircle2,
  CircleStop,
  Database,
  Download,
  Gauge,
  LoaderCircle,
  Play,
  RefreshCw,
  Router,
  Save,
  Server,
  ShieldCheck,
  Unplug,
} from "lucide-react";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { dbcAction, eventSocketUrl, getDbc, getStatus, restartCan0, updateDbcMessage, updateTcp } from "./api";
import { Badge } from "./components/ui/badge";
import { Button } from "./components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "./components/ui/card";
import { Input } from "./components/ui/input";
import { Switch } from "./components/ui/switch";
import type { DbcMessageDraft, DbcSnapshot, GatewayEvent, GatewayStatus } from "./types";
import { GatewayApiError } from "./types";

const MAX_VISIBLE_EVENTS = 200;

function stateTone(ok: boolean): string {
  return ok ? "border-emerald-500/40 bg-emerald-500/10 text-emerald-300" : "border-amber-500/40 bg-amber-500/10 text-amber-200";
}

function StatusItem({ label, value, ok = true }: { label: string; value: string; ok?: boolean }) {
  return (
    <div className="rounded-md border border-border/70 bg-background/45 p-3">
      <div className="mb-2 text-[11px] uppercase tracking-[0.18em] text-muted-foreground">{label}</div>
      <div className="flex items-center gap-2 text-sm font-medium">
        <span className={`h-2 w-2 rounded-full ${ok ? "bg-emerald-400" : "bg-amber-400"}`} />
        <span className="truncate">{value}</span>
      </div>
    </div>
  );
}

function Header({ status, online }: { status: GatewayStatus; online: boolean }) {
  return (
    <header className="flex flex-col gap-4 border-b border-border/60 pb-6 md:flex-row md:items-end md:justify-between">
      <div>
        <div className="mb-3 flex items-center gap-2 text-xs font-semibold uppercase tracking-[0.24em] text-cyan-300">
          <Gauge className="h-4 w-4" /> ExcavatorSim / CAN Gateway
        </div>
        <h1 className="text-3xl font-semibold tracking-tight md:text-4xl">本机总线控制台</h1>
        <p className="mt-2 max-w-2xl text-sm text-muted-foreground">
          单一 Gateway 发送核心 · DBC 物理值编辑 · 平台固定传输
        </p>
      </div>
      <div className="flex flex-wrap gap-2">
        <Badge className={stateTone(online)}>{online ? "事件流在线" : "事件流重连中"}</Badge>
        <Badge>{status.mode === "standalone" ? "独立启动" : "Godot 托管"}</Badge>
        <Badge>{status.platform}</Badge>
        <Badge>rev {status.revision}</Badge>
      </div>
    </header>
  );
}

function StatusGrid({ status }: { status: GatewayStatus }) {
  const transportReady = status.transport_state === "ready";
  const handshakeReady = status.transport_kind !== "tcp" || status.pc001_handshake;
  const socketcan = status.transport_kind === "socketcan" || status.transport_kind === "vcan";
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><Server className="h-4 w-4 text-cyan-300" /> 运行状态</CardTitle>
        <CardDescription>状态信息来自不可变 Gateway 快照。</CardDescription>
      </CardHeader>
      <CardContent className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">
        <StatusItem label="传输" value={`${status.transport_kind} · ${status.transport_state}`} ok={transportReady} />
        <StatusItem
          label={status.transport_kind === "tcp" ? "PC001 握手" : "CAN 接口"}
          value={status.transport_kind === "tcp" ? (status.pc001_handshake ? "已连接" : "等待客户端") : status.can_interface}
          ok={handshakeReady}
        />
        <StatusItem label="周期发送" value={status.periodic_armed ? "运行中" : "已停止"} ok={status.periodic_armed} />
        <StatusItem label="ICT" value={status.ict_active ? "已连接" : "未连接"} ok={status.ict_active} />
        <StatusItem label="Godot 遥测" value={status.recording ? "录制中" : "未录制"} ok={!status.recording || status.ict_active} />
        {socketcan ? <>
          <StatusItem label="SocketCAN 待发送" value={`${status.socketcan_pending} 帧`} />
          <StatusItem label="提交 / 已发送" value={`${status.socketcan_submitted} / ${status.socketcan_sent}`} />
          <StatusItem label="拥塞丢弃 / 合并" value={`${status.socketcan_congestion_dropped} / ${status.socketcan_coalesced}`} ok={status.socketcan_congestion_dropped === 0} />
          <StatusItem label="终端错误" value={`${status.socketcan_terminal_errors} 次`} ok={status.socketcan_terminal_errors === 0} />
        </> : <>
          <StatusItem label="PC001 队列" value={`${status.pc001_queued_frames} 帧`} />
          <StatusItem label="已发送 / 丢弃" value={`${status.pc001_sent_frames} / ${status.pc001_dropped_frames}`} ok={status.pc001_dropped_frames === 0} />
        </>}
        <StatusItem label="日志丢弃" value={`${status.log_dropped_records} 条`} ok={status.log_dropped_records === 0} />
      </CardContent>
    </Card>
  );
}

function TransportControl({ status, mutate, busy }: { status: GatewayStatus; mutate: (action: () => Promise<void>) => void; busy: boolean }) {
  const [host, setHost] = useState(status.tcp_host);
  const [port, setPort] = useState(String(status.tcp_port));
  const [confirm, setConfirm] = useState(false);
  useEffect(() => {
    setHost(status.tcp_host);
    setPort(String(status.tcp_port));
  }, [status.tcp_host, status.tcp_port]);

  if (status.platform === "windows") {
    const numericPort = Number(port);
    const valid = host.trim().length > 0 && Number.isInteger(numericPort) && numericPort >= 1 && numericPort <= 65535;
    return (
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2"><Router className="h-4 w-4 text-cyan-300" /> Windows PC001 服务端</CardTitle>
          <CardDescription>应用新端点会先停发、断开并重新绑定；不会自动恢复周期发送。</CardDescription>
        </CardHeader>
        <CardContent className="flex flex-col gap-3 sm:flex-row sm:items-end">
          <label className="flex-1 text-xs text-muted-foreground">监听地址<Input className="mt-1" value={host} onChange={(event) => setHost(event.target.value)} /></label>
          <label className="w-full text-xs text-muted-foreground sm:w-36">端口<Input className="mt-1" type="number" value={port} onChange={(event) => setPort(event.target.value)} /></label>
          <Button disabled={!valid || busy} onClick={() => mutate(() => updateTcp(status, host, numericPort))}><Cable className="h-4 w-4" /> 应用端点</Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><Router className="h-4 w-4 text-cyan-300" /> Linux can0</CardTitle>
        <CardDescription>固定执行 down → 250 kbit/s / restart-ms=100 → txqueuelen=10 → up → 复核。</CardDescription>
      </CardHeader>
      <CardContent className="flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
        <Switch checked={confirm} onChange={setConfirm} label="我确认停发并重启 can0" />
        <Button variant="destructive" disabled={!confirm || busy} onClick={() => mutate(async () => { await restartCan0(status); setConfirm(false); })}>
          <RefreshCw className="h-4 w-4" /> 重启 can0
        </Button>
      </CardContent>
    </Card>
  );
}

function LoadMeter({ dbc }: { dbc: DbcSnapshot }) {
  const tone = dbc.load.level === "red" ? "bg-red-500" : dbc.load.level === "yellow" ? "bg-amber-400" : "bg-emerald-400";
  return (
    <div className="rounded-md border border-border bg-background/50 p-4">
      <div className="mb-2 flex items-center justify-between text-sm">
        <span className="font-medium">估算总线负载</span>
        <span className={dbc.load.warning ? "font-semibold text-amber-300" : "text-emerald-300"}>{dbc.load.percent.toFixed(2)}%</span>
      </div>
      <div className="h-2 overflow-hidden rounded-full bg-muted"><div className={`h-full ${tone}`} style={{ width: `${Math.min(dbc.load.percent, 100)}%` }} /></div>
      <p className="mt-2 text-xs text-muted-foreground">{dbc.load.caveat}；高负载只警告，不阻止发送。</p>
    </div>
  );
}

function DbcSources({ dbc }: { dbc: DbcSnapshot }) {
  return (
    <Card>
      <CardHeader>
        <CardTitle className="flex items-center gap-2"><Database className="h-4 w-4 text-cyan-300" /> DBC 来源</CardTitle>
        <CardDescription>{dbc.catalog.message_count} 个报文定义；相同内容按 SHA-256 折叠。</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        {dbc.catalog.files.map((file) => (
          <div key={file.sha256} className="rounded-md border border-border bg-background/45 p-3 text-xs">
            <div className="flex flex-wrap items-center gap-2"><Badge>{file.messages.length} messages</Badge><code className="break-all text-muted-foreground">{file.sha256}</code></div>
            <div className="mt-2 space-y-1 text-muted-foreground">{file.sources.map((source) => <div className="break-all" key={source}>{source}</div>)}</div>
            {file.parse_error && <div className="mt-2 text-red-300">解析失败：{file.parse_error}</div>}
          </div>
        ))}
      </CardContent>
    </Card>
  );
}

function MessageEditor({ draft, status, busy, mutate }: { draft: DbcMessageDraft; status: GatewayStatus; busy: boolean; mutate: (action: () => Promise<void>) => void }) {
  const [values, setValues] = useState<Record<string, string>>(() => Object.fromEntries(Object.entries(draft.values).map(([key, value]) => [key, String(value)])));
  const [enabled, setEnabled] = useState(draft.enabled);
  const [frequency, setFrequency] = useState(String(draft.frequency_hz));
  useEffect(() => {
    setValues(Object.fromEntries(Object.entries(draft.values).map(([key, value]) => [key, String(value)])));
    setEnabled(draft.enabled);
    setFrequency(String(draft.frequency_hz));
  }, [draft]);

  const parsedFrequency = Number(frequency);
  const parsedValues = Object.fromEntries(Object.entries(values).map(([key, value]) => [key, Number(value)]));
  const valuesValid = draft.message.signals.every((signal) => {
    if (!(signal.name in values)) return true;
    const value = parsedValues[signal.name];
    return Number.isFinite(value) && (signal.minimum === null || value >= signal.minimum) && (signal.maximum === null || value <= signal.maximum);
  });
  const valid = valuesValid && Number.isInteger(parsedFrequency) && parsedFrequency >= 1 && parsedFrequency <= 100;

  return (
    <div className="space-y-4 rounded-lg border border-cyan-500/25 bg-cyan-500/[0.035] p-4">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div><div className="font-semibold">{draft.message.name}</div><div className="mt-1 font-mono text-xs text-muted-foreground">{draft.message.frame_id_hex} · DLC {draft.message.length} · {draft.message.is_extended ? "EFF" : "SFF"}</div></div>
        <div className="flex items-center gap-4"><Switch checked={enabled} onChange={setEnabled} label="启用" /><Badge className={draft.generated_default ? "border-amber-500/40 text-amber-200" : ""}>{draft.generated_default ? "生成默认值" : "已编辑"}</Badge></div>
      </div>
      <div className="grid gap-3 md:grid-cols-2 xl:grid-cols-3">
        {draft.message.signals.filter((signal) => signal.name in values).map((signal) => (
          <label key={signal.key} className="text-xs text-muted-foreground">
            <span className="flex items-center justify-between gap-2"><span className="font-medium text-foreground">{signal.name}</span><span>{signal.unit || "—"}</span></span>
            <Input
              className="mt-1 font-mono"
              type="number"
              step="any"
              value={values[signal.name]}
              onChange={(event) => setValues((current) => ({ ...current, [signal.name]: event.target.value }))}
            />
            <span className="mt-1 block">{signal.minimum ?? "−∞"} … {signal.maximum ?? "+∞"} · ×{signal.scale} {signal.offset >= 0 ? "+" : ""}{signal.offset}</span>
          </label>
        ))}
      </div>
      <div className="flex flex-col gap-3 border-t border-border pt-4 sm:flex-row sm:items-end">
        <label className="w-full text-xs text-muted-foreground sm:w-36">频率 (1–100 Hz)<Input className="mt-1" type="number" min={1} max={100} step={1} value={frequency} onChange={(event) => setFrequency(event.target.value)} /></label>
        <div className="flex-1 rounded-md bg-background/70 p-3 font-mono text-xs"><span className="mr-2 text-muted-foreground">payload</span>{draft.payload_hex || "等待合法值"}</div>
        <Button disabled={!valid || busy} onClick={() => mutate(() => updateDbcMessage(status, draft.message.key, parsedValues, enabled, parsedFrequency))}><Save className="h-4 w-4" /> 保存报文</Button>
      </div>
      {!valid && <div className="text-xs text-red-300">物理值必须有限且位于 DBC 范围内；频率只接受 1–100 的整数。</div>}
    </div>
  );
}

function DbcControl({ status, dbc, refresh, mutate, busy }: { status: GatewayStatus; dbc: DbcSnapshot; refresh: () => void; mutate: (action: () => Promise<void>) => void; busy: boolean }) {
  const [query, setQuery] = useState("");
  const [selectedKey, setSelectedKey] = useState(dbc.messages[0]?.message.key ?? "");
  const messages = useMemo(() => dbc.messages.filter((item) => `${item.message.name} ${item.message.frame_id_hex}`.toLowerCase().includes(query.toLowerCase())), [dbc.messages, query]);
  const selected = dbc.messages.find((item) => item.message.key === selectedKey) ?? messages[0];
  return (
    <Card>
      <CardHeader className="gap-4 md:flex-row md:items-start md:justify-between">
        <div><CardTitle>DBC 周期发送</CardTitle><CardDescription className="mt-1">每报文独立 1–100 Hz，默认 50 Hz；错过时隙不追发。</CardDescription></div>
        <div className="flex flex-wrap gap-2">
          <Button variant="outline" disabled={busy} onClick={() => mutate(() => dbcAction("reload", status))}><RefreshCw className="h-4 w-4" /> 重载 DBC</Button>
          {dbc.armed ? (
            <Button variant="destructive" disabled={busy} onClick={() => mutate(() => dbcAction("stop", status))}><CircleStop className="h-4 w-4" /> 停止</Button>
          ) : (
            <Button disabled={busy || !dbc.messages.some((item) => item.enabled)} onClick={() => mutate(() => dbcAction("start", status))}><Play className="h-4 w-4" /> 开始发送</Button>
          )}
          <Button variant="ghost" size="icon" onClick={refresh} aria-label="刷新"><RefreshCw className="h-4 w-4" /></Button>
        </div>
      </CardHeader>
      <CardContent className="space-y-4">
        <LoadMeter dbc={dbc} />
        {[...dbc.catalog.notices, ...dbc.notices].map((notice, index) => (
          <div key={`${notice.code}-${index}`} className="flex gap-2 rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-xs text-amber-100"><AlertTriangle className="h-4 w-4 shrink-0" /><span><strong>{notice.code}</strong> · {notice.detail}{notice.source ? ` · ${notice.source}` : ""}</span></div>
        ))}
        <div className="grid gap-4 lg:grid-cols-[300px_1fr]">
          <div className="space-y-2">
            <Input placeholder="搜索报文名或 CAN ID" value={query} onChange={(event) => setQuery(event.target.value)} />
            <div className="max-h-[520px] space-y-1 overflow-auto rounded-md border border-border bg-background/45 p-2">
              {messages.map((item) => (
                <button key={item.message.key} onClick={() => setSelectedKey(item.message.key)} className={`flex w-full items-center justify-between rounded-md px-3 py-2 text-left text-sm transition ${selected?.message.key === item.message.key ? "bg-cyan-500/15 text-cyan-100" : "hover:bg-muted"}`}>
                  <span className="min-w-0"><span className="block truncate font-medium">{item.message.name}</span><span className="font-mono text-xs text-muted-foreground">{item.message.frame_id_hex}</span></span>
                  <span className={`h-2 w-2 rounded-full ${item.enabled ? "bg-emerald-400" : "bg-slate-600"}`} />
                </button>
              ))}
            </div>
          </div>
          {selected ? <MessageEditor key={selected.message.key} draft={selected} status={status} busy={busy} mutate={mutate} /> : <div className="grid min-h-48 place-items-center rounded-md border border-dashed border-border text-sm text-muted-foreground">没有可编辑报文</div>}
        </div>
      </CardContent>
    </Card>
  );
}

function EventLog({ events, gap, status }: { events: GatewayEvent[]; gap: string; status: GatewayStatus }) {
  return (
    <Card>
      <CardHeader className="gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div><CardTitle>运行事件与发送汇总</CardTitle><CardDescription className="mt-1">最多显示最近 {MAX_VISIBLE_EVENTS} 条；高频帧按报文每秒聚合。</CardDescription></div>
        <div className="flex gap-2">
          <Button asChild size="sm" variant="outline"><a href="./api/v1/logs/current"><Download className="h-3.5 w-3.5" /> 当前日志</a></Button>
          <Button asChild size="sm" variant="outline"><a href="./api/v1/logs/archive"><Download className="h-3.5 w-3.5" /> 全部日志</a></Button>
        </div>
      </CardHeader>
      <CardContent>
        {(gap || status.log_dropped_records > 0) && <div className="mb-3 flex gap-2 rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-xs text-amber-100"><AlertTriangle className="h-4 w-4" />{gap || `后台日志队列已丢弃 ${status.log_dropped_records} 条记录`}</div>}
        <div className="max-h-80 overflow-auto rounded-md border border-border bg-[#07090d] font-mono text-xs">
          {events.length === 0 ? <div className="p-6 text-center text-muted-foreground">等待事件…</div> : events.map((event) => (
            <div key={event.sequence} className="grid grid-cols-[62px_145px_1fr] gap-2 border-b border-border/45 px-3 py-2 last:border-0">
              <span className="text-slate-500">#{event.sequence}</span><span className="text-cyan-300">{event.kind}</span><span className="break-all text-slate-300">{event.source} {JSON.stringify(event.detail)}</span>
            </div>
          ))}
        </div>
      </CardContent>
    </Card>
  );
}

export default function App() {
  const [status, setStatus] = useState<GatewayStatus | null>(null);
  const [dbc, setDbc] = useState<DbcSnapshot | null>(null);
  const [events, setEvents] = useState<GatewayEvent[]>([]);
  const [online, setOnline] = useState(false);
  const [gap, setGap] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);
  const lastSequence = useRef(0);

  const refresh = useCallback(async () => {
    try {
      const [nextStatus, nextDbc] = await Promise.all([getStatus(), getDbc()]);
      setStatus(nextStatus);
      setDbc(nextDbc);
      lastSequence.current = Math.max(lastSequence.current, nextStatus.event_sequence);
      setError("");
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : "无法读取 Gateway 状态");
    }
  }, []);

  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    let socket: WebSocket | null = null;
    let timer: number | undefined;
    let closed = false;
    let retry = 500;
    const connect = () => {
      socket = new WebSocket(eventSocketUrl(lastSequence.current));
      socket.onopen = () => { setOnline(true); retry = 500; };
      socket.onmessage = (message) => {
        const data = JSON.parse(String(message.data)) as { type: string; earliest_sequence?: number; event?: GatewayEvent };
        if (data.type === "gap") {
          setGap(`事件序列存在缺口；最早可用序列为 ${data.earliest_sequence ?? "未知"}，已刷新快照。`);
          void refresh();
        } else if (data.event && data.event.sequence > lastSequence.current) {
          lastSequence.current = data.event.sequence;
          setEvents((current) => [...current, data.event!].slice(-MAX_VISIBLE_EVENTS));
          if (["transport_reconfigured", "transport_error", "dbc_started", "dbc_stopped", "dbc_reloaded", "dbc_message_updated", "pc001_connected", "pc001_disconnected", "socketcan_transmission_aggregate"].includes(data.event.kind)) void refresh();
        }
      };
      socket.onclose = () => {
        setOnline(false);
        if (!closed) { timer = window.setTimeout(connect, retry); retry = Math.min(retry * 2, 5000); }
      };
      socket.onerror = () => socket?.close();
    };
    connect();
    return () => { closed = true; if (timer) window.clearTimeout(timer); socket?.close(); };
  }, [refresh]);

  const mutate = useCallback((action: () => Promise<void>) => {
    setBusy(true);
    setError("");
    void action()
      .then(refresh)
      .catch(async (reason: unknown) => {
        if (reason instanceof GatewayApiError && reason.code === "stale_revision") await refresh();
        setError(reason instanceof GatewayApiError ? `${reason.code}: ${reason.message}` : reason instanceof Error ? reason.message : "操作失败");
      })
      .finally(() => setBusy(false));
  }, [refresh]);

  if (!status || !dbc) {
    return <main className="grid min-h-screen place-items-center bg-background text-foreground"><div className="flex items-center gap-3 text-sm text-muted-foreground"><LoaderCircle className="h-5 w-5 animate-spin text-cyan-300" /> 正在连接本机 Gateway…</div></main>;
  }

  const managed = status.mode === "godot-managed";
  return (
    <main className="min-h-screen bg-background text-foreground">
      <div className="pointer-events-none fixed inset-0 bg-[radial-gradient(circle_at_15%_0%,rgba(22,148,170,0.14),transparent_35%),radial-gradient(circle_at_85%_12%,rgba(53,87,140,0.12),transparent_30%)]" />
      <div className="relative mx-auto max-w-[1500px] space-y-5 px-4 py-6 md:px-8 md:py-9">
        <Header status={status} online={online} />
        {error && <div role="alert" className="flex items-start gap-3 rounded-md border border-red-500/35 bg-red-500/10 p-4 text-sm text-red-100"><AlertTriangle className="h-5 w-5 shrink-0" /><div><strong>操作未完成</strong><div className="mt-1 font-mono text-xs">{error}</div></div></div>}
        {managed && <div className="flex gap-3 rounded-md border border-cyan-500/30 bg-cyan-500/10 p-4 text-sm text-cyan-100"><ShieldCheck className="h-5 w-5 shrink-0" /><div><strong>Godot 托管只读模式</strong><p className="mt-1 text-xs text-cyan-100/70">此页面只展示状态与发送汇总。传输和 DBC mutation API 同样会拒绝写入。</p></div></div>}
        <StatusGrid status={status} />
        {!managed && <>
          <TransportControl status={status} mutate={mutate} busy={busy} />
          <div className="grid gap-5 xl:grid-cols-[minmax(0,1fr)_420px]"><DbcControl status={status} dbc={dbc} refresh={() => void refresh()} mutate={mutate} busy={busy} /><DbcSources dbc={dbc} /></div>
        </>}
        <EventLog events={events} gap={gap} status={status} />
        <footer className="flex flex-wrap items-center justify-between gap-3 border-t border-border/60 py-5 text-xs text-muted-foreground"><span>127.0.0.1 only · {status.web_url}</span><span className="flex items-center gap-2">{online ? <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400" /> : <Unplug className="h-3.5 w-3.5 text-amber-400" />}{status.transport_detail || "无传输详情"}</span></footer>
      </div>
    </main>
  );
}
