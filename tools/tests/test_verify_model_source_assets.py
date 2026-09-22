import hashlib
import importlib.util
import json
import unittest
from pathlib import Path
from tempfile import TemporaryDirectory

SPEC = importlib.util.spec_from_file_location(
    "verify_model_source_assets", Path(__file__).parents[1] / "verify_model_source_assets.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ModelSourceAssetsTest(unittest.TestCase):
    def test_missing_and_changed_sources_rejected(self):
        with TemporaryDirectory() as folder:
            client = Path(folder)
            for name in ("physics", "models"):
                (client / "resources" / name).mkdir(parents=True)
            source = client / "machine.glb"
            source.write_bytes(b"original model")
            profile = {
                "asset_path": "res://machine.glb",
                "asset_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
            }
            (client / "resources/physics/wheeled_machine_profiles.json").write_text(
                json.dumps({"profiles": {"machine": profile}})
            )
            (client / "resources/models/attachment_catalog.json").write_text("{}")
            self.assertEqual(MODULE.verify(client), [])
            source.write_bytes(b"changed geometry")
            self.assertIn("SHA-256 mismatch", MODULE.verify(client)[0])
            source.unlink()
            self.assertIn("missing source asset", MODULE.verify(client)[0])


if __name__ == "__main__":
    unittest.main()
