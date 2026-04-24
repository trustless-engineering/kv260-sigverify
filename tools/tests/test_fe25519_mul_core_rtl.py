from __future__ import annotations

import random
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "fpga" / "rtl"
FIELD_P = (1 << 255) - 19


def _format_vectors() -> str:
    vectors: list[tuple[int, int]] = [
        (0, 0),
        (0, 1),
        (1, 1),
        (2, FIELD_P - 1),
        (FIELD_P - 1, FIELD_P - 1),
        (FIELD_P - 2, FIELD_P - 3),
    ]
    rng = random.Random(0)
    for _ in range(8):
        vectors.append((rng.randrange(FIELD_P), rng.randrange(FIELD_P)))

    lines: list[str] = []
    for index, (lhs, rhs) in enumerate(vectors):
        expected = (lhs * rhs) % FIELD_P
        lines.append(
            "    run_case(\n"
            f"      255'h{lhs:064x},\n"
            f"      255'h{rhs:064x},\n"
            f"      255'h{expected:064x},\n"
            f"      \"case_{index}\"\n"
            "    );"
        )
    return "\n".join(lines)


@unittest.skipUnless(shutil.which("verilator"), "verilator is not installed")
class Fe25519MulCoreRtlTests(unittest.TestCase):
    def _run_multiplier_bench(
        self,
        *,
        module_name: str,
        source_files: list[str],
        latency_budget: int,
    ) -> None:
        tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg [254:0] a = 255'd0;
  reg [254:0] b = 255'd0;
  wire busy;
  wire done;
  wire [254:0] result;
  integer cycles;

  {module_name} dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .a(a),
    .b(b),
    .busy(busy),
    .done(done),
    .result(result)
  );

  always #5 clk = ~clk;

  task automatic run_case;
    input [254:0] lhs;
    input [254:0] rhs;
    input [254:0] expected;
    input [8*32-1:0] case_name;
    begin
      a = lhs;
      b = rhs;
      @(posedge clk);
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;
      cycles = 0;
      while (!done) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (cycles > {latency_budget}) begin
          $display("LATENCY_MISMATCH case=%0s cycles=%0d", case_name, cycles);
          $fatal(1);
        end
      end
      if (result !== expected) begin
        $display("RESULT_MISMATCH case=%0s got=%064x expected=%064x", case_name, result, expected);
        $fatal(1);
      end
      if (busy) begin
        $display("BUSY_MISMATCH case=%0s", case_name);
        $fatal(1);
      end
      @(posedge clk);
    end
  endtask

  initial begin
    #20;
    rst_n = 1'b1;
    #20;
{_format_vectors()}
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        with tempfile.TemporaryDirectory() as temp_dir:
            tb_path = Path(temp_dir) / "tb_fe25519_mul_core.v"
            build_dir = Path(temp_dir) / "obj_dir"
            tb_path.write_text(tb_source, encoding="utf-8")

            subprocess.run(
                [
                    "verilator",
                    "-Wno-fatal",
                    "-I.",
                    "--binary",
                    "--Mdir",
                    str(build_dir),
                    "--top-module",
                    "tb",
                    str(tb_path),
                    *source_files,
                ],
                cwd=RTL_DIR,
                check=True,
                stdout=subprocess.DEVNULL,
            )

            run = subprocess.run(
                [str(build_dir / "Vtb")],
                cwd=RTL_DIR,
                check=True,
                capture_output=True,
                text=True,
            )

        self.assertIn("PASS", run.stdout)

    def test_multiplier_matches_field_reference_and_has_bounded_latency(self) -> None:
        self._run_multiplier_bench(
            module_name="fe25519_mul_core",
            source_files=["fe25519_mul_core.v"],
            latency_budget=140,
        )

    def test_wide_multiplier_matches_field_reference_and_has_low_latency(self) -> None:
        self._run_multiplier_bench(
            module_name="fe25519_mul_wide_core",
            source_files=["fe25519_mul_wide_core.v"],
            latency_budget=33,
        )


if __name__ == "__main__":
    unittest.main()
