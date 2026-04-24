from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "tools" / "prepare_petalinux_project.py"
SPEC = importlib.util.spec_from_file_location("prepare_petalinux_project", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class PreparePetalinuxProjectTests(unittest.TestCase):
    def test_build_metadata_text_uses_resolved_xsa_path(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            xsa_path = Path(tmpdir) / "fpga" / "kv260_sigv.xsa"
            text = MODULE.build_metadata_text(xsa_path)

        self.assertIn("PETALINUX_VER=2025.2\n", text)
        self.assertIn(f"HARDWARE_PATH={xsa_path.resolve()}\n", text)
        self.assertIn("HDF_EXT=xsa\n", text)

    def test_write_metadata_creates_parent_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            metadata_path = root / ".petalinux" / "metadata"
            xsa_path = root / "build" / "hw" / "kv260_sigv.xsa"

            MODULE.write_metadata(metadata_path, xsa_path)

            self.assertTrue(metadata_path.exists())
            self.assertIn(f"HARDWARE_PATH={xsa_path.resolve()}", metadata_path.read_text())


if __name__ == "__main__":
    unittest.main()
