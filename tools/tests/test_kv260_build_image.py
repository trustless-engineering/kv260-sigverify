from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
import unittest
import zipfile
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = REPO_ROOT / "tools" / "kv260_build_image.py"
SPEC = importlib.util.spec_from_file_location("kv260_build_image", MODULE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Unable to load {MODULE_PATH}")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)

PASSING_TIMING_REPORT = """
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
      3.921        0.000                      0                80539        0.010        0.000                      0                80539        8.500        0.000                       0                 27078
""".strip()


class Kv260BuildImageMetadataTests(unittest.TestCase):
    def test_strict_bash_prelude_skips_nounset_by_default(self) -> None:
        self.assertEqual(MODULE.strict_bash_prelude(), "set -eo pipefail")

    def test_strict_bash_prelude_can_enable_nounset(self) -> None:
        self.assertEqual(MODULE.strict_bash_prelude(nounset=True), "set -euo pipefail")

    def test_generated_uenv_programs_fpga_before_boot(self) -> None:
        self.assertEqual(MODULE.UENV_FILENAME, "uEnv.txt")
        self.assertIn("initrd_high=0xffffffffffffffff", MODULE.UENV_CONTENT)
        self.assertIn("fatload ${devtype} ${devnum}:${distro_bootpart} 0x30000000 system.bit", MODULE.UENV_CONTENT)
        self.assertIn("fpga loadb 0 0x30000000 ${filesize}", MODULE.UENV_CONTENT)

    def test_write_stage_metadata_records_artifacts_and_checksums(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            stage_dir = Path(tmpdir)
            alpha = stage_dir / "alpha.bin"
            beta = stage_dir / "beta.log"
            alpha.write_bytes(b"alpha")
            beta.write_bytes(b"beta")

            MODULE.write_stage_metadata(stage_dir, qemu_timeout=12, qemu_enabled=True)

            manifest = json.loads((stage_dir / "manifest.json").read_text())
            self.assertEqual(manifest["files"], ["alpha.bin", "beta.log", "SHA256SUMS", "manifest.json"])
            self.assertEqual(manifest["manifest_file"], "manifest.json")
            self.assertEqual(manifest["sha256sums_file"], "SHA256SUMS")
            self.assertEqual(manifest["qemu_timeout_s"], 12)
            self.assertTrue(manifest["qemu_enabled"])

            artifacts = manifest["artifacts"]
            self.assertEqual([artifact["name"] for artifact in artifacts], ["alpha.bin", "beta.log"])
            self.assertEqual(artifacts[0]["size_bytes"], 5)
            self.assertEqual(artifacts[1]["size_bytes"], 4)
            self.assertEqual(
                artifacts[0]["sha256"],
                hashlib.sha256(b"alpha").hexdigest(),
            )
            self.assertEqual(
                artifacts[1]["sha256"],
                hashlib.sha256(b"beta").hexdigest(),
            )

            checksums = (stage_dir / "SHA256SUMS").read_text().splitlines()
            self.assertEqual(
                checksums,
                [
                    f"{hashlib.sha256(b'alpha').hexdigest()}  alpha.bin",
                    f"{hashlib.sha256(b'beta').hexdigest()}  beta.log",
                ],
            )

    def test_write_stage_metadata_parses_implementation_reports(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            stage_dir = Path(tmpdir)
            reports_dir = stage_dir / "reports"
            reports_dir.mkdir()
            (reports_dir / "timing_summary.rpt").write_text(PASSING_TIMING_REPORT + "\n")
            (reports_dir / "utilization.rpt").write_text(
                """
| CLB LUTs       | 29923 |     0 |          0 |    117120 | 25.55 |
| CLB Registers  | 26735 |     0 |          0 |    234240 | 11.41 |
| Block RAM Tile |    33 |     0 |          0 |       144 | 22.92 |
| DSPs           |     0 |     0 |          0 |      1248 |  0.00 |
""".strip()
                + "\n"
            )

            MODULE.write_stage_metadata(stage_dir, qemu_timeout=30, qemu_enabled=False)

            manifest = json.loads((stage_dir / "manifest.json").read_text())
            reports = manifest["implementation_reports"]
            self.assertEqual(reports["timing_summary"]["wns_ns"], 3.921)
            self.assertEqual(reports["timing_summary"]["tns_total_endpoints"], 80539)
            self.assertEqual(reports["utilization"]["CLB LUTs"]["used"], 29923)
            self.assertEqual(reports["utilization"]["Block RAM Tile"]["available"], 144)

    def test_validate_implementation_artifacts_rejects_xsa_without_full_bitstream_metadata(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            hw_dir = root / "hw"
            reports_dir = hw_dir / "reports"
            reports_dir.mkdir(parents=True)
            bit = hw_dir / "system.bit"
            bit.write_bytes(b"bit")
            (hw_dir / "hw_mode.txt").write_text("full\n")
            for name in MODULE.STAGED_REPORT_FILES:
                report_text = PASSING_TIMING_REPORT if name == "timing_summary.rpt" else "report"
                (reports_dir / name).write_text(report_text + "\n")
            xsa = hw_dir / "kv260_sigv.xsa"
            with zipfile.ZipFile(xsa, "w") as archive:
                archive.writestr("xsa.json", '{"platformState": "pre_synth", "acceleratorBinaryContent": "dcp"}')
                archive.writestr("design.bit", b"bit")

            old_xsa = MODULE.XSA_PATH
            old_bit = MODULE.VIVADO_BIT_PATH
            old_mode = MODULE.HW_MODE_PATH
            old_reports = MODULE.REPORTS_DIR
            try:
                MODULE.XSA_PATH = xsa
                MODULE.VIVADO_BIT_PATH = bit
                MODULE.HW_MODE_PATH = hw_dir / "hw_mode.txt"
                MODULE.REPORTS_DIR = reports_dir
                with self.assertRaisesRegex(RuntimeError, "does not describe an implemented full-bit export"):
                    MODULE.validate_implementation_artifacts()
            finally:
                MODULE.XSA_PATH = old_xsa
                MODULE.VIVADO_BIT_PATH = old_bit
                MODULE.HW_MODE_PATH = old_mode
                MODULE.REPORTS_DIR = old_reports

    def test_validate_implementation_artifacts_accepts_pre_synth_platform_state_with_full_bitstream(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            hw_dir = root / "hw"
            reports_dir = hw_dir / "reports"
            reports_dir.mkdir(parents=True)
            bit = hw_dir / "system.bit"
            bit.write_bytes(b"bit")
            (hw_dir / "hw_mode.txt").write_text("full\n")
            for name in MODULE.STAGED_REPORT_FILES:
                report_text = PASSING_TIMING_REPORT if name == "timing_summary.rpt" else "report"
                (reports_dir / name).write_text(report_text + "\n")
            xsa = hw_dir / "kv260_sigv.xsa"
            with zipfile.ZipFile(xsa, "w") as archive:
                archive.writestr(
                    "xsa.json",
                    json.dumps(
                        {
                            "platformState": "pre_synth",
                            "acceleratorBinaryContent": "bitstream",
                            "files": [{"name": "design.bit", "type": "FULL_BIT"}],
                        }
                    ),
                )
                archive.writestr("design.bit", b"bit")

            old_xsa = MODULE.XSA_PATH
            old_bit = MODULE.VIVADO_BIT_PATH
            old_mode = MODULE.HW_MODE_PATH
            old_reports = MODULE.REPORTS_DIR
            try:
                MODULE.XSA_PATH = xsa
                MODULE.VIVADO_BIT_PATH = bit
                MODULE.HW_MODE_PATH = hw_dir / "hw_mode.txt"
                MODULE.REPORTS_DIR = reports_dir
                metadata = MODULE.validate_implementation_artifacts()
                self.assertEqual(metadata["xsa_platform_state"], "pre_synth")
                self.assertEqual(metadata["xsa_bit_members"], ["design.bit"])
            finally:
                MODULE.XSA_PATH = old_xsa
                MODULE.VIVADO_BIT_PATH = old_bit
                MODULE.HW_MODE_PATH = old_mode
                MODULE.REPORTS_DIR = old_reports

    def test_validate_implementation_artifacts_rejects_failed_timing(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            hw_dir = root / "hw"
            reports_dir = hw_dir / "reports"
            reports_dir.mkdir(parents=True)
            bit = hw_dir / "system.bit"
            bit.write_bytes(b"bit")
            (hw_dir / "hw_mode.txt").write_text("full\n")
            for name in MODULE.STAGED_REPORT_FILES:
                report_text = "report"
                if name == "timing_summary.rpt":
                    report_text = """
    WNS(ns)      TNS(ns)  TNS Failing Endpoints  TNS Total Endpoints      WHS(ns)      THS(ns)  THS Failing Endpoints  THS Total Endpoints     WPWS(ns)     TPWS(ns)  TPWS Failing Endpoints  TPWS Total Endpoints
     -0.125       -1.250                      3                80539        0.010        0.000                      0                80539        8.500        0.000                       0                 27078
""".strip()
                (reports_dir / name).write_text(report_text + "\n")
            xsa = hw_dir / "kv260_sigv.xsa"
            with zipfile.ZipFile(xsa, "w") as archive:
                archive.writestr("xsa.json", '{"platformState": "implemented"}')
                archive.writestr("design.bit", b"bit")

            old_xsa = MODULE.XSA_PATH
            old_bit = MODULE.VIVADO_BIT_PATH
            old_mode = MODULE.HW_MODE_PATH
            old_reports = MODULE.REPORTS_DIR
            try:
                MODULE.XSA_PATH = xsa
                MODULE.VIVADO_BIT_PATH = bit
                MODULE.HW_MODE_PATH = hw_dir / "hw_mode.txt"
                MODULE.REPORTS_DIR = reports_dir
                with self.assertRaisesRegex(RuntimeError, "failed timing closure"):
                    MODULE.validate_implementation_artifacts()
            finally:
                MODULE.XSA_PATH = old_xsa
                MODULE.VIVADO_BIT_PATH = old_bit
                MODULE.HW_MODE_PATH = old_mode
                MODULE.REPORTS_DIR = old_reports

    def test_validate_packaged_bitstream_rejects_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            hw_dir = root / "hw"
            images_dir = root / "images"
            hw_dir.mkdir()
            images_dir.mkdir()
            bit = hw_dir / "system.bit"
            image_bit = images_dir / "system.bit"
            bit.write_bytes(b"implemented")
            image_bit.write_bytes(b"stale")

            old_bit = MODULE.VIVADO_BIT_PATH
            old_images = MODULE.IMAGES_DIR
            try:
                MODULE.VIVADO_BIT_PATH = bit
                MODULE.IMAGES_DIR = images_dir
                with self.assertRaisesRegex(RuntimeError, "does not match"):
                    MODULE.validate_packaged_bitstream()
            finally:
                MODULE.VIVADO_BIT_PATH = old_bit
                MODULE.IMAGES_DIR = old_images
