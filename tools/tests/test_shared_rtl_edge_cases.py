from __future__ import annotations

import hashlib
import os
import random
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = Path(__file__).resolve().parents[2]
RTL_DIR = REPO_ROOT / "fpga" / "rtl"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from verilator_cache import build_verilator_cache_key

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
BASEPOINT_ENCODED = bytes.fromhex("5866666666666666666666666666666666666666666666666666666666666666")
SMALL_ORDER_IDENTITY = bytes.fromhex("0100000000000000000000000000000000000000000000000000000000000000")
ED25519_SCALAR_L = 2**252 + 27742317777372353535851937790883648493


def _little_endian_hex(blob: bytes) -> str:
    return blob[::-1].hex()


def _pack_word_lines(mem_name: str, blob: bytes) -> str:
    lines: list[str] = []
    for word_index in range((len(blob) + 3) // 4):
        chunk = blob[word_index * 4 : (word_index + 1) * 4]
        word = int.from_bytes(chunk.ljust(4, b"\x00"), "little")
        lines.append(f"    {mem_name}[{word_index}] = 32'h{word:08x};")
    return "\n".join(lines)


def _sha512_stream_engine_cases() -> list[dict[str, bytes]]:
    rng = random.Random(0x5A512)
    lengths = []
    for length in [0, 1, 31, 32, 47, 48, 63, 64, 65, 111, 127, 128, 175, 176, 191, 255]:
        if length not in lengths:
            lengths.append(length)
    while len(lengths) < 24:
        candidate = rng.randrange(0, 256)
        if candidate not in lengths:
            lengths.append(candidate)

    cases: list[dict[str, bytes]] = []
    for length in lengths:
        prefix0 = bytes(rng.getrandbits(8) for _ in range(32))
        prefix1 = bytes(rng.getrandbits(8) for _ in range(32))
        message = bytes(rng.getrandbits(8) for _ in range(length))
        digest = hashlib.sha512(prefix0 + prefix1 + message).digest()
        cases.append(
            {
                "prefix0": prefix0,
                "prefix1": prefix1,
                "message": message,
                "digest": digest,
            }
        )
    return cases


def _wnaf4_packed(scalar: int) -> int:
    work = scalar
    packed = 0
    digit_map = {
        1: (0x1, 1),
        3: (0x3, 3),
        5: (0x5, 5),
        7: (0x7, 7),
        9: (0x9, 7),
        11: (0xB, 5),
        13: (0xD, 3),
        15: (0xF, 1),
    }
    for bit_index in range(256):
        digit, abs_value = 0, 0
        if work & 1:
            digit, abs_value = digit_map[work & 0xF]
            if digit & 0x8:
                work += abs_value
            else:
                work -= abs_value
        packed |= digit << (bit_index * 4)
        work >>= 1
    return packed


def _run_verilator(tb_name: str, tb_source: str, sources: list[str]) -> str:
    if shutil.which("verilator") is None:
        raise unittest.SkipTest("verilator is not installed")

    abs_sources = [RTL_DIR / s for s in sources]
    include_dirs = [RTL_DIR]
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
                *sources,
            ],
            cwd=RTL_DIR,
            check=True,
            stdout=subprocess.DEVNULL,
        )
        built = build_dir / "Vtb"
        if built.exists() and not cached_binary.exists():
            shutil.copy2(str(built), str(cached_binary))

    completed = subprocess.run(
        [str(cached_binary)],
        cwd=RTL_DIR,
        check=False,
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            "verilator bench failed\n"
            f"stdout:\n{completed.stdout}\n"
            f"stderr:\n{completed.stderr}"
        )
    return completed.stdout


