from __future__ import annotations

import os
import unittest
from typing import ClassVar, cast

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from PySide6.QtCore import Qt
from PySide6.QtWidgets import QApplication

from pc001_test_client.aggregation import FrameKey, FrameSnapshot
from pc001_test_client.models import Column, FrameFilterProxyModel, FrameTableModel


class FrameModelTest(unittest.TestCase):
    app: ClassVar[QApplication]

    @classmethod
    def setUpClass(cls) -> None:
        cls.app = cast(QApplication | None, QApplication.instance()) or QApplication([])

    def test_model_formats_and_updates_one_identity(self) -> None:
        model = FrameTableModel()
        first = FrameSnapshot(FrameKey(True, 0x18FF3A00, 3), 2, b"\x01\x02", 1, 10.0, None)
        model.apply_snapshots((first,))
        self.assertEqual(model.rowCount(), 1)
        self.assertEqual(model.data(model.index(0, int(Column.CAN_ID))), "0x18FF3A00")
        self.assertEqual(model.data(model.index(0, int(Column.CHANNEL))), "ch3")
        self.assertEqual(model.data(model.index(0, int(Column.PAYLOAD))), "01 02")
        updated = FrameSnapshot(first.key, 2, b"\x03\x04", 2, 10.02, 50.0)
        model.apply_snapshots((updated,))
        self.assertEqual(model.rowCount(), 1)
        self.assertEqual(model.data(model.index(0, int(Column.COUNT))), 2)

    def test_filter_matches_id_and_channel(self) -> None:
        model = FrameTableModel()
        model.apply_snapshots(
            (
                FrameSnapshot(FrameKey(True, 0x18FF3A00, 3), 1, b"a", 1, 1.0, None),
                FrameSnapshot(FrameKey(False, 0x256, 0), 1, b"b", 1, 1.0, None),
            )
        )
        proxy = FrameFilterProxyModel()
        proxy.setSourceModel(model)
        proxy.set_id_filter("3A00")
        self.assertEqual(proxy.rowCount(), 1)
        proxy.set_id_filter("")
        proxy.set_channel_filter(0)
        self.assertEqual(proxy.rowCount(), 1)
        index = proxy.index(0, int(Column.CHANNEL))
        self.assertEqual(proxy.data(index, Qt.ItemDataRole.DisplayRole), "ch0")

    def test_freshness_boundaries(self) -> None:
        self.assertEqual(FrameTableModel._format_freshness(0.012345), "12.345 ms")
        self.assertEqual(FrameTableModel._format_freshness(1.25), "1.250 s")
        self.assertEqual(FrameTableModel._format_freshness(1000.0), ">999s")


if __name__ == "__main__":
    unittest.main()
