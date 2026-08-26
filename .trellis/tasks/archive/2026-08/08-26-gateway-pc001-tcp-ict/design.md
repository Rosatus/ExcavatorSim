# Design — 08-26-gateway-pc001-tcp-ict

## 1. 关键决策

| 决策 | 结论 | 理由 |
|---|---|---|
| 配置位置 | Godot 面板 LineEdit + user:// ConfigFile；argv 注入 gateway | bridge 是唯一监督者，参数通道单一；现场改配置零成本 |
| gateway 角色 | TCP 服务端（同 can_replay --transport tcp） | ICT 侧 socket_bridge 是客户端，零改动复用 |
| 并发模型 | 后台 daemon 线程 + `socketserver`/裸 socket + 线程锁 | asyncio 引入复杂度；gateway 主循环是同步 recv，线程最贴合 |
| 无客户端行为 | 静默丢弃帧，状态打印一次 | ICT 未接入时录制照常，不阻塞不刷屏 |
| 多客户端 | 新连接顶替旧连接（close 旧的） | 与参考 Pc001ReplayServer 语义一致 |

## 2. pc001_sink.py 结构

```python
CAN_FRAME_STRUCT = struct.Struct("<IBBBB8s")   # 与 sinks.pack_can_frame 一致
CHANNEL_STRUCT  = struct.Struct("<i")
BATCH_PREFIX    = struct.Struct("<H")
SINGLE_FRAME_SIZE = CAN_FRAME_STRUCT.size + CHANNEL_STRUCT.size   # 20
MAX_BATCH_FRAMES = 100

class TcpPc001Sink:            # FrameSink 协议
    def __init__(self, host, port): 
        self._sock_listen(...)          # bind+listen，失败抛 RuntimeError(带端口占用提示)
        self._thread = Thread(target=self._serve_loop, daemon=True)
        self._lock; self._pending: list[bytes]   # 待发帧 (packed 16B)
        self._client: socket | None
    def append(can_id, payload)  # 锁内 pack 16B 入 _pending；满100立即唤醒 flush
    def _serve_loop()            # accept → 发"who" → 收32B校验 b"PC001"
                                 #   （失败/超时 close 继续accept）
                                 #   成功后：顶替旧 client；循环取 _pending 组批发送
                                 #   send 失败→close client 回 accept
    def close()                  # 停线程、关 server/client（幂等）
```

- 批次组装：`BATCH_PREFIX.pack(n) + n*(can_frame+channel)`；channel 恒 0。
- 握手读超时 10s（对齐参考实现）；握手期新连接到来则弃旧握手。
- peer_name() 返回 `tcp:host:port (connected)` / `(waiting)`。

### CLI 接线

```
--sink tcp --tcp-host 0.0.0.0 --tcp-port 5678
```
`run()` 中 sink=="tcp" 分支创建 TcpPc001Sink（失败 exit 1）；ICT_START/STOP 门控
与 vcan 相同（vcan/tcp 二选一由 --sink 决定）。active_sinks() 不变。

## 3. Godot 侧

### operator_ui.gd / main.tscn
- AdvancedPanel 新增：
  - `ICTHost` LineEdit（placeholder "IP，默认 0.0.0.0"，text 记忆值）
  - `ICTPort` LineEdit（placeholder "端口，默认 5678"）
- 持久化：`user://ict_config.cfg`（ConfigFile get/set "ict/host"/"ict/port"），
  `_ready` 加载、文本变更时保存（或失焦保存——用 text_changed 简单节流即可）。
- `_on_ict_pressed`：去掉 linux-only 检查；仅要求网关在线。
- `_set_ict_button`：tooltip 按 `bridge.is_linux_gateway()` 显示
  "Linux 网关：vcan 直发" / "Windows 网关：TCP host:port（PC001 协议，需对方桥接 vcan）"。

### can_telemetry_bridge.gd
- `var tcp_host := "0.0.0.0"`、`var tcp_port := 5678`（面板 setter 写入）。
- `_resolve_gateway_command()`：追加 `"--sink", "tcp", "--tcp-host", tcp_host,
  "--tcp-port", str(tcp_port)` —— **仅 Windows 分支**；Linux 分支维持 `--sink vcan`
  （保持现状：Linux 默认 vcan，也可后续加 UI 开关）。
- spawn 时若网关已在线且配置变更 → 提示需重启网关（respawn 按钮已有）。

## 4. 测试计划

| 层 | 用例 |
|---|---|
| pc001_sink 单测 | 握手成功后收批帧字节==pack_batch 期望；错误应答被拒；无客户端 append 不炸；>100 帧自动分批；断线后再连恢复收帧；close 幂等 |
| e2e 冒烟 | 脚本起 `gateway --sink tcp --smoke`，最小客户端握手并解出 ≥1 帧（复用 smoke 注入）|
| Godot | operator_ui：Windows 在线下按钮 enabled；host/port 输入持久化 round-trip；e2e argv 含 --tcp 参数（可经 spawn 探测断言） |
| 回归 | 金样本不变；矩阵绿 |

## 5. 风险

| 风险 | 缓解 |
|---|---|
| 线程与主循环数据竞争 | _pending 仅在锁内读写；client socket 只在服务线程触碰 |
| 阻塞 send 拖死线程 | client settimeout(1s)；send 失败即弃客户端 |
| 端口占用 | bind 失败 RuntimeError 文案含 netstat 提示 |
