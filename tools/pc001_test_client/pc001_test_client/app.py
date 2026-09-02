"""PySide6 desktop interface for the PC001 test client."""

from __future__ import annotations

import argparse
import os
import queue
import socket
import sys
import threading
import time

from PySide6.QtCore import QObject, QTimer, Signal, Slot
from PySide6.QtGui import QCloseEvent
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QSpinBox,
    QTableView,
    QVBoxLayout,
    QWidget,
)

from .aggregation import FrameAccumulator
from .models import Column, FrameFilterProxyModel, FrameTableModel
from .protocol import Pc001Batch, Pc001Error, perform_handshake, recv_batch
from .receiver import Pc001Receiver, ReceiverEvent, ReceiverState

DEFAULT_HOST = "127.0.0.1"
DEFAULT_PORT = 5678
UI_REFRESH_MS = 50


class _ReceiverSignals(QObject):
    state_received = Signal(object)


class MainWindow(QMainWindow):
    def __init__(self, host: str = DEFAULT_HOST, port: int = DEFAULT_PORT) -> None:
        super().__init__()
        self.setWindowTitle("ExcavatorSim PC001 测试客户端")
        self.resize(1120, 680)

        self._signals = _ReceiverSignals()
        self._signals.state_received.connect(self._on_receiver_state)
        self._batch_queue: queue.Queue[tuple[int, Pc001Batch, float]] = queue.Queue(
            maxsize=2048
        )
        self._queue_stats_lock = threading.Lock()
        self._dropped_ui_batches = 0
        self._clear_before_s = 0.0
        self._receiver = Pc001Receiver(
            self._signals.state_received.emit,
            self._enqueue_batch,
        )
        self._accumulator = FrameAccumulator()
        self._model = FrameTableModel()
        self._proxy = FrameFilterProxyModel()
        self._proxy.setSourceModel(self._model)

        self._host = QLineEdit(host)
        self._host.setPlaceholderText("Gateway host")
        self._port = QSpinBox()
        self._port.setRange(1, 65535)
        self._port.setValue(port)
        self._connect = QPushButton("连接")
        self._disconnect = QPushButton("断开")
        self._disconnect.setEnabled(False)
        self._pause = QPushButton("暂停显示")
        self._pause.setCheckable(True)
        self._clear = QPushButton("清空")
        self._id_filter = QLineEdit()
        self._id_filter.setPlaceholderText("过滤 CAN ID (例如 18FF)")
        self._channel_filter = QComboBox()
        self._channel_filter.addItem("全部 channel", None)
        for channel in (0, 2, 3):
            self._channel_filter.addItem(f"ch{channel}", channel)

        self._table = QTableView()
        self._table.setModel(self._proxy)
        self._table.setSortingEnabled(True)
        self._table.setAlternatingRowColors(True)
        self._table.setSelectionBehavior(QTableView.SelectionBehavior.SelectRows)
        self._table.setEditTriggers(QTableView.EditTrigger.NoEditTriggers)
        self._table.verticalHeader().setVisible(False)
        self._table.horizontalHeader().setStretchLastSection(False)
        self._table.setColumnWidth(int(Column.CAN_ID), 130)
        self._table.setColumnWidth(int(Column.FORMAT), 65)
        self._table.setColumnWidth(int(Column.CHANNEL), 85)
        self._table.setColumnWidth(int(Column.DLC), 55)
        self._table.setColumnWidth(int(Column.PAYLOAD), 245)
        self._table.setColumnWidth(int(Column.COUNT), 95)
        self._table.setColumnWidth(int(Column.ACTUAL_HZ), 110)
        self._table.setColumnWidth(int(Column.FRESHNESS), 120)

        self._state_label = QLabel("未连接")
        self._counter_label = QLabel("批次 0 · 帧 0")
        self._error_label = QLabel("")
        self._error_label.setStyleSheet("color: #dc2626")

        connection_row = QHBoxLayout()
        connection_row.addWidget(QLabel("Gateway"))
        connection_row.addWidget(self._host, 1)
        connection_row.addWidget(QLabel(":"))
        connection_row.addWidget(self._port)
        connection_row.addWidget(self._connect)
        connection_row.addWidget(self._disconnect)
        connection_row.addSpacing(16)
        connection_row.addWidget(self._pause)
        connection_row.addWidget(self._clear)

        filter_row = QHBoxLayout()
        filter_row.addWidget(self._id_filter, 1)
        filter_row.addWidget(self._channel_filter)
        filter_row.addStretch(1)
        filter_row.addWidget(self._state_label)
        filter_row.addWidget(self._counter_label)

        layout = QVBoxLayout()
        layout.addLayout(connection_row)
        layout.addLayout(filter_row)
        layout.addWidget(self._error_label)
        layout.addWidget(self._table, 1)
        central = QWidget()
        central.setLayout(layout)
        self.setCentralWidget(central)

        self._connect.clicked.connect(self._connect_requested)
        self._disconnect.clicked.connect(self._disconnect_requested)
        self._pause.toggled.connect(self._pause_toggled)
        self._clear.clicked.connect(self._clear_requested)
        self._id_filter.textChanged.connect(self._proxy.set_id_filter)
        self._channel_filter.currentIndexChanged.connect(self._channel_filter_changed)

        self._refresh_timer = QTimer(self)
        self._refresh_timer.setInterval(UI_REFRESH_MS)
        self._refresh_timer.timeout.connect(self._refresh_table)
        self._refresh_timer.start()

    @Slot()
    def _connect_requested(self) -> None:
        try:
            self._receiver.start(self._host.text(), self._port.value())
        except (RuntimeError, ValueError) as exc:
            QMessageBox.warning(self, "连接参数无效", str(exc))

    @Slot()
    def _disconnect_requested(self) -> None:
        self._receiver.stop()

    @Slot(bool)
    def _pause_toggled(self, paused: bool) -> None:
        self._pause.setText("继续显示" if paused else "暂停显示")
        if not paused:
            self._model.apply_snapshots(self._accumulator.all_snapshots())
            self._accumulator.drain_dirty()

    @Slot()
    def _clear_requested(self) -> None:
        self._clear_before_s = time.monotonic()
        while True:
            try:
                self._batch_queue.get_nowait()
            except queue.Empty:
                break
        self._accumulator.clear()
        self._model.clear()
        with self._queue_stats_lock:
            self._dropped_ui_batches = 0
        self._update_counters()

    @Slot(int)
    def _channel_filter_changed(self, index: int) -> None:
        value = self._channel_filter.itemData(index)
        self._proxy.set_channel_filter(value if isinstance(value, int) else None)

    @Slot(object)
    def _on_receiver_state(self, event_object: object) -> None:
        if not isinstance(event_object, ReceiverEvent):
            return
        event = event_object
        if event.generation != self._receiver.generation:
            return
        labels = {
            ReceiverState.CONNECTING: "正在连接",
            ReceiverState.HANDSHAKING: "正在握手",
            ReceiverState.CONNECTED: "已连接",
            ReceiverState.DISCONNECTED: "未连接",
            ReceiverState.ERROR: "连接错误",
        }
        self._state_label.setText(labels[event.state])
        active = event.state in {
            ReceiverState.CONNECTING,
            ReceiverState.HANDSHAKING,
            ReceiverState.CONNECTED,
        }
        self._connect.setEnabled(not active)
        self._disconnect.setEnabled(active)
        self._host.setEnabled(not active)
        self._port.setEnabled(not active)
        if event.state == ReceiverState.ERROR:
            self._error_label.setText(event.detail or "未知连接错误")
        elif event.state == ReceiverState.CONNECTED:
            self._error_label.clear()
        elif event.detail:
            self._error_label.setText(event.detail)

    def _enqueue_batch(self, generation: int, batch: Pc001Batch, received_s: float) -> None:
        try:
            self._batch_queue.put_nowait((generation, batch, received_s))
        except queue.Full:
            with self._queue_stats_lock:
                self._dropped_ui_batches += 1

    @Slot()
    def _refresh_table(self) -> None:
        generation = self._receiver.generation
        while True:
            try:
                batch_generation, batch, received_s = self._batch_queue.get_nowait()
            except queue.Empty:
                break
            if batch_generation == generation and received_s > self._clear_before_s:
                self._accumulator.add_batch(batch, received_s)
        self._update_counters()
        if self._pause.isChecked():
            return
        dirty = self._accumulator.drain_dirty()
        if dirty:
            self._model.apply_snapshots(dirty)
        self._model.refresh_freshness(time.monotonic())

    def _update_counters(self) -> None:
        suffix = ""
        if self._accumulator.dropped_new_identities:
            suffix = f" · 新 ID 丢弃 {self._accumulator.dropped_new_identities}"
        with self._queue_stats_lock:
            dropped_ui_batches = self._dropped_ui_batches
        if dropped_ui_batches:
            suffix += f" · UI 批次丢弃 {dropped_ui_batches}"
        self._counter_label.setText(
            f"批次 {self._accumulator.total_batches} · 帧 {self._accumulator.total_frames}{suffix}"
        )

    def closeEvent(self, event: QCloseEvent) -> None:
        try:
            self._receiver.stop()
        except RuntimeError as exc:
            QMessageBox.critical(self, "无法安全退出", str(exc))
            event.ignore()
            return
        event.accept()


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="ExcavatorSim PC001 TCP test client")
    parser.add_argument("--host", default=DEFAULT_HOST, help="Gateway TCP host")
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Gateway TCP port")
    parser.add_argument(
        "--auto-connect",
        action="store_true",
        help="connect immediately after the GUI opens",
    )
    parser.add_argument(
        "--smoke-connect",
        action="store_true",
        help=argparse.SUPPRESS,
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    if not 1 <= args.port <= 65535:
        raise SystemExit("--port must be within 1..65535")
    smoke_port_text = os.environ.get("EXCAVATORSIM_PC001_SMOKE_PORT")
    if args.smoke_connect or smoke_port_text is not None:
        smoke_host = os.environ.get("EXCAVATORSIM_PC001_SMOKE_HOST", args.host)
        smoke_port = int(smoke_port_text) if smoke_port_text is not None else args.port
        try:
            with socket.create_connection((smoke_host, smoke_port), timeout=3.0) as sock:
                sock.settimeout(0.25)
                perform_handshake(sock, timeout_s=3.0)
                if recv_batch(sock, partial_timeout_s=3.0).count < 1:
                    return 2
            return 0
        except (OSError, Pc001Error):
            return 2
    app = QApplication(sys.argv[:1])
    app.setApplicationName("ExcavatorSim PC001 Test Client")
    window = MainWindow(args.host, args.port)
    window.show()
    if args.auto_connect:
        QTimer.singleShot(0, window._connect_requested)
    return app.exec()