@unittest.skipUnless(shutil.which("verilator"), "verilator is not installed")
class SharedRtlEdgeCaseTests(unittest.TestCase):
    def test_scalar_wnaf4_recode_matches_reference_vectors(self) -> None:
        rng = random.Random(0x4A6F696E74)
        scalars = [
            0,
            1,
            2,
            (1 << 255) - 1,
            (1 << 255),
            (1 << 256) - 1,
            *[rng.getrandbits(256) for _ in range(8)],
        ]
        scalar_assigns = "\n".join(
            f"    scalar_mem[{index}] = 256'h{scalar:064x};\n"
            f"    expected_mem[{index}] = 1024'h{_wnaf4_packed(scalar):0256x};"
            for index, scalar in enumerate(scalars)
        )
        tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg [255:0] scalar_in = 256'd0;
  wire done;
  wire digit_valid;
  wire [7:0] digit_index;
  wire [3:0] digit;
  reg [1023:0] packed_digits = 1024'd0;
  reg [255:0] scalar_mem [0:{len(scalars) - 1}];
  reg [1023:0] expected_mem [0:{len(scalars) - 1}];
  integer case_index;
  integer cycles;

  scalar_wnaf4_recode dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .scalar_in(scalar_in),
    .busy(),
    .done(done),
    .digit_valid(digit_valid),
    .digit_index(digit_index),
    .digit(digit)
  );

  always #5 clk = ~clk;

  initial begin
{scalar_assigns}
    #20;
    rst_n = 1'b1;
    #20;

    for (case_index = 0; case_index < {len(scalars)}; case_index = case_index + 1) begin
      scalar_in = scalar_mem[case_index];
      packed_digits = 1024'd0;
      @(posedge clk);
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;
      cycles = 0;
      while (!done) begin
        @(posedge clk);
        if (digit_valid) begin
          packed_digits[{{digit_index, 2'b00}} +: 4] = digit;
        end
        cycles = cycles + 1;
        if (cycles > 260) begin
          $display("recode timed out at case %0d", case_index);
          $fatal(1);
        end
      end
      if (digit_valid) begin
        packed_digits[{{digit_index, 2'b00}} +: 4] = digit;
      end
      if (packed_digits !== expected_mem[case_index]) begin
        $display("wnaf mismatch at case %0d", case_index);
        $fatal(1);
      end
      @(posedge clk);
    end
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_scalar_wnaf4_recode.v",
            tb_source,
            [
                "scalar_wnaf4_recode.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_scalar_reduce_mod_l_matches_little_endian_modulo_reference(self) -> None:
        rng = random.Random(0x51CA1A)
        def wide_from_little_endian_int(value: int) -> int:
            return int.from_bytes(value.to_bytes(64, "little"), "big")

        wide_values = [
            0,
            wide_from_little_endian_int(1),
            wide_from_little_endian_int(ED25519_SCALAR_L - 1),
            wide_from_little_endian_int(ED25519_SCALAR_L),
            wide_from_little_endian_int(ED25519_SCALAR_L + 1),
            (1 << 512) - 1,
            *[rng.getrandbits(512) for _ in range(8)],
        ]
        assigns = "\n".join(
            f"    wide_mem[{index}] = 512'h{wide:0128x};\n"
            f"    expected_mem[{index}] = 256'h{(int.from_bytes(wide.to_bytes(64, 'big'), 'little') % ED25519_SCALAR_L):064x};"
            for index, wide in enumerate(wide_values)
        )
        tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg [511:0] wide_in = 512'd0;
  wire done;
  wire [255:0] scalar_out;
  reg [511:0] wide_mem [0:{len(wide_values) - 1}];
  reg [255:0] expected_mem [0:{len(wide_values) - 1}];
  integer case_index;
  integer cycles;

  scalar_reduce_mod_l dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .wide_in(wide_in),
    .busy(),
    .done(done),
    .scalar_out(scalar_out)
  );

  always #5 clk = ~clk;

  initial begin
{assigns}
    #20;
    rst_n = 1'b1;
    #20;

    for (case_index = 0; case_index < {len(wide_values)}; case_index = case_index + 1) begin
      wide_in = wide_mem[case_index];
      @(posedge clk);
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;
      cycles = 0;
      while (!done) begin
        @(posedge clk);
        cycles = cycles + 1;
        if (cycles > 520) begin
          $display("reduce timed out at case %0d", case_index);
          $fatal(1);
        end
      end
      if (scalar_out !== expected_mem[case_index]) begin
        $display("reduce mismatch at case %0d got=%064x expected=%064x",
                 case_index, scalar_out, expected_mem[case_index]);
        $fatal(1);
      end
      @(posedge clk);
    end
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_scalar_reduce_mod_l.v",
            tb_source,
            [
                "scalar_reduce_mod_l.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_sha512_stream_engine_rejects_oversized_messages(self) -> None:
        tb_source = """`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  wire msg_rd_en;
  wire [3:0] msg_rd_addr;
  reg [31:0] msg_rd_data = 32'h00;
  wire busy;
  wire done;
  wire error;
  wire [511:0] digest_out;

  sha512_stream_engine #(.MESSAGE_ADDR_WIDTH(4)) dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .prefix0(256'd0),
    .prefix1(256'd0),
    .message_length(16'd17),
    .msg_rd_en(msg_rd_en),
    .msg_rd_addr(msg_rd_addr),
    .msg_rd_ready(1'b1),
    .msg_rd_data(msg_rd_data),
    .busy(busy),
    .done(done),
    .error(error),
    .digest_out(digest_out)
  );

  always #5 clk = ~clk;

  initial begin
    #20;
    rst_n = 1'b1;
    #20;
    @(posedge clk);
    start <= 1'b1;
    @(posedge clk);
    start <= 1'b0;
    wait (done);
    if (!error || busy) begin
      $display("expected oversize message rejection");
      $fatal(1);
    end
    if (msg_rd_en) begin
      $display("oversize rejection should not issue a BRAM read");
      $fatal(1);
    end
    if (digest_out !== 512'd0) begin
      $display("oversize rejection should zero the digest");
      $fatal(1);
    end
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_sha512_stream_engine_guard.v",
            tb_source,
            [
                "sha512_compress_core.v",
                "sha512_stream_engine.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_sha512_stream_engine_matches_hashlib_on_boundary_and_random_vectors(self) -> None:
        cases = _sha512_stream_engine_cases()
        max_message_len = max(len(case["message"]) for case in cases)
        prefix_assigns = "\n".join(
            f"    prefix0_mem[{case_index}] = 256'h{_little_endian_hex(case['prefix0'])};\n"
            f"    prefix1_mem[{case_index}] = 256'h{_little_endian_hex(case['prefix1'])};\n"
            f"    message_length_mem[{case_index}] = 16'd{len(case['message'])};\n"
            f"    expected_digest_mem[{case_index}] = 512'h{case['digest'].hex()};"
            for case_index, case in enumerate(cases)
        )
        max_message_words = (max_message_len + 3) // 4
        message_assign_parts: list[str] = []
        for case_index, case in enumerate(cases):
            msg = case["message"]
            for word_index in range((len(msg) + 3) // 4):
                chunk = msg[word_index * 4 : (word_index + 1) * 4]
                word = int.from_bytes(chunk.ljust(4, b"\x00"), "little")
                message_assign_parts.append(
                    f"    message_mem[{case_index * max_message_words + word_index}] = 32'h{word:08x};"
                )
        message_assigns = "\n".join(message_assign_parts)
        tb_source = f"""`timescale 1ns/1ps
module tb;
  localparam integer CASE_COUNT = {len(cases)};
  localparam integer MAX_MESSAGE_BYTES = {max_message_len};
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg [255:0] prefix0 = 256'd0;
  reg [255:0] prefix1 = 256'd0;
  reg [15:0] message_length = 16'd0;
  wire msg_rd_en;
  wire [8:0] msg_rd_addr;
  reg [31:0] msg_rd_data = 32'd0;
  wire busy;
  wire done;
  wire error;
  wire [511:0] digest_out;
  reg [255:0] prefix0_mem [0:CASE_COUNT-1];
  reg [255:0] prefix1_mem [0:CASE_COUNT-1];
  reg [15:0] message_length_mem [0:CASE_COUNT-1];
  reg [511:0] expected_digest_mem [0:CASE_COUNT-1];
  reg [31:0] message_mem [0:((CASE_COUNT * MAX_MESSAGE_BYTES + 3) / 4) - 1];
  integer case_index;
  integer word_index;
  integer current_message_word_base;
  integer wait_cycles;

  sha512_stream_engine #(.MESSAGE_ADDR_WIDTH(9)) dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .prefix0(prefix0),
    .prefix1(prefix1),
    .message_length(message_length),
    .msg_rd_en(msg_rd_en),
    .msg_rd_addr(msg_rd_addr),
    .msg_rd_ready(1'b1),
    .msg_rd_data(msg_rd_data),
    .busy(busy),
    .done(done),
    .error(error),
    .digest_out(digest_out)
  );

  always #5 clk = ~clk;

  always @(posedge clk) begin
    if (msg_rd_en) begin
      msg_rd_data <= message_mem[current_message_word_base + msg_rd_addr[8:2]];
    end
  end

  task automatic run_case;
    input integer case_id;
    begin
      prefix0 = prefix0_mem[case_id];
      prefix1 = prefix1_mem[case_id];
      message_length = message_length_mem[case_id];
      current_message_word_base = case_id * ((MAX_MESSAGE_BYTES + 3) / 4);
      @(posedge clk);
      start = 1'b1;
      @(posedge clk);
      start = 1'b0;
      wait_cycles = 0;
      while (!done) begin
        @(posedge clk);
        wait_cycles = wait_cycles + 1;
        if (wait_cycles > 20000) begin
          $display("sha512 stream engine timed out on case=%0d len=%0d", case_id, message_length_mem[case_id]);
          $fatal(1);
        end
      end
      if (error || busy) begin
        $display("sha512 stream engine signalled error on case=%0d len=%0d", case_id, message_length_mem[case_id]);
        $fatal(1);
      end
      if (digest_out !== expected_digest_mem[case_id]) begin
        $display("sha512 digest mismatch case=%0d len=%0d", case_id, message_length_mem[case_id]);
        $display("got      %0128x", digest_out);
        $display("expected %0128x", expected_digest_mem[case_id]);
        $fatal(1);
      end
      @(posedge clk);
    end
  endtask

  initial begin
    for (case_index = 0; case_index < CASE_COUNT; case_index = case_index + 1) begin
      prefix0_mem[case_index] = 256'd0;
      prefix1_mem[case_index] = 256'd0;
      message_length_mem[case_index] = 16'd0;
      expected_digest_mem[case_index] = 512'd0;
    end
    for (word_index = 0; word_index < ((CASE_COUNT * MAX_MESSAGE_BYTES + 3) / 4); word_index = word_index + 1) begin
      message_mem[word_index] = 32'd0;
    end
{prefix_assigns}
{message_assigns}
    #20;
    rst_n = 1'b1;
    #20;
    for (case_index = 0; case_index < CASE_COUNT; case_index = case_index + 1) begin
      run_case(case_index);
    end
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_sha512_stream_engine_oracle.v",
            tb_source,
            [
                "sha512_compress_core.v",
                "sha512_stream_engine.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_point_double_and_point_add_agree_on_affine_result(self) -> None:
        tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg [1:0] op = 2'd0;
  reg [255:0] encoded_point = 256'h{_little_endian_hex(BASEPOINT_ENCODED)};
  reg [254:0] point_a_x = 255'd0;
  reg [254:0] point_a_y = 255'd1;
  reg [254:0] point_a_z = 255'd1;
  reg [254:0] point_a_t = 255'd0;
  reg [254:0] point_b_x = 255'd0;
  reg [254:0] point_b_y = 255'd1;
  reg [254:0] point_b_z = 255'd1;
  reg [254:0] point_b_t = 255'd0;
  wire done;
  wire flag;
  wire [254:0] out_x;
  wire [254:0] out_y;
  wire [254:0] out_z;
  wire [254:0] out_t;
  reg [254:0] base_x;
  reg [254:0] base_y;
  reg [254:0] base_z;
  reg [254:0] base_t;
  reg [254:0] dbl_x;
  reg [254:0] dbl_y;
  reg [254:0] dbl_z;
  reg [254:0] dbl_t;

  function [254:0] neg_mod_p;
    input [254:0] value;
    begin
      if (value == 255'd0) begin
        neg_mod_p = 255'd0;
      end else begin
        neg_mod_p = 255'h7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffed - value;
      end
    end
  endfunction

  ed25519_point_core dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .op(op),
    .encoded_point(encoded_point),
    .point_a_x(point_a_x),
    .point_a_y(point_a_y),
    .point_a_z(point_a_z),
    .point_a_t(point_a_t),
    .point_b_x(point_b_x),
    .point_b_y(point_b_y),
    .point_b_z(point_b_z),
    .point_b_t(point_b_t),
    .busy(),
    .done(done),
    .flag(flag),
    .out_x(out_x),
    .out_y(out_y),
    .out_z(out_z),
    .out_t(out_t)
  );

  always #5 clk = ~clk;

  task automatic pulse_start;
    begin
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;
      wait (done);
      if (!flag) begin
        $display("point op failed for op=%0d", op);
        $fatal(1);
      end
      @(posedge clk);
    end
  endtask

  initial begin
    #20;
    rst_n = 1'b1;
    #20;

    op = 2'd0;
    pulse_start();
    base_x = out_x;
    base_y = out_y;
    base_z = out_z;
    base_t = out_t;

    op = 2'd2;
    point_a_x = base_x;
    point_a_y = base_y;
    point_a_z = base_z;
    point_a_t = base_t;
    point_b_x = base_x;
    point_b_y = base_y;
    point_b_z = base_z;
    point_b_t = base_t;
    pulse_start();
    dbl_x = out_x;
    dbl_y = out_y;
    dbl_z = out_z;
    dbl_t = out_t;

    op = 2'd1;
    point_a_x = base_x;
    point_a_y = base_y;
    point_a_z = base_z;
    point_a_t = base_t;
    point_b_x = base_x;
    point_b_y = base_y;
    point_b_z = base_z;
    point_b_t = base_t;
    pulse_start();

    op = 2'd1;
    point_a_x = dbl_x;
    point_a_y = dbl_y;
    point_a_z = dbl_z;
    point_a_t = dbl_t;
    point_b_x = neg_mod_p(out_x);
    point_b_y = out_y;
    point_b_z = out_z;
    point_b_t = neg_mod_p(out_t);
    pulse_start();

    if ((out_x !== 255'd0) || (out_t !== 255'd0) || (out_y !== out_z)) begin
      $display("double and add should agree up to projective scaling");
      $fatal(1);
    end
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_point_double_equivalence.v",
            tb_source,
            [
                "fe25519_aux_core.v",
                "fe25519_mul_core.v",
                "fe25519_mul_wide_core.v",
                "ed25519_point_core.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_verify_engine_strict_mode_rejects_small_order_pubkey(self) -> None:
        message_assigns = _pack_word_lines("mem", MESSAGE)
        tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg [15:0] message_length = 16'd{len(MESSAGE)};
  reg [255:0] pubkey_raw = 256'h{_little_endian_hex(SMALL_ORDER_IDENTITY)};
  reg [255:0] signature_r_raw = 256'h{_little_endian_hex(SIGNATURE[:32])};
  reg [255:0] signature_s_raw = 256'h{_little_endian_hex(SIGNATURE[32:])};
  reg [1:0] verify_mode = 2'd0;
  wire msg_rd_en;
  wire [10:0] msg_rd_addr;
  reg [31:0] msg_rd_data = 32'd0;
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
  integer strict_cycles = 0;
  integer index;

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
    .busy(),
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
    output integer cycles_out;
    begin
      verify_mode = 2'd0;
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;
      cycles_out = 0;
      while (!done) begin
        @(posedge clk);
        cycles_out = cycles_out + 1;
        if (cycles_out > 256) begin
          $display("verify engine timed out");
          $fatal(1);
        end
      end
      if (verified !== 1'b0) begin
        $display("expected strict mode to reject the small-order pubkey");
        $fatal(1);
      end
      @(posedge clk);
    end
  endtask

  initial begin
    for (index = 0; index < {(len(MESSAGE) + 3) // 4}; index = index + 1) begin
      mem[index] = 32'd0;
    end
{message_assigns}
    #20;
    rst_n = 1'b1;
    #20;

    run_case(strict_cycles);
    if (strict_cycles > 8) begin
      $display("strict mode should reject the small-order pubkey quickly");
      $fatal(1);
    end
    if (perf_total_cycles !== strict_cycles || perf_control_cycles !== strict_cycles) begin
      $display("unexpected early-reject perf counters total=%0d control=%0d strict_cycles=%0d",
               perf_total_cycles, perf_control_cycles, strict_cycles);
      $fatal(1);
    end
    if (perf_decode_cycles !== 32'd0 || perf_hash_cycles !== 32'd0 || perf_reduce_cycles !== 32'd0 ||
        perf_precompute_cycles !== 32'd0 || perf_joint_cycles !== 32'd0 || perf_finalize_cycles !== 32'd0) begin
      $display("unexpected early-reject phase counters decode=%0d hash=%0d reduce=%0d precompute=%0d joint=%0d finalize=%0d",
               perf_decode_cycles, perf_hash_cycles, perf_reduce_cycles, perf_precompute_cycles,
               perf_joint_cycles, perf_finalize_cycles);
      $fatal(1);
    end
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_verify_engine_small_order_modes.v",
            tb_source,
            [
                "fe25519_aux_core.v",
                "fe25519_mul_core.v",
                "fe25519_mul_wide_core.v",
                "sha512_compress_core.v",
                "sha512_stream_engine.v",
                "scalar_reduce_mod_l.v",
                "scalar_wnaf4_recode.v",
                "ed25519_point_core.v",
                "ed25519_basepoint_table.v",
                "ed25519_verify_engine.v",
            ],
        )
        self.assertIn("PASS", stdout)


if __name__ == "__main__":
    unittest.main()
