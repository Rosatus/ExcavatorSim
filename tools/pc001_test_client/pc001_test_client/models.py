"""Qt table models for the PC001 monitor."""

from __future__ import annotations

import time
from collections.abc import Sequence
from enum import IntEnum
from typing import Any

from PySide6.QtCore import (
    QAbstractTableModel,
    QModelIndex,
    QPersistentModelIndex,
    QSortFilterProxyModel,
    Qt,
)
from PySide6.QtGui import QBrush, QColor

from .aggregation import FrameKey, FrameSnapshot


class Column(IntEnum):
    CAN_ID = 0
    FORMAT = 1
    CHANNEL = 2
    DLC = 3
    PAYLOAD = 4
    COUNT = 5
    ACTUAL_HZ = 6
    FRESHNESS = 7


HEADERS = (
    "CAN ID",
    "格式",
    "Channel",
    "DLC",
    "Payload",
    "接收次数",
    "实际频率",
    "新鲜度",
)


class FrameTableModel(QAbstractTableModel):
    def __init__(self) -> None:
        super().__init__()
        self._rows: list[FrameSnapshot] = []
        self._row_by_key: dict[FrameKey, int] = {}
        self._display_now_s = time.monotonic()

    def rowCount(
        self,
        parent: QModelIndex | QPersistentModelIndex = QModelIndex(),  # noqa: B008
    ) -> int:
        return 0 if parent.isValid() else len(self._rows)

    def columnCount(
        self,
        parent: QModelIndex | QPersistentModelIndex = QModelIndex(),  # noqa: B008
    ) -> int:
        return 0 if parent.isValid() else len(HEADERS)

    def headerData(
        self,
        section: int,
        orientation: Qt.Orientation,
        role: int = Qt.ItemDataRole.DisplayRole,
    ) -> Any:
        if (
            role == Qt.ItemDataRole.DisplayRole
            and orientation == Qt.Orientation.Horizontal
            and 0 <= section < len(HEADERS)
        ):
            return HEADERS[section]
        return None

    def data(
        self,
        index: QModelIndex | QPersistentModelIndex,
        role: int = Qt.ItemDataRole.DisplayRole,
    ) -> Any:
        if not index.isValid() or not 0 <= index.row() < len(self._rows):
            return None
        snapshot = self._rows[index.row()]
        column = Column(index.column())
        if role == Qt.ItemDataRole.DisplayRole:
            return self._display_value(snapshot, column)
        if role == Qt.ItemDataRole.UserRole:
            return self._sort_value(snapshot, column)
        if role == Qt.ItemDataRole.TextAlignmentRole:
            if column in (Column.PAYLOAD, Column.CAN_ID):
                return int(Qt.AlignmentFlag.AlignVCenter | Qt.AlignmentFlag.AlignLeft)
            return int(Qt.AlignmentFlag.AlignCenter)
        if role == Qt.ItemDataRole.ForegroundRole and column == Column.FRESHNESS:
            return QBrush(self._freshness_color(self._age_s(snapshot)))
        return None

    def apply_snapshots(self, snapshots: Sequence[FrameSnapshot]) -> None:
        for snapshot in snapshots:
            row = self._row_by_key.get(snapshot.key)
            if row is None:
                row = len(self._rows)
                self.beginInsertRows(QModelIndex(), row, row)
                self._rows.append(snapshot)
                self._row_by_key[snapshot.key] = row
                self.endInsertRows()
                continue
            self._rows[row] = snapshot
            self.dataChanged.emit(
                self.index(row, 0),
                self.index(row, len(HEADERS) - 1),
                [Qt.ItemDataRole.DisplayRole, Qt.ItemDataRole.UserRole],
            )

    def clear(self) -> None:
        if not self._rows:
            return
        self.beginResetModel()
        self._rows.clear()
        self._row_by_key.clear()
        self.endResetModel()

    def refresh_freshness(self, now_s: float) -> None:
        self._display_now_s = now_s
        if not self._rows:
            return
        column = int(Column.FRESHNESS)
        self.dataChanged.emit(
            self.index(0, column),
            self.index(len(self._rows) - 1, column),
            [
                Qt.ItemDataRole.DisplayRole,
                Qt.ItemDataRole.ForegroundRole,
                Qt.ItemDataRole.UserRole,
            ],
        )

    def snapshot_at(self, row: int) -> FrameSnapshot:
        return self._rows[row]

    @staticmethod
    def _identity_text(snapshot: FrameSnapshot) -> str:
        width = 8 if snapshot.key.is_extended else 3
        return f"0x{snapshot.key.can_id:0{width}X}"

    def _age_s(self, snapshot: FrameSnapshot) -> float:
        return max(0.0, self._display_now_s - snapshot.last_received_s)

    def _display_value(self, snapshot: FrameSnapshot, column: Column) -> str | int:
        if column == Column.CAN_ID:
            return self._identity_text(snapshot)
        if column == Column.FORMAT:
            return "EFF" if snapshot.key.is_extended else "SFF"
        if column == Column.CHANNEL:
            return f"ch{snapshot.key.channel}"
        if column == Column.DLC:
            return snapshot.dlc
        if column == Column.PAYLOAD:
            return " ".join(f"{value:02X}" for value in snapshot.payload)
        if column == Column.COUNT:
            return snapshot.count
        if column == Column.ACTUAL_HZ:
            return "—" if snapshot.actual_hz is None else f"{snapshot.actual_hz:.2f} Hz"
        return self._format_freshness(self._age_s(snapshot))

    def _sort_value(self, snapshot: FrameSnapshot, column: Column) -> str | int | float:
        if column == Column.CAN_ID:
            return snapshot.key.can_id + (1 << 29 if snapshot.key.is_extended else 0)
        if column == Column.FORMAT:
            return int(snapshot.key.is_extended)
        if column == Column.CHANNEL:
            return snapshot.key.channel
        if column == Column.DLC:
            return snapshot.dlc
        if column == Column.PAYLOAD:
            return snapshot.payload.hex()
        if column == Column.COUNT:
            return snapshot.count
        if column == Column.ACTUAL_HZ:
            return -1.0 if snapshot.actual_hz is None else snapshot.actual_hz
        return self._age_s(snapshot)

    @staticmethod
    def _format_freshness(age_s: float) -> str:
        if age_s < 1.0:
            return f"{age_s * 1000.0:.3f} ms"
        if age_s <= 999.0:
            return f"{age_s:.3f} s"
        return ">999s"

    @staticmethod
    def _freshness_color(age_s: float) -> QColor:
        if age_s <= 0.1:
            return QColor("#16a34a")
        if age_s < 1.0:
            return QColor("#ca8a04")
        return QColor("#dc2626")


class FrameFilterProxyModel(QSortFilterProxyModel):
    def __init__(self) -> None:
        super().__init__()
        self._id_filter = ""
        self._channel_filter: int | None = None
        self.setSortRole(Qt.ItemDataRole.UserRole)
        self.setDynamicSortFilter(True)

    def set_id_filter(self, text: str) -> None:
        self._id_filter = text.strip().lower()
        self.invalidateFilter()

    def set_channel_filter(self, channel: int | None) -> None:
        self._channel_filter = channel
        self.invalidateFilter()

    def filterAcceptsRow(
        self,
        source_row: int,
        source_parent: QModelIndex | QPersistentModelIndex,
    ) -> bool:
        model = self.sourceModel()
        if not isinstance(model, FrameTableModel):
            return False
        snapshot = model.snapshot_at(source_row)
        if self._channel_filter is not None and snapshot.key.channel != self._channel_filter:
            return False
        if not self._id_filter:
            return True
        identity = FrameTableModel._identity_text(snapshot).lower()
        compact = identity.removeprefix("0x").lstrip("0") or "0"
        query = self._id_filter.removeprefix("0x").lstrip("0") or "0"
        return self._id_filter in identity or query in compact
