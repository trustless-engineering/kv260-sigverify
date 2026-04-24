#!/usr/bin/env python3
"""Benchmark harness for Ed25519 fixed-base verification experiments."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Sequence

from verilator_cache import build_verilator_cache_key


TOOLS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOLS_DIR.parent
KV260_FPGA_DIR = REPO_ROOT / "fpga" / "kv260_sigv"
RTL_BENCH_FPGA_DIR = KV260_FPGA_DIR

PUBKEY = bytes.fromhex("c33fbaf9e0492af6ba001c65cb78c8dc2cc3f76b4c6a3eb17be941ae97eaf67f")
MESSAGE = bytes.fromhex(
    "01000102c33fbaf9e0492af6ba001c65cb78c8dc2cc3f76b4c6a3eb17be941ae97eaf67f"
    "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
    "1111111111111111111111111111111111111111111111111111111111111111"
    "0101010002cafe"
)
SIGNATURE = bytes.fromhex(
    "bcdd25ebb9e6546ea7bbfe47eb9c681b7cd94a53c6d90378c6f233662053eff8"
    "5325497ba6997d1db8b30dd6f3de4b419dd912395e81fde2a62c912581b8f80d"
)
BAD_SIGNATURE = bytes([SIGNATURE[0] ^ 0x01]) + SIGNATURE[1:]

STRICT_VERIFY_MODE = 0
AGAVE_VERIFY_MODE = 1

VERIFY_MODE_LOOKUP = {
    "strict": STRICT_VERIFY_MODE,
    "agave": AGAVE_VERIFY_MODE,
    "agave_zebra": AGAVE_VERIFY_MODE,
}
VERIFY_MODE_NAMES = {
    STRICT_VERIFY_MODE: "strict",
    AGAVE_VERIFY_MODE: "agave_zebra",
}

VERIFY_ENGINE_SOURCES = [
    "../rtl/scalar_reduce_mod_l.v",
    "../rtl/scalar_wnaf4_recode.v",
    "../rtl/fe25519_mul_core.v",
    "../rtl/fe25519_mul_wide_core.v",
    "../rtl/sha512_compress_core.v",
    "../rtl/sha512_stream_engine.v",
    "../rtl/ed25519_point_core.v",
    "../rtl/ed25519_verify_engine.v",
]
KV260_CORE_SOURCES = [
    "../rtl/fe25519_aux_core.v",
    "../rtl/fe25519_mul_core.v",
    "../rtl/fe25519_mul_wide_core.v",
    "../rtl/sha512_compress_core.v",
    "../rtl/sha512_stream_engine.v",
    "../rtl/scalar_reduce_mod_l.v",
    "../rtl/scalar_wnaf4_recode.v",
    "../rtl/ed25519_point_core.v",
    "../rtl/ed25519_verify_engine.v",
    "src/sigv_kv260_core.v",
]
OPTIONAL_FIXED_BASE_SOURCE_PATTERNS = (
    "ed25519_fixed_base*.v",
    "ed25519_basepoint*.v",
    "ed25519_base_table*.v",
    "ed25519_windowed*.v",
)
PHASE_COUNTER_NAMES = (
    "control",
    "decode",
    "hash",
    "reduce",
    "precompute",
    "joint",
    "finalize",
)

VERIFY_BENCH_RE = re.compile(
    r"^BENCH case=(?P<case>\S+) mode=(?P<mode>\S+) verified=(?P<verified>[01]) cycles=(?P<cycles>\d+) "
    r"control_cycles=(?P<control_cycles>\d+) decode_cycles=(?P<decode_cycles>\d+) "
    r"hash_cycles=(?P<hash_cycles>\d+) reduce_cycles=(?P<reduce_cycles>\d+) "
    r"precompute_cycles=(?P<precompute_cycles>\d+) joint_cycles=(?P<joint_cycles>\d+) "
    r"finalize_cycles=(?P<finalize_cycles>\d+)$"
)
KV260_BENCH_RE = re.compile(
    r"^BENCH case=(?P<case>\S+) mode=(?P<mode>\S+) dispatch_limit=(?P<dispatch_limit>\d+) "
    r"cycles=(?P<cycles>\d+) result_mask=(?P<result_mask>[0-9a-fA-F]+) "
    r"accepted=(?P<accepted_job_count>\d+) current=(?P<current_job_index>\d+) "
    r"started=(?P<jobs_started>\d+) completed=(?P<jobs_completed>\d+) dropped=(?P<jobs_dropped>\d+) "
    r"last_job_cycles=(?P<last_job_cycles>\d+) max_job_cycles=(?P<max_job_cycles>\d+) "
    r"last_batch_cycles=(?P<last_batch_cycles>\d+)$"
)


@dataclass(frozen=True)
class VerifyVector:
    name: str
    pubkey: bytes
    signature: bytes
    verify_mode: int
    expected_verified: bool


def _little_endian_hex(blob: bytes) -> str:
    return blob[::-1].hex()


def _pack_word_lines(mem_name: str, blob: bytes) -> str:
    lines: list[str] = []
    for word_index in range((len(blob) + 3) // 4):
        chunk = blob[word_index * 4 : (word_index + 1) * 4]
        word = int.from_bytes(chunk.ljust(4, b"\x00"), "little")
        lines.append(f"    {mem_name}[{word_index}] = 32'h{word:08x};")
    return "\n".join(lines)


def _result_mask_bits(mask_value: int, width: int) -> list[bool]:
    return [bool((mask_value >> bit_index) & 0x1) for bit_index in range(width)]


def _verify_mode_from_name(name: str) -> int:
    return VERIFY_MODE_LOOKUP[name]


def _verify_mode_name(mode: int) -> str:
    return VERIFY_MODE_NAMES[mode]


def _phase_cycles_from_match(match: dict[str, str]) -> dict[str, int]:
    return {name: int(match[f"{name}_cycles"]) for name in PHASE_COUNTER_NAMES}


def _build_verify_vectors(case_names: Sequence[str], verify_mode_names: Sequence[str]) -> list[VerifyVector]:
    vectors: list[VerifyVector] = []
    for case_name in case_names:
        for verify_mode_name in verify_mode_names:
            verify_mode = _verify_mode_from_name(verify_mode_name)
            if case_name == "valid":
                vectors.append(
                    VerifyVector(
                        name=case_name,
                        pubkey=PUBKEY,
                        signature=SIGNATURE,
                        verify_mode=verify_mode,
                        expected_verified=True,
                    )
                )
            elif case_name == "invalid":
                vectors.append(
                    VerifyVector(
                        name=case_name,
                        pubkey=PUBKEY,
                        signature=BAD_SIGNATURE,
                        verify_mode=verify_mode,
                        expected_verified=False,
                    )
                )
            else:
                raise ValueError(f"unsupported verify case: {case_name}")
    return vectors


def discover_optional_fixed_base_sources(
    fpga_dir: Path,
    patterns: Sequence[str] = OPTIONAL_FIXED_BASE_SOURCE_PATTERNS,
) -> list[str]:
    rtl_dir = fpga_dir.parent / "rtl"
    discovered: list[str] = []
    seen: set[str] = set()
    for pattern in patterns:
        for candidate in sorted(rtl_dir.glob(pattern)):
            relative_path = str(Path("..") / "rtl" / candidate.name)
            if relative_path in seen:
                continue
            seen.add(relative_path)
            discovered.append(relative_path)
    return discovered


def resolve_rtl_sources(
    fpga_dir: Path,
    required_sources: Sequence[str],
    *,
    extra_sources: Sequence[str] = (),
) -> tuple[list[str], list[str]]:
    optional_sources = discover_optional_fixed_base_sources(fpga_dir)
    resolved: list[str] = []
    seen: set[str] = set()
    for source in [*required_sources, *optional_sources, *extra_sources]:
        if source in seen:
            continue
        seen.add(source)
        resolved.append(source)
    return resolved, optional_sources


def _run_verilator(fpga_dir: Path, tb_name: str, tb_source: str, sources: Sequence[str]) -> str:
    if shutil.which("verilator") is None:
        raise RuntimeError("verilator is not installed")

    abs_sources = [fpga_dir / s for s in sources]
    include_dirs = [fpga_dir / "src", fpga_dir.parent / "rtl"]
    cache_key = build_verilator_cache_key(tb_source, abs_sources, include_dirs)
    cache_dir = Path(tempfile.gettempdir()) / "txnverify_verilator_cache" / cache_key
    cached_binary = cache_dir / "Vtb"

    if cached_binary.exists() and os.access(cached_binary, os.X_OK):
        pass
    else:
        cache_dir.mkdir(parents=True, exist_ok=True)
        tb_path = cache_dir / tb_name
        build_dir = cache_dir / "obj_dir"
        tb_path.write_text(tb_source, encoding="utf-8")
        command = [
            "verilator",
            "-Wno-fatal",
            "-I./src",
            "-I../rtl",
            "--binary",
            "--Mdir",
            str(build_dir),
            "--top-module",
            "tb",
            str(tb_path),
            *sources,
        ]
        compile_run = subprocess.run(command, cwd=fpga_dir, capture_output=True, text=True, check=False)
        if compile_run.returncode != 0:
            shutil.rmtree(cache_dir, ignore_errors=True)
            raise RuntimeError(
                "verilator compile failed\n"
                f"stdout:\n{compile_run.stdout}\n"
                f"stderr:\n{compile_run.stderr}"
            )
        built = build_dir / "Vtb"
        if built.exists() and not cached_binary.exists():
            shutil.copy2(str(built), str(cached_binary))

    bench_run = subprocess.run(
        [str(cached_binary)],
        cwd=fpga_dir,
        capture_output=True,
        text=True,
        check=False,
    )
    if bench_run.returncode != 0:
        raise RuntimeError(
            "verilator bench failed\n"
            f"stdout:\n{bench_run.stdout}\n"
            f"stderr:\n{bench_run.stderr}"
        )
    return bench_run.stdout


def _parse_bench_lines(stdout: str, pattern: re.Pattern[str]) -> list[dict[str, str]]:
    parsed: list[dict[str, str]] = []
    for line in stdout.splitlines():
        match = pattern.match(line.strip())
        if match is not None:
            parsed.append(match.groupdict())
    if not parsed:
        raise RuntimeError(f"no BENCH lines found in output:\n{stdout}")
    return parsed


def run_verify_engine_benchmarks(
    *,
    case_names: Sequence[str] = ("valid", "invalid"),
    verify_mode_names: Sequence[str] = ("strict", "agave_zebra"),
    extra_sources: Sequence[str] = (),
) -> list[dict[str, object]]:
    vectors = _build_verify_vectors(case_names, verify_mode_names)
    message_assigns = _pack_word_lines("mem", MESSAGE)

    case_lines: list[str] = []
    for vector in vectors:
        case_lines.append(
            f"""    run_case(
      256'h{_little_endian_hex(vector.pubkey)},
      256'h{_little_endian_hex(vector.signature[:32])},
      256'h{_little_endian_hex(vector.signature[32:])},
      2'd{vector.verify_mode},
      1'b{1 if vector.expected_verified else 0}
    );
    $display("BENCH case={vector.name} mode={_verify_mode_name(vector.verify_mode)} verified=%0d cycles=%0d control_cycles=%0d decode_cycles=%0d hash_cycles=%0d reduce_cycles=%0d precompute_cycles=%0d joint_cycles=%0d finalize_cycles=%0d",
             verified, last_cycles, perf_control_cycles, perf_decode_cycles, perf_hash_cycles, perf_reduce_cycles,
             perf_precompute_cycles, perf_joint_cycles, perf_finalize_cycles);"""
        )

    tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg [15:0] message_length = 16'd{len(MESSAGE)};
  reg [255:0] pubkey_raw = 256'h{_little_endian_hex(PUBKEY)};
  reg [255:0] signature_r_raw = 256'h{_little_endian_hex(SIGNATURE[:32])};
  reg [255:0] signature_s_raw = 256'h{_little_endian_hex(SIGNATURE[32:])};
  reg [1:0] verify_mode = 2'd{STRICT_VERIFY_MODE};
  wire msg_rd_en;
  wire [10:0] msg_rd_addr;
  reg [31:0] msg_rd_data = 32'd0;
  wire busy;
  wire done;
  wire verified;
  wire [31:0] perf_total_cycles;
  wire [31:0] perf_control_cycles;
  wire [31:0] perf_decode_cycles;
  wire [31:0] perf_hash_cycles;
  wire [31:0] perf_reduce_cycles;
  wire [31:0] perf_precompute_cycles;
  wire [31:0] perf_joint_cycles;
  wire [31:0] perf_finalize_cycles;
  reg [31:0] mem [0:{(len(MESSAGE) + 3) // 4 - 1}];
  integer last_cycles = 0;

  ed25519_verify_engine #(.MESSAGE_ADDR_WIDTH(11)) dut(
    .clk(clk),
    .rst_n(rst_n),
    .abort(1'b0),
    .start(start),
    .message_length(message_length),
    .pubkey_raw(pubkey_raw),
    .signature_r_raw(signature_r_raw),
    .signature_s_raw(signature_s_raw),
    .verify_mode(verify_mode),
    .msg_rd_en(msg_rd_en),
    .msg_rd_addr(msg_rd_addr),
    .msg_rd_ready(1'b1),
    .msg_rd_data(msg_rd_data),
    .busy(busy),
    .done(done),
    .verified(verified),
    .perf_total_cycles(perf_total_cycles),
    .perf_control_cycles(perf_control_cycles),
    .perf_decode_cycles(perf_decode_cycles),
    .perf_hash_cycles(perf_hash_cycles),
    .perf_reduce_cycles(perf_reduce_cycles),
    .perf_precompute_cycles(perf_precompute_cycles),
    .perf_joint_cycles(perf_joint_cycles),
    .perf_finalize_cycles(perf_finalize_cycles)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (msg_rd_en) begin
      msg_rd_data <= mem[msg_rd_addr[6:2]];
    end
  end

  task automatic run_case;
    input [255:0] pubkey_word;
    input [255:0] r_word;
    input [255:0] s_word;
    input [1:0] mode_word;
    input expected_verified;
    begin
      pubkey_raw = pubkey_word;
      signature_r_raw = r_word;
      signature_s_raw = s_word;
      verify_mode = mode_word;
      @(posedge clk);
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;
      last_cycles = 0;
      while (!done) begin
        @(posedge clk);
        last_cycles = last_cycles + 1;
      end
      if (verified !== expected_verified) begin
        $display("VERIFY_MISMATCH got=%0d expected=%0d", verified, expected_verified);
        $fatal(1);
      end
      if (perf_total_cycles !== last_cycles) begin
        $display("VERIFY_TOTAL_CYCLE_MISMATCH measured=%0d internal=%0d", last_cycles, perf_total_cycles);
        $fatal(1);
      end
      if ((perf_control_cycles + perf_decode_cycles + perf_hash_cycles + perf_reduce_cycles +
           perf_precompute_cycles + perf_joint_cycles + perf_finalize_cycles) !== perf_total_cycles) begin
        $display("VERIFY_PHASE_SUM_MISMATCH total=%0d control=%0d decode=%0d hash=%0d reduce=%0d precompute=%0d joint=%0d finalize=%0d",
                 perf_total_cycles, perf_control_cycles, perf_decode_cycles, perf_hash_cycles, perf_reduce_cycles,
                 perf_precompute_cycles, perf_joint_cycles, perf_finalize_cycles);
        $fatal(1);
      end
      @(posedge clk);
    end
  endtask

  initial begin
{message_assigns}
    #20;
    rst_n = 1'b1;
    #20;
{chr(10).join(case_lines)}
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

    sources, optional_sources = resolve_rtl_sources(
        RTL_BENCH_FPGA_DIR,
        VERIFY_ENGINE_SOURCES,
        extra_sources=extra_sources,
    )
    stdout = _run_verilator(RTL_BENCH_FPGA_DIR, "tb_fixed_base_verify_bench.v", tb_source, sources)
    parsed = _parse_bench_lines(stdout, VERIFY_BENCH_RE)
    results: list[dict[str, object]] = []
    for result in parsed:
        phase_cycles = _phase_cycles_from_match(result)
        results.append(
            {
                "target": "verify_engine",
                "case": result["case"],
                "verify_mode": result["mode"],
                "verified": bool(int(result["verified"])),
                "cycles": int(result["cycles"]),
                "phase_cycles": phase_cycles,
                "phase_total_cycles": sum(phase_cycles.values()),
                "fixed_base_rtl_sources": optional_sources,
            }
        )
    return results


def run_kv260_core_benchmarks(
    *,
    verify_mode_name: str = "strict",
    extra_sources: Sequence[str] = (),
) -> list[dict[str, object]]:
    jobs_blob = PUBKEY + SIGNATURE + PUBKEY + BAD_SIGNATURE
    message_assigns = _pack_word_lines("message_mem", MESSAGE)
    job_assigns = _pack_word_lines("job_mem", jobs_blob)
    verify_mode = _verify_mode_from_name(verify_mode_name)

    tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg soft_reset = 0;
  reg [15:0] message_length = 16'd{len(MESSAGE)};
  reg [31:0] requested_job_count = 32'd2;
  reg [1:0] verify_mode = 2'd{verify_mode};
  reg [7:0] dispatch_limit = 8'd0;
  wire busy;
  wire done;
  wire error;
  wire result_valid;
  wire [7:0] error_code;
  wire [255:0] result_mask;
  wire [7:0] accepted_job_count;
  wire [7:0] current_job_index;
  wire [31:0] jobs_started;
  wire [31:0] jobs_completed;
  wire [31:0] jobs_dropped;
  wire [31:0] active_cycles;
  wire [31:0] last_job_cycles;
  wire [31:0] max_job_cycles;
  wire [31:0] last_batch_cycles;
  wire [31:0] batch_id;
  wire [31:0] snapshot_batch_id;
  wire [7:0] snapshot_accepted_job_count;
  wire [31:0] snapshot_jobs_completed;
  wire [31:0] snapshot_jobs_dropped;
  wire snapshot_error;
  wire snapshot_result_valid;
  wire [7:0] snapshot_error_code;
  wire message_bram_en;
  wire [9:0] message_bram_addr;
  reg [31:0] message_bram_dout = 32'd0;
  wire job_bram_en;
  wire [12:0] job_bram_addr;
  reg [31:0] job_bram_dout = 32'd0;
  reg [31:0] message_mem [0:1023];
  reg [31:0] job_mem [0:8191];
  integer index;
  integer last_cycles = 0;

  sigv_kv260_core dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .soft_reset(soft_reset),
    .message_length(message_length),
    .requested_job_count(requested_job_count),
    .verify_mode(verify_mode),
    .dispatch_limit(dispatch_limit),
    .job_timeout_cycles(32'd0),
    .busy(busy),
    .done(done),
    .error(error),
    .result_valid(result_valid),
    .error_code(error_code),
    .result_mask(result_mask),
    .accepted_job_count(accepted_job_count),
    .current_job_index(current_job_index),
    .jobs_started(jobs_started),
    .jobs_completed(jobs_completed),
    .jobs_dropped(jobs_dropped),
    .active_cycles(active_cycles),
    .last_job_cycles(last_job_cycles),
    .max_job_cycles(max_job_cycles),
    .last_batch_cycles(last_batch_cycles),
    .batch_id(batch_id),
    .snapshot_batch_id(snapshot_batch_id),
    .snapshot_accepted_job_count(snapshot_accepted_job_count),
    .snapshot_jobs_completed(snapshot_jobs_completed),
    .snapshot_jobs_dropped(snapshot_jobs_dropped),
    .snapshot_error(snapshot_error),
    .snapshot_result_valid(snapshot_result_valid),
    .snapshot_error_code(snapshot_error_code),
    .message_bram_en(message_bram_en),
    .message_bram_addr(message_bram_addr),
    .message_bram_dout(message_bram_dout),
    .job_bram_en(job_bram_en),
    .job_bram_addr(job_bram_addr),
    .job_bram_dout(job_bram_dout)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (message_bram_en) begin
      message_bram_dout <= message_mem[message_bram_addr];
    end
    if (job_bram_en) begin
      job_bram_dout <= job_mem[job_bram_addr];
    end
  end

  task automatic pulse_start;
    begin
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;
    end
  endtask

  task automatic run_case;
    input [7:0] dispatch_limit_word;
    input [7:0] expected_accepted;
    input [7:0] expected_index;
    input [31:0] expected_started;
    input [31:0] expected_completed;
    input [31:0] expected_dropped;
    begin
      dispatch_limit = dispatch_limit_word;
      last_cycles = 0;
      pulse_start();
      while (!done) begin
        @(posedge clk);
        last_cycles = last_cycles + 1;
      end
      if (!result_valid || error || error_code !== 8'd0) begin
        $display("CORE_RESULT_MISMATCH result_valid=%0d error=%0d error_code=%0d", result_valid, error, error_code);
        $fatal(1);
      end
      if (result_mask[0] !== 1'b1 || result_mask[1] !== 1'b0) begin
        $display("CORE_MASK_MISMATCH got=%064x", result_mask);
        $fatal(1);
      end
      if (accepted_job_count !== expected_accepted || current_job_index !== expected_index) begin
        $display("CORE_DISPATCH_MISMATCH accepted=%0d index=%0d", accepted_job_count, current_job_index);
        $fatal(1);
      end
      if (jobs_started !== expected_started || jobs_completed !== expected_completed || jobs_dropped !== expected_dropped) begin
        $display("CORE_COUNTER_MISMATCH started=%0d completed=%0d dropped=%0d", jobs_started, jobs_completed, jobs_dropped);
        $fatal(1);
      end
      if (last_job_cycles == 32'd0 || last_batch_cycles == 32'd0 || max_job_cycles < last_job_cycles) begin
        $display("CORE_PERF_MISMATCH last_job_cycles=%0d max_job_cycles=%0d last_batch_cycles=%0d",
                 last_job_cycles, max_job_cycles, last_batch_cycles);
        $fatal(1);
      end
      @(posedge clk);
    end
  endtask

  initial begin
    for (index = 0; index < 1024; index = index + 1) begin
      message_mem[index] = 32'd0;
    end
    for (index = 0; index < 8192; index = index + 1) begin
      job_mem[index] = 32'd0;
    end
{message_assigns}
{job_assigns}
    #20;
    rst_n = 1'b1;
    #20;

    run_case(8'd0, 8'd2, 8'd1, 32'd2, 32'd2, 32'd0);
    $display("BENCH case=full_batch mode={verify_mode_name} dispatch_limit=0 cycles=%0d result_mask=%064x accepted=%0d current=%0d started=%0d completed=%0d dropped=%0d last_job_cycles=%0d max_job_cycles=%0d last_batch_cycles=%0d",
             last_cycles, result_mask, accepted_job_count, current_job_index, jobs_started, jobs_completed, jobs_dropped,
             last_job_cycles, max_job_cycles, last_batch_cycles);

    run_case(8'd1, 8'd1, 8'd0, 32'd3, 32'd3, 32'd1);
    $display("BENCH case=dispatch_limit_1 mode={verify_mode_name} dispatch_limit=1 cycles=%0d result_mask=%064x accepted=%0d current=%0d started=%0d completed=%0d dropped=%0d last_job_cycles=%0d max_job_cycles=%0d last_batch_cycles=%0d",
             last_cycles, result_mask, accepted_job_count, current_job_index, jobs_started, jobs_completed, jobs_dropped,
             last_job_cycles, max_job_cycles, last_batch_cycles);

    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

    sources, optional_sources = resolve_rtl_sources(
        KV260_FPGA_DIR,
        KV260_CORE_SOURCES,
        extra_sources=extra_sources,
    )
    stdout = _run_verilator(KV260_FPGA_DIR, "tb_fixed_base_kv260_bench.v", tb_source, sources)
    parsed = _parse_bench_lines(stdout, KV260_BENCH_RE)
    results: list[dict[str, object]] = []
    for result in parsed:
        mask_hex = result["result_mask"].lower()
        mask_value = int(mask_hex, 16)
        results.append(
            {
                "target": "kv260_core",
                "case": result["case"],
                "verify_mode": result["mode"],
                "dispatch_limit": int(result["dispatch_limit"]),
                "cycles": int(result["cycles"]),
                "result_mask_hex": mask_hex,
                "result_bits": _result_mask_bits(mask_value, int(result["accepted_job_count"])),
                "accepted_job_count": int(result["accepted_job_count"]),
                "current_job_index": int(result["current_job_index"]),
                "jobs_started": int(result["jobs_started"]),
                "jobs_completed": int(result["jobs_completed"]),
                "jobs_dropped": int(result["jobs_dropped"]),
                "last_job_cycles": int(result["last_job_cycles"]),
                "max_job_cycles": int(result["max_job_cycles"]),
                "last_batch_cycles": int(result["last_batch_cycles"]),
                "fixed_base_rtl_sources": optional_sources,
            }
        )
    return results


def _add_common_source_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument(
        "--extra-source",
        action="append",
        default=[],
        help="additional RTL helper file to compile alongside auto-discovered fixed-base sources",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="target", required=True)

    verify_parser = subparsers.add_parser("verify-engine", help="benchmark ed25519_verify_engine")
    verify_parser.add_argument("--case", action="append", choices=["valid", "invalid"], default=None)
    verify_parser.add_argument(
        "--verify-mode",
        action="append",
        choices=["strict", "agave", "agave_zebra"],
        default=None,
    )
    _add_common_source_args(verify_parser)

    kv260_parser = subparsers.add_parser("kv260-core", help="benchmark sigv_kv260_core")
    kv260_parser.add_argument("--verify-mode", choices=["strict", "agave", "agave_zebra"], default="strict")
    _add_common_source_args(kv260_parser)

    return parser


def _defaulted(values: Sequence[str] | None, defaults: Sequence[str]) -> list[str]:
    if values is None or len(values) == 0:
        return list(defaults)
    return list(values)


def main(argv: Sequence[str] | None = None) -> None:
    parser = build_parser()
    args = parser.parse_args(argv)

    if args.target == "verify-engine":
        payload = {
            "benchmarks": run_verify_engine_benchmarks(
                case_names=_defaulted(args.case, ("valid", "invalid")),
                verify_mode_names=_defaulted(args.verify_mode, ("strict", "agave_zebra")),
                extra_sources=args.extra_source,
            )
        }
    elif args.target == "kv260-core":
        payload = {
            "benchmarks": run_kv260_core_benchmarks(
                verify_mode_name=args.verify_mode,
                extra_sources=args.extra_source,
            )
        }
    else:
        raise SystemExit(f"unsupported target: {args.target}")

    print(json.dumps(payload, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
