from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = TOOLS_DIR.parent
FPGA_DIR = REPO_ROOT / "fpga" / "kv260_sigv"

if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from verilator_cache import build_verilator_cache_key


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
STRICT_VERIFY_MODE = 0


def _pack_word_lines(mem_name: str, blob: bytes) -> str:
    lines: list[str] = []
    for word_index in range((len(blob) + 3) // 4):
        chunk = blob[word_index * 4 : (word_index + 1) * 4]
        word = int.from_bytes(chunk.ljust(4, b"\x00"), "little")
        lines.append(f"    {mem_name}[{word_index}] = 32'h{word:08x};")
    return "\n".join(lines)


def _run_verilator(tb_name: str, tb_source: str, extra_sources: list[str]) -> str:
    if shutil.which("verilator") is None:
        raise unittest.SkipTest("verilator is not installed")

    abs_sources = [FPGA_DIR / s for s in extra_sources]
    include_dirs = [FPGA_DIR / "src", FPGA_DIR.parent / "rtl"]
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
            *extra_sources,
        ]
        compile_run = subprocess.run(command, cwd=FPGA_DIR, capture_output=True, text=True, check=False)
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

    run = subprocess.run(
        [str(cached_binary)],
        capture_output=True,
        text=True,
        check=False,
    )
    if run.returncode != 0:
        raise RuntimeError(
            "verilator bench failed\n"
            f"stdout:\n{run.stdout}\n"
            f"stderr:\n{run.stderr}"
        )
    return run.stdout


