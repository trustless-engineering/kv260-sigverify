from __future__ import annotations

import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import fixed_base_bench as bench  # noqa: E402
import verilator_cache  # noqa: E402


VALID_VERIFY_CYCLE_BUDGET = 100_000


class FixedBaseBenchUnitTests(unittest.TestCase):
    def test_discover_optional_fixed_base_sources_finds_future_helper_files(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            fpga_dir = Path(tmpdir) / "fpga" / "kv260_sigv"
            rtl_dir = fpga_dir.parent / "rtl"
            fpga_dir.mkdir(parents=True)
            rtl_dir.mkdir()

            for filename in [
                "ed25519_base_table_rom.v",
                "ed25519_basepoint_window.v",
                "ed25519_fixed_base_mul.v",
                "ed25519_windowed_lookup.v",
                "unrelated_helper.v",
            ]:
                (rtl_dir / filename).write_text("// stub\n", encoding="utf-8")

            discovered = bench.discover_optional_fixed_base_sources(fpga_dir)

        self.assertEqual(
            discovered,
            [
                "../rtl/ed25519_fixed_base_mul.v",
                "../rtl/ed25519_basepoint_window.v",
                "../rtl/ed25519_base_table_rom.v",
                "../rtl/ed25519_windowed_lookup.v",
            ],
        )

    def test_build_parser_accepts_verify_and_extra_source_flags(self) -> None:
        parser = bench.build_parser()

        verify_args = parser.parse_args(
            [
                "verify-engine",
                "--case",
                "valid",
                "--verify-mode",
                "agave",
                "--extra-source",
                "../rtl/ed25519_fixed_base_mul.v",
            ]
        )
        kv260_args = parser.parse_args(
            [
                "kv260-core",
                "--verify-mode",
                "strict",
                "--extra-source",
                "../rtl/ed25519_base_table_rom.v",
            ]
        )

        self.assertEqual(verify_args.target, "verify-engine")
        self.assertEqual(verify_args.case, ["valid"])
        self.assertEqual(verify_args.verify_mode, ["agave"])
        self.assertEqual(verify_args.extra_source, ["../rtl/ed25519_fixed_base_mul.v"])

        self.assertEqual(kv260_args.target, "kv260-core")
        self.assertEqual(kv260_args.verify_mode, "strict")
        self.assertEqual(kv260_args.extra_source, ["../rtl/ed25519_base_table_rom.v"])

    def test_build_verilator_cache_key_changes_when_source_header_or_version_changes(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            tmp_path = Path(tmpdir)
            src_dir = tmp_path / "src"
            include_dir = tmp_path / "include"
            src_dir.mkdir()
            include_dir.mkdir()

            source_path = src_dir / "dut.v"
            header_path = include_dir / "ed25519_constants.vh"
            source_path.write_text("module dut; endmodule\n", encoding="utf-8")
            header_path.write_text("`define FOO 1\n", encoding="utf-8")

            with patch.object(verilator_cache, "_probe_verilator_version", return_value="Verilator 5.000"):
                baseline = verilator_cache.build_verilator_cache_key(
                    "module tb; endmodule\n",
                    [source_path],
                    [include_dir],
                )
                source_path.write_text("module dut; wire x; endmodule\n", encoding="utf-8")
                source_changed = verilator_cache.build_verilator_cache_key(
                    "module tb; endmodule\n",
                    [source_path],
                    [include_dir],
                )
                self.assertNotEqual(baseline, source_changed)

                source_path.write_text("module dut; endmodule\n", encoding="utf-8")
                header_path.write_text("`define FOO 2\n", encoding="utf-8")
                header_changed = verilator_cache.build_verilator_cache_key(
                    "module tb; endmodule\n",
                    [source_path],
                    [include_dir],
                )
                self.assertNotEqual(baseline, header_changed)

            with patch.object(verilator_cache, "_probe_verilator_version", return_value="Verilator 5.001"):
                version_changed = verilator_cache.build_verilator_cache_key(
                    "module tb; endmodule\n",
                    [source_path],
                    [include_dir],
                )
            self.assertNotEqual(header_changed, version_changed)


@unittest.skipUnless(shutil.which("verilator"), "verilator is not installed")
class FixedBaseBenchIntegrationTests(unittest.TestCase):
    def test_verify_engine_benchmarks_report_cycles_and_results(self) -> None:
        results = bench.run_verify_engine_benchmarks()
        indexed = {(item["case"], item["verify_mode"]): item for item in results}

        self.assertTrue(indexed[("valid", "strict")]["verified"])
        self.assertTrue(indexed[("valid", "agave_zebra")]["verified"])
        self.assertFalse(indexed[("invalid", "strict")]["verified"])
        self.assertFalse(indexed[("invalid", "agave_zebra")]["verified"])
        self.assertLessEqual(indexed[("valid", "strict")]["cycles"], VALID_VERIFY_CYCLE_BUDGET)
        self.assertLessEqual(indexed[("valid", "agave_zebra")]["cycles"], VALID_VERIFY_CYCLE_BUDGET)

        for item in results:
            self.assertGreater(item["cycles"], 0)
            self.assertEqual(item["phase_total_cycles"], item["cycles"])
            self.assertEqual(
                sorted(item["phase_cycles"].keys()),
                sorted(bench.PHASE_COUNTER_NAMES),
            )
            self.assertGreaterEqual(item["phase_cycles"]["joint"], 0)
            self.assertIn("fixed_base_rtl_sources", item)

    def test_kv260_core_benchmarks_report_dispatch_and_cycle_metrics(self) -> None:
        results = bench.run_kv260_core_benchmarks()
        indexed = {item["case"]: item for item in results}

        full_batch = indexed["full_batch"]
        self.assertEqual(full_batch["verify_mode"], "strict")
        self.assertEqual(full_batch["dispatch_limit"], 0)
        self.assertEqual(full_batch["accepted_job_count"], 2)
        self.assertEqual(full_batch["current_job_index"], 1)
        self.assertEqual(full_batch["jobs_started"], 2)
        self.assertEqual(full_batch["jobs_completed"], 2)
        self.assertEqual(full_batch["jobs_dropped"], 0)
        self.assertEqual(full_batch["result_bits"], [True, False])
        self.assertGreater(full_batch["cycles"], 0)
        self.assertGreater(full_batch["last_batch_cycles"], 0)
        self.assertGreaterEqual(full_batch["max_job_cycles"], full_batch["last_job_cycles"])
        self.assertLessEqual(full_batch["last_job_cycles"], VALID_VERIFY_CYCLE_BUDGET)
        self.assertLessEqual(full_batch["last_batch_cycles"], VALID_VERIFY_CYCLE_BUDGET)

        truncated = indexed["dispatch_limit_1"]
        self.assertEqual(truncated["dispatch_limit"], 1)
        self.assertEqual(truncated["accepted_job_count"], 1)
        self.assertEqual(truncated["current_job_index"], 0)
        self.assertEqual(truncated["jobs_started"], 3)
        self.assertEqual(truncated["jobs_completed"], 3)
        self.assertEqual(truncated["jobs_dropped"], 1)
        self.assertEqual(truncated["result_bits"], [True])
        self.assertGreater(truncated["cycles"], 0)
        self.assertGreater(truncated["last_batch_cycles"], 0)
        self.assertGreaterEqual(truncated["max_job_cycles"], truncated["last_job_cycles"])
        self.assertLessEqual(truncated["last_job_cycles"], VALID_VERIFY_CYCLE_BUDGET)
        self.assertLessEqual(truncated["last_batch_cycles"], VALID_VERIFY_CYCLE_BUDGET)


if __name__ == "__main__":
    unittest.main()