class Kv260SigvRtlTests(unittest.TestCase):
    def test_kv260_clock_metadata_uses_single_ps_pl_clock_domain(self) -> None:
        project_script = (FPGA_DIR / "tcl" / "create_project.tcl").read_text(encoding="utf-8")
        xdc = (FPGA_DIR / "xdc" / "kv260_sigv.xdc").read_text(encoding="utf-8")
        top = (FPGA_DIR / "src" / "kv260_sigv_top.v").read_text(encoding="utf-8")

        freq_mhz_match = re.search(r"PL0_REF_CTRL__FREQMHZ \{(\d+)\}", project_script)
        interface_freqs = re.findall(r"FREQ_HZ (\d+)", top)

        self.assertIsNotNone(freq_mhz_match)
        self.assertEqual(int(freq_mhz_match.group(1)), 100)
        self.assertNotIn("CLKOUT1_REQUESTED_OUT_FREQ", project_script)
        self.assertIn("maxihpm0_fpd_aclk", project_script)
        self.assertNotIn("maxihpm1_fpd_aclk", project_script)
        self.assertIn("create_bd_cell -type ip -vlnv $smartconnect_ip axi_smc", project_script)
        self.assertIn("create_bd_cell -type ip -vlnv $proc_sys_reset_ip rst_pl", project_script)
        self.assertIn("CONFIG.SINGLE_PORT_BRAM {1}", project_script)
        self.assertNotIn("bd_rule:axi4", project_script)
        self.assertNotIn("create_clock", xdc)
        self.assertEqual(interface_freqs, ["99999001", "99999001", "99999001", "99999001"])
        self.assertIn("reg  [23:0] bringup_irq_counter;", top)
        self.assertIn("bringup_irq_counter <= bringup_irq_counter + 24'd1;", top)
        self.assertIn("assign irq = (BRINGUP_MODE != 0) ? bringup_irq_counter[23] : axi_irq;", top)

    def test_bitstream_export_requires_timing_closure(self) -> None:
        build_script = (FPGA_DIR / "tcl" / "build_bitstream.tcl").read_text(encoding="utf-8")

        self.assertIn("get_timing_paths -setup", build_script)
        self.assertIn("get_timing_paths -hold", build_script)
        self.assertIn("failed timing closure", build_script)
        self.assertLess(build_script.index("report_timing_summary"), build_script.index("write_hw_platform"))
        self.assertLess(build_script.index("failed timing closure"), build_script.index("write_hw_platform"))

    def test_axi_register_block_locks_config_and_exposes_irq_snapshot_state(self) -> None:
        result_mask = bytes.fromhex(
            "efcdab8967452301"
            "1032547698badcfe"
            "0f1e2d3c4b5a6978"
            "8877665544332211"
        )
        result_words = [int.from_bytes(result_mask[index : index + 4], "little") for index in range(0, 32, 4)]

        tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg [7:0] awaddr = 8'h00;
  reg awvalid = 1'b0;
  wire awready;
  reg [31:0] wdata = 32'd0;
  reg [3:0] wstrb = 4'hF;
  reg wvalid = 1'b0;
  wire wready;
  wire [1:0] bresp;
  wire bvalid;
  reg bready = 1'b0;
  reg [7:0] araddr = 8'h00;
  reg arvalid = 1'b0;
  wire arready;
  wire [31:0] rdata;
  wire [1:0] rresp;
  wire rvalid;
  reg rready = 1'b0;

  wire start_pulse;
  wire soft_reset_pulse;
  wire [15:0] message_length;
  wire [31:0] requested_job_count;
  wire [1:0] verify_mode;
  wire [7:0] dispatch_limit;
  wire [31:0] led_control;
  wire [31:0] job_timeout_cycles;
  wire irq;
  reg autonomous_irq = 1'b0;

  reg busy = 1'b0;
  reg done = 1'b0;
  reg error = 1'b0;
  reg result_valid = 1'b0;
  reg [7:0] error_code = 8'hA5;
  reg [255:0] result_mask = 256'h{result_mask[::-1].hex()};
  reg [7:0] accepted_job_count = 8'h12;
  reg [7:0] current_job_index = 8'h34;
  reg [31:0] jobs_started = 32'h01020304;
  reg [31:0] jobs_completed = 32'h11121314;
  reg [31:0] jobs_dropped = 32'h21222324;
  reg [31:0] active_cycles = 32'h31323334;
  reg [31:0] last_job_cycles = 32'h41424344;
  reg [31:0] max_job_cycles = 32'h51525354;
  reg [31:0] last_batch_cycles = 32'h61626364;
  reg [31:0] batch_id = 32'h00000037;
  reg [31:0] snapshot_batch_id = 32'h00000036;
  reg [7:0] snapshot_accepted_job_count = 8'h09;
  reg [31:0] snapshot_jobs_completed = 32'h71727374;
  reg [31:0] snapshot_jobs_dropped = 32'h81828384;
  reg snapshot_error = 1'b1;
  reg snapshot_result_valid = 1'b1;
  reg [7:0] snapshot_error_code = 8'h3C;
  reg saw_start_pulse = 1'b0;
  reg saw_soft_reset_pulse = 1'b0;

  sigv_axi_regs dut(
    .clk(clk),
    .rst_n(rst_n),
    .s_axi_awaddr(awaddr),
    .s_axi_awvalid(awvalid),
    .s_axi_awready(awready),
    .s_axi_wdata(wdata),
    .s_axi_wstrb(wstrb),
    .s_axi_wvalid(wvalid),
    .s_axi_wready(wready),
    .s_axi_bresp(bresp),
    .s_axi_bvalid(bvalid),
    .s_axi_bready(bready),
    .s_axi_araddr(araddr),
    .s_axi_arvalid(arvalid),
    .s_axi_arready(arready),
    .s_axi_rdata(rdata),
    .s_axi_rresp(rresp),
    .s_axi_rvalid(rvalid),
    .s_axi_rready(rready),
    .start_pulse(start_pulse),
    .soft_reset_pulse(soft_reset_pulse),
    .message_length(message_length),
    .requested_job_count(requested_job_count),
    .verify_mode(verify_mode),
    .dispatch_limit(dispatch_limit),
    .led_control(led_control),
    .job_timeout_cycles(job_timeout_cycles),
    .autonomous_irq(autonomous_irq),
    .irq(irq),
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
    .snapshot_error_code(snapshot_error_code)
  );

  always #5 clk = ~clk;

  always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      saw_start_pulse <= 1'b0;
      saw_soft_reset_pulse <= 1'b0;
    end else begin
      if (start_pulse) begin
        saw_start_pulse <= 1'b1;
      end
      if (soft_reset_pulse) begin
        saw_soft_reset_pulse <= 1'b1;
      end
    end
  end

  task automatic axi_write;
    input [7:0] addr;
    input [31:0] value;
    begin
      @(posedge clk);
      awaddr <= addr;
      awvalid <= 1'b1;
      wdata <= value;
      wvalid <= 1'b1;
      wait (awready && wready);
      @(posedge clk);
      awvalid <= 1'b0;
      wvalid <= 1'b0;
      bready <= 1'b1;
      wait (bvalid);
      @(posedge clk);
      bready <= 1'b0;
    end
  endtask

  task automatic axi_read_expect;
    input [7:0] addr;
    input [31:0] expected;
    begin
      @(posedge clk);
      araddr <= addr;
      arvalid <= 1'b1;
      rready <= 1'b1;
      wait (arready);
      @(posedge clk);
      arvalid <= 1'b0;
      wait (rvalid);
      if (rdata !== expected) begin
        $display("AXI_READ_MISMATCH addr=%02h got=%08x expected=%08x", addr, rdata, expected);
        $fatal(1);
      end
      @(posedge clk);
      rready <= 1'b0;
    end
  endtask

  initial begin
    #20;
    rst_n = 1'b1;
    #20;

    axi_write(8'h08, 32'h00000123);
    axi_write(8'h0C, 32'h00000123);
    axi_write(8'h34, 32'h0000000B);
    axi_write(8'h38, 32'h00000501);
    axi_write(8'h5C, 32'h000001F4);
    axi_write(8'h60, 32'h00000001);

    if (message_length !== 16'h0123 || requested_job_count !== 32'h00000123 ||
        led_control !== 32'h0000000B || verify_mode !== 2'd1 ||
        dispatch_limit !== 8'h05 || job_timeout_cycles !== 32'h000001F4) begin
      $display("idle-time configuration writes did not stick");
      $fatal(1);
    end

    busy = 1'b1;
    axi_write(8'h08, 32'h00000456);
    axi_write(8'h0C, 32'h00000456);
    axi_write(8'h38, 32'h00000900);
    axi_write(8'h5C, 32'h00000010);

    if (message_length !== 16'h0123 || requested_job_count !== 32'h00000123 ||
        verify_mode !== 2'd1 || dispatch_limit !== 8'h05 ||
        job_timeout_cycles !== 32'h000001F4) begin
      $display("busy-time configuration write should have been ignored");
      $fatal(1);
    end

    done = 1'b1;
    error = 1'b1;
    result_valid = 1'b1;
    @(posedge clk);

    if (!irq) begin
      $display("completion should raise the IRQ output when enabled");
      $fatal(1);
    end

    axi_read_expect(8'h04, 32'h0000007F);
    axi_read_expect(8'h08, 32'h00000123);
    axi_read_expect(8'h0C, 32'h00000123);
    axi_read_expect(8'h10, 32'h{result_words[0]:08x});
    axi_read_expect(8'h14, 32'h{result_words[1]:08x});
    axi_read_expect(8'h18, 32'h{result_words[2]:08x});
    axi_read_expect(8'h1C, 32'h{result_words[3]:08x});
    axi_read_expect(8'h20, 32'h{result_words[4]:08x});
    axi_read_expect(8'h24, 32'h{result_words[5]:08x});
    axi_read_expect(8'h28, 32'h{result_words[6]:08x});
    axi_read_expect(8'h2C, 32'h{result_words[7]:08x});
    axi_read_expect(8'h30, 32'h000000A5);
    axi_read_expect(8'h34, 32'h0000000B);
    axi_read_expect(8'h38, 32'h00000501);
    axi_read_expect(8'h3C, 32'h00013412);
    axi_read_expect(8'h40, 32'h01020304);
    axi_read_expect(8'h44, 32'h11121314);
    axi_read_expect(8'h48, 32'h21222324);
    axi_read_expect(8'h4C, 32'h31323334);
    axi_read_expect(8'h50, 32'h41424344);
    axi_read_expect(8'h54, 32'h51525354);
    axi_read_expect(8'h58, 32'h61626364);
    axi_read_expect(8'h5C, 32'h000001F4);
    axi_read_expect(8'h60, 32'h00000003);
    axi_read_expect(8'h64, 32'h00000037);
    axi_read_expect(8'h68, 32'h00000036);
    axi_read_expect(8'h6C, 32'h00000009);
    axi_read_expect(8'h70, 32'h71727374);
    axi_read_expect(8'h74, 32'h81828384);
    axi_read_expect(8'h78, 32'h0000033C);
    axi_read_expect(8'h7C, 32'h53494756);
    axi_read_expect(8'h80, 32'h00000100);

    axi_write(8'h60, 32'h00000003);
    if (irq) begin
      $display("IRQ acknowledge should drop the IRQ output");
      $fatal(1);
    end
    axi_read_expect(8'h60, 32'h00000001);

    busy = 1'b0;
    axi_write(8'h00, 32'h00000003);
    if (!saw_start_pulse || !saw_soft_reset_pulse) begin
      $display("expected control write to pulse start and soft reset");
      $fatal(1);
    end
    if (start_pulse || soft_reset_pulse) begin
      $display("control pulses should clear after one cycle");
      $fatal(1);
    end
    axi_read_expect(8'h04, 32'h0000001E);

    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_kv260_axi_regs.v",
            tb_source,
            [
                "src/sigv_axi_regs.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_axi_register_block_can_forward_autonomous_irq_without_mmio_enable(self) -> None:
        tb_source = """`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg autonomous_irq = 1'b0;
  wire irq;

  sigv_axi_regs #(
    .AUTO_IRQ_ENABLE(1)
  ) dut(
    .clk(clk),
    .rst_n(rst_n),
    .s_axi_awaddr(8'd0),
    .s_axi_awvalid(1'b0),
    .s_axi_awready(),
    .s_axi_wdata(32'd0),
    .s_axi_wstrb(4'd0),
    .s_axi_wvalid(1'b0),
    .s_axi_wready(),
    .s_axi_bresp(),
    .s_axi_bvalid(),
    .s_axi_bready(1'b0),
    .s_axi_araddr(8'd0),
    .s_axi_arvalid(1'b0),
    .s_axi_arready(),
    .s_axi_rdata(),
    .s_axi_rresp(),
    .s_axi_rvalid(),
    .s_axi_rready(1'b0),
    .start_pulse(),
    .soft_reset_pulse(),
    .message_length(),
    .requested_job_count(),
    .verify_mode(),
    .dispatch_limit(),
    .led_control(),
    .job_timeout_cycles(),
    .autonomous_irq(autonomous_irq),
    .irq(irq),
    .busy(1'b0),
    .done(1'b0),
    .error(1'b0),
    .result_valid(1'b0),
    .error_code(8'd0),
    .result_mask(256'd0),
    .accepted_job_count(8'd0),
    .current_job_index(8'd0),
    .jobs_started(32'd0),
    .jobs_completed(32'd0),
    .jobs_dropped(32'd0),
    .active_cycles(32'd0),
    .last_job_cycles(32'd0),
    .max_job_cycles(32'd0),
    .last_batch_cycles(32'd0),
    .batch_id(32'd0),
    .snapshot_batch_id(32'd0),
    .snapshot_accepted_job_count(8'd0),
    .snapshot_jobs_completed(32'd0),
    .snapshot_jobs_dropped(32'd0),
    .snapshot_error(1'b0),
    .snapshot_result_valid(1'b0),
    .snapshot_error_code(8'd0)
  );

  always #5 clk = ~clk;

  initial begin
    #20;
    rst_n = 1'b1;
    @(posedge clk);
    if (irq !== 1'b0) begin
      $display("irq should start low");
      $fatal(1);
    end
    autonomous_irq <= 1'b1;
    @(posedge clk);
    if (irq !== 1'b1) begin
      $display("autonomous irq should bypass the MMIO enable bit");
      $fatal(1);
    end
    autonomous_irq <= 1'b0;
    @(posedge clk);
    if (irq !== 1'b0) begin
      $display("irq should drop when the autonomous source drops");
      $fatal(1);
    end
    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_kv260_sigv_axi_auto_irq.v",
            tb_source,
            [
                "src/sigv_axi_regs.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_kv260_core_processes_batches_and_latches_snapshot_ids(self) -> None:
        bad_signature = bytearray(SIGNATURE)
        bad_signature[0] ^= 0x01
        jobs_blob = PUBKEY + SIGNATURE + PUBKEY + bytes(bad_signature)
        message_assigns = _pack_word_lines("message_mem", MESSAGE)
        job_assigns = _pack_word_lines("job_mem", jobs_blob)

        tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg soft_reset = 0;
  reg [15:0] message_length = 16'd{len(MESSAGE)};
  reg [31:0] requested_job_count = 32'd2;
  reg [1:0] verify_mode = 2'd{STRICT_VERIFY_MODE};
  reg [7:0] dispatch_limit = 8'd0;
  reg [31:0] job_timeout_cycles = 32'd0;
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

  sigv_kv260_core dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .soft_reset(soft_reset),
    .message_length(message_length),
    .requested_job_count(requested_job_count),
    .verify_mode(verify_mode),
    .dispatch_limit(dispatch_limit),
    .job_timeout_cycles(job_timeout_cycles),
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

  task automatic pulse_reset_then_start;
    begin
      @(posedge clk);
      soft_reset <= 1'b1;
      start <= 1'b1;
      @(posedge clk);
      soft_reset <= 1'b0;
      start <= 1'b0;
    end
  endtask

  integer index;
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

    pulse_start();
    wait (done);
    if (busy || !result_valid || error || error_code !== 8'd0) begin
      $display("expected first batch to complete successfully");
      $fatal(1);
    end
    if (result_mask[0] !== 1'b1 || result_mask[1] !== 1'b0) begin
      $display("unexpected first-batch result mask %064x", result_mask);
      $fatal(1);
    end
    if (accepted_job_count !== 8'd2 || current_job_index !== 8'd1) begin
      $display("unexpected first-batch dispatch state accepted=%0d index=%0d", accepted_job_count, current_job_index);
      $fatal(1);
    end
    if (jobs_started !== 32'd2 || jobs_completed !== 32'd2 || jobs_dropped !== 32'd0) begin
      $display("unexpected first-batch counters started=%0d completed=%0d dropped=%0d", jobs_started, jobs_completed, jobs_dropped);
      $fatal(1);
    end
    if (batch_id !== 32'd1 || snapshot_batch_id !== 32'd1 ||
        snapshot_accepted_job_count !== 8'd2 || snapshot_jobs_completed !== 32'd2 ||
        snapshot_jobs_dropped !== 32'd0 || snapshot_error || !snapshot_result_valid ||
        snapshot_error_code !== 8'd0) begin
      $display("unexpected first-batch snapshot state");
      $fatal(1);
    end
    if (last_job_cycles == 32'd0 || last_batch_cycles == 32'd0 || max_job_cycles < last_job_cycles) begin
      $display("expected non-zero first-batch perf counters");
      $fatal(1);
    end

    dispatch_limit = 8'd1;
    pulse_reset_then_start();
    wait (done);
    if (!result_valid || error || error_code !== 8'd0) begin
      $display("expected reset-then-start batch to complete successfully");
      $fatal(1);
    end
    if (accepted_job_count !== 8'd1 || current_job_index !== 8'd0) begin
      $display("unexpected truncated dispatch state accepted=%0d index=%0d", accepted_job_count, current_job_index);
      $fatal(1);
    end
    if (jobs_started !== 32'd1 || jobs_completed !== 32'd1 || jobs_dropped !== 32'd1) begin
      $display("unexpected reset-then-start counters started=%0d completed=%0d dropped=%0d", jobs_started, jobs_completed, jobs_dropped);
      $fatal(1);
    end
    if (batch_id !== 32'd2 || snapshot_batch_id !== 32'd2 ||
        snapshot_accepted_job_count !== 8'd1 || snapshot_jobs_completed !== 32'd1 ||
        snapshot_jobs_dropped !== 32'd1 || snapshot_error || !snapshot_result_valid ||
        snapshot_error_code !== 8'd0) begin
      $display("unexpected truncated snapshot state");
      $fatal(1);
    end

    requested_job_count = 32'd256;
    pulse_start();
    wait (done);
    if (!error || error_code !== 8'd2 || result_valid) begin
      $display("expected oversized requested-job-count parameter error, got error=%0d code=%0d result_valid=%0d",
               error, error_code, result_valid);
      $fatal(1);
    end
    if (batch_id !== 32'd3 || snapshot_batch_id !== 32'd3 ||
        snapshot_error !== 1'b1 || snapshot_result_valid !== 1'b0 ||
        snapshot_error_code !== 8'd2 || snapshot_jobs_completed !== 32'd0) begin
      $display("unexpected parameter-error snapshot state");
      $fatal(1);
    end

    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_kv260_core_snapshots.v",
            tb_source,
            [
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
            ],
        )
        self.assertIn("PASS", stdout)

    def test_kv260_bringup_core_exposes_deterministic_completion(self) -> None:
        tb_source = """`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg soft_reset = 0;
  reg [15:0] message_length = 16'd64;
  reg [31:0] requested_job_count = 32'd2;
  reg [1:0] verify_mode = 2'd0;
  reg [7:0] dispatch_limit = 8'd1;
  reg [31:0] job_timeout_cycles = 32'd0;
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
  wire [31:0] batch_id;
  wire [31:0] snapshot_batch_id;
  wire [7:0] snapshot_accepted_job_count;
  wire [31:0] snapshot_jobs_completed;
  wire [31:0] snapshot_jobs_dropped;
  wire snapshot_error;
  wire snapshot_result_valid;
  wire [7:0] snapshot_error_code;
  wire heartbeat_irq;
  wire heartbeat_led;
  wire message_bram_en;
  wire [9:0] message_bram_addr;
  wire job_bram_en;
  wire [12:0] job_bram_addr;
  integer heartbeat_irq_high_cycles = 0;
  reg heartbeat_led_seen = 1'b0;
  reg heartbeat_led_last = 1'b0;

  sigv_kv260_bringup_core #(
    .HEARTBEAT_INTERVAL_CYCLES(32'd8),
    .HEARTBEAT_PULSE_CYCLES(32'd3)
  ) dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .soft_reset(soft_reset),
    .message_length(message_length),
    .requested_job_count(requested_job_count),
    .verify_mode(verify_mode),
    .dispatch_limit(dispatch_limit),
    .job_timeout_cycles(job_timeout_cycles),
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
    .active_cycles(),
    .last_job_cycles(),
    .max_job_cycles(),
    .last_batch_cycles(),
    .batch_id(batch_id),
    .snapshot_batch_id(snapshot_batch_id),
    .snapshot_accepted_job_count(snapshot_accepted_job_count),
    .snapshot_jobs_completed(snapshot_jobs_completed),
    .snapshot_jobs_dropped(snapshot_jobs_dropped),
    .snapshot_error(snapshot_error),
    .snapshot_result_valid(snapshot_result_valid),
    .snapshot_error_code(snapshot_error_code),
    .heartbeat_irq(heartbeat_irq),
    .heartbeat_led(heartbeat_led),
    .message_bram_en(message_bram_en),
    .message_bram_addr(message_bram_addr),
    .message_bram_dout(32'd0),
    .job_bram_en(job_bram_en),
    .job_bram_addr(job_bram_addr),
    .job_bram_dout(32'd0)
  );

  always #5 clk = ~clk;

  task automatic pulse_start;
    begin
      @(posedge clk);
      start <= 1'b1;
      @(posedge clk);
      start <= 1'b0;
    end
  endtask

  initial begin
    #20;
    rst_n = 1'b1;
    #20;

    pulse_start();
    wait (done);
    if (busy || error || !result_valid || error_code !== 8'd0) begin
      $display("bringup completion flags are wrong");
      $fatal(1);
    end
    if (accepted_job_count !== 8'd1 || jobs_started !== 32'd1 ||
        jobs_completed !== 32'd1 || jobs_dropped !== 32'd1 ||
        result_mask[0] !== 1'b1 || result_mask[1] !== 1'b0) begin
      $display("bringup dispatch/result state is wrong");
      $fatal(1);
    end
    if (batch_id !== 32'd1 || snapshot_batch_id !== 32'd1 ||
        snapshot_accepted_job_count !== 8'd1 || snapshot_jobs_completed !== 32'd1 ||
        snapshot_jobs_dropped !== 32'd1 || snapshot_error || !snapshot_result_valid ||
        snapshot_error_code !== 8'd0) begin
      $display("bringup snapshot state is wrong");
      $fatal(1);
    end
    if (message_bram_en || job_bram_en || message_bram_addr !== 10'd0 || job_bram_addr !== 13'd0) begin
      $display("bringup core should not touch BRAM sideband ports");
      $fatal(1);
    end
    heartbeat_led_last = heartbeat_led;
    repeat (20) begin
      @(posedge clk);
      if (heartbeat_irq) begin
        heartbeat_irq_high_cycles = heartbeat_irq_high_cycles + 1;
      end
      if (heartbeat_led !== heartbeat_led_last) begin
        heartbeat_led_seen = 1'b1;
      end
      heartbeat_led_last = heartbeat_led;
    end
    if (!heartbeat_led_seen) begin
      $display("bringup heartbeat LED did not toggle");
      $fatal(1);
    end
    if (heartbeat_irq_high_cycles == 0) begin
      $display("bringup heartbeat IRQ did not assert");
      $fatal(1);
    end
    if (heartbeat_irq_high_cycles >= 20) begin
      $display("bringup heartbeat IRQ should pulse, not stay high");
      $fatal(1);
    end

    requested_job_count = 32'd0;
    pulse_start();
    repeat (2) @(posedge clk);
    if (!error || error_code !== 8'd2 || snapshot_result_valid) begin
      $display("bringup core should preserve parameter validation");
      $fatal(1);
    end

    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_kv260_bringup_core.v",
            tb_source,
            [
                "src/sigv_kv260_bringup_core.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_kv260_bringup_heartbeat_runs_without_reset_release(self) -> None:
        tb_source = """`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  wire heartbeat_irq;
  wire heartbeat_led;
  integer heartbeat_irq_high_cycles = 0;
  reg heartbeat_led_seen = 1'b0;
  reg heartbeat_led_last = 1'b0;

  sigv_kv260_bringup_core #(
    .HEARTBEAT_INTERVAL_CYCLES(32'd8),
    .HEARTBEAT_PULSE_CYCLES(32'd3)
  ) dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(1'b0),
    .soft_reset(1'b0),
    .message_length(16'd0),
    .requested_job_count(32'd0),
    .verify_mode(2'd0),
    .dispatch_limit(8'd0),
    .job_timeout_cycles(32'd0),
    .busy(),
    .done(),
    .error(),
    .result_valid(),
    .error_code(),
    .result_mask(),
    .accepted_job_count(),
    .current_job_index(),
    .jobs_started(),
    .jobs_completed(),
    .jobs_dropped(),
    .active_cycles(),
    .last_job_cycles(),
    .max_job_cycles(),
    .last_batch_cycles(),
    .batch_id(),
    .snapshot_batch_id(),
    .snapshot_accepted_job_count(),
    .snapshot_jobs_completed(),
    .snapshot_jobs_dropped(),
    .snapshot_error(),
    .snapshot_result_valid(),
    .snapshot_error_code(),
    .heartbeat_irq(heartbeat_irq),
    .heartbeat_led(heartbeat_led),
    .message_bram_en(),
    .message_bram_addr(),
    .message_bram_dout(32'd0),
    .job_bram_en(),
    .job_bram_addr(),
    .job_bram_dout(32'd0)
  );

  always #5 clk = ~clk;

  initial begin
    repeat (20) begin
      @(posedge clk);
      if (heartbeat_irq) begin
        heartbeat_irq_high_cycles = heartbeat_irq_high_cycles + 1;
      end
      if (heartbeat_led !== heartbeat_led_last) begin
        heartbeat_led_seen = 1'b1;
      end
      heartbeat_led_last = heartbeat_led;
    end

    if (!heartbeat_led_seen) begin
      $display("bringup heartbeat LED should toggle even when rst_n stays low");
      $fatal(1);
    end
    if (heartbeat_irq_high_cycles == 0) begin
      $display("bringup heartbeat IRQ should assert even when rst_n stays low");
      $fatal(1);
    end

    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_kv260_bringup_heartbeat_no_reset.v",
            tb_source,
            [
                "src/sigv_kv260_bringup_core.v",
            ],
        )
        self.assertIn("PASS", stdout)

    def test_kv260_core_soft_reset_aborts_verify_wait_and_timeout_reports_error(self) -> None:
        jobs_blob = PUBKEY + SIGNATURE
        message_assigns = _pack_word_lines("message_mem", MESSAGE)
        job_assigns = _pack_word_lines("job_mem", jobs_blob)

        tb_source = f"""`timescale 1ns/1ps
module tb;
  reg clk = 0;
  reg rst_n = 0;
  reg start = 0;
  reg soft_reset = 0;
  reg [15:0] message_length = 16'd{len(MESSAGE)};
  reg [31:0] requested_job_count = 32'd1;
  reg [1:0] verify_mode = 2'd{STRICT_VERIFY_MODE};
  reg [7:0] dispatch_limit = 8'd0;
  reg [31:0] job_timeout_cycles = 32'd0;
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

  sigv_kv260_core dut(
    .clk(clk),
    .rst_n(rst_n),
    .start(start),
    .soft_reset(soft_reset),
    .message_length(message_length),
    .requested_job_count(requested_job_count),
    .verify_mode(verify_mode),
    .dispatch_limit(dispatch_limit),
    .job_timeout_cycles(job_timeout_cycles),
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

  task automatic pulse_soft_reset;
    begin
      @(posedge clk);
      soft_reset <= 1'b1;
      @(posedge clk);
      soft_reset <= 1'b0;
    end
  endtask

  integer index;
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

    pulse_start();
    wait (dut.engine0_busy_slot);
    repeat (5) @(posedge clk);
    pulse_soft_reset();
    repeat (5) @(posedge clk);

    if (busy || done || error || result_valid || jobs_started !== 32'd0 || jobs_completed !== 32'd0 ||
        jobs_dropped !== 32'd0 || current_job_index !== 8'd0 || snapshot_batch_id !== 32'd0) begin
      $display("soft_reset should abort and clear the live batch state");
      $fatal(1);
    end
    if (batch_id !== 32'd1) begin
      $display("aborted launch should still consume one batch_id");
      $fatal(1);
    end

    pulse_start();
    wait (done);
    if (busy || !result_valid || error || error_code !== 8'd0) begin
      $display("post-abort relaunch should complete successfully");
      $fatal(1);
    end
    if (batch_id !== 32'd2 || snapshot_batch_id !== 32'd2 ||
        snapshot_error || !snapshot_result_valid || snapshot_error_code !== 8'd0 ||
        snapshot_jobs_completed !== 32'd1) begin
      $display("successful relaunch snapshot mismatch");
      $fatal(1);
    end

    job_timeout_cycles = 32'd32;
    pulse_start();
    wait (done);
    if (!error || !result_valid || error_code !== 8'd4) begin
      $display("expected timeout error, got error=%0d result_valid=%0d code=%0d", error, result_valid, error_code);
      $fatal(1);
    end
    if (jobs_completed !== 32'd1) begin
      $display("timed out job should not increment completed-job count");
      $fatal(1);
    end
    if (batch_id !== 32'd3 || snapshot_batch_id !== 32'd3 ||
        snapshot_error !== 1'b1 || snapshot_result_valid !== 1'b1 ||
        snapshot_error_code !== 8'd4 || snapshot_jobs_completed !== 32'd1) begin
      $display("timeout snapshot mismatch");
      $fatal(1);
    end

    $display("PASS");
    #20;
    $finish;
  end
endmodule
"""

        stdout = _run_verilator(
            "tb_kv260_core_abort_timeout.v",
            tb_source,
            [
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
            ],
        )
        self.assertIn("PASS", stdout)


if __name__ == "__main__":
    unittest.main()
