# KV260 Sigverify Shell

This directory contains the compile-first KV260 port scaffolding for the Solana
Ed25519 verifier.

Current scope:

- reusable verifier RTL is sourced from `../rtl/`
- `src/sigv_axi_regs.v` provides the AXI-Lite control/status register block
- `src/sigv_kv260_core.v` walks the job BRAM window and drives the shared
  `ed25519_verify_engine`
- `src/kv260_sigv_top.v` packages the register block, verifier core, and BRAM
  sideband ports for Vivado block design use
- `tcl/create_project.tcl` creates the Vivado project and KV260 block design
- `tcl/build_bitstream.tcl` runs implementation and exports an `.xsa`

The first milestone for this target is a batch-buildable hardware shell on a
supported host. On-board Linux bring-up remains a later step because the
physical KV260 has not arrived yet.

## Memory Map

The PS-visible windows are fixed now so later userspace and device-tree work can
assume stable addresses:

- control/status registers: `0xA0000000`
- message BRAM window: `0xA0010000`
- job BRAM window: `0xA0020000`

The AXI-Lite register block now exposes the verifier mode, a per-job watchdog,
an interrupt control register, batch identity/snapshot metadata, and
batch/job perf counters in addition to the original control and result
registers:

- `0x00`: control command register
  - `0x1`: `start`
  - `0x2`: `soft_reset`
  - `0x3`: `reset_then_start`
- `0x04`: status
  - `bit0=busy`
  - `bit1=done`
  - `bit2=error`
  - `bit3=result_valid`
  - `bit4=irq_pending`
  - `bit5=config_write_ignored`
  - `bit6=config_locked`
- `0x08`: message length
- `0x0C`: requested job count (`32-bit`; values `0` and `>255` are rejected)
- `0x10..0x2C`: result mask words `[255:0]`
- `0x30`: error code
- `0x34`: LED override
- `0x38`: verify config (`bits[1:0]=verify_mode`, `bits[15:8]=dispatch_limit`)
- `0x3C`: dispatch status (`accepted_job_count`, `current_job_index`, `inflight`)
- `0x40`: cumulative jobs started
- `0x44`: cumulative jobs completed
- `0x48`: cumulative jobs dropped by dispatch cap
- `0x4C`: active batch cycles
- `0x50`: last job cycles
- `0x54`: max job cycles
- `0x58`: last batch cycles
- `0x5C`: per-job timeout cycles (`0` disables the watchdog)
- `0x60`: IRQ control/status (`bit0=enable`, `bit1=pending`, write `0x3` to ack and keep enabled)
- `0x64`: live `batch_id`
- `0x68`: completion snapshot `batch_id`
- `0x6C`: completion snapshot accepted-job count
- `0x70`: completion snapshot completed-job count
- `0x74`: completion snapshot dropped-job count
- `0x78`: completion snapshot error status (`bits[7:0]=error_code`, `bit8=error`, `bit9=result_valid`)
- `0x7C`: hardware magic (`0x53494756`, ASCII `SIGV`)
- `0x80`: hardware build (`bits[7:0]=mode`, `bits[15:8]=register API version`; mode `0=full`, `1=bringup`)

Set `KV260_SIGV_HW_MODE=bringup` when building a tiny deterministic shell for
PS-to-PL AXI recovery. Bring-up mode preserves the control and BRAM address map
but replaces the Ed25519 verifier with a one-cycle deterministic completion
path. The default is `KV260_SIGV_HW_MODE=full`.

Accepted control writes clear the visible `done`, `error`, and `result_valid`
status bits before the next batch starts so an immediate poll cannot see stale
completion state from the previous run.

`soft_reset` now asserts a local abort/reset into the shared
`ed25519_verify_engine`, so a reset during `ST_VERIFY_WAIT` no longer leaves the
wrapper idle while the sub-engine keeps running internally. A pure
`soft_reset` clears the live batch state and counters; `reset_then_start`
clears the live state and launches a new batch, but the monotonic `batch_id`
and the latched completion snapshot remain available for software correlation.

Writes to `MESSAGE_LEN`, `JOB_COUNT`, `VERIFY_CFG`, and `JOB_TIMEOUT_CYCLES`
are ignored while `busy=1`. Software should treat those fields as locked for
the active batch; `STATUS.config_write_ignored` is sticky until the next
control command.

`accepted_job_count` is the number of jobs the core will actually process for
the current batch after the optional `dispatch_limit` is applied. Only
`result_mask[0:accepted_job_count-1]` is meaningful. Jobs excluded by the
dispatch cap are counted in `jobs_dropped`; they are not represented as failed
verification bits.

`verify_mode=0` keeps the exact-equation check with fast low-order point
rejection. `verify_mode=1` switches to a cofactored final check intended to
track Agave/Zebra validator semantics more closely.

The job loader now reads the `96`-byte job records as `24` aligned `32-bit`
words, and the wrapper prefetches the next job into a shadow register bank
while the current verifier instance is running. The external BRAM layout stays
unchanged.

## Performance Target

The current optimization branch targets a 100 MHz PL clock for sub-`1 ms`
single-signature verification. The full KV260 image instantiates one verifier
lane by default; the wrapper RTL remains parameterized so multi-lane simulation
and later scale-out work can reuse the same dispatcher.

RTL benchmarks meet the 100 MHz cycle budget:

- strict valid verify: `97,680` cycles
- Agave/Zebra-mode valid verify: `98,340` cycles
- invalid decode rejection: `14,732` cycles
- KV260 wrapper last processed job: `97,709` cycles

The latest 100 MHz implementation is resource-feasible but not timing closed.
The measured physopt checkpoint used `58,634` LUTs, `42,118` FFs, `33` RAMB36
blocks, and `45` DSP48E2 blocks, with `WNS=-2.403 ns`. The previous
`point_core/fe_a_reg[*]/CE` worst path is removed; the current worst paths are
point-core control-enable fanout paths from `point_core/step_reg[1]_rep__2` into
`point_core/out_z_reg[*]/CE`, with related `fe_a_reg[*]/D` paths nearby.

## Build

Requirements:

- `vivado` from a KV260-capable AMD install

Create the Vivado project and block design:

```bash
make project
```

Build the bitstream and export the hardware handoff:

```bash
make bitstream
```

The exported `.xsa` lands under `build/hw/`.

Implementation reports now land under `build/hw/reports/`:

- `timing_summary.rpt`
- `utilization.rpt`
- `clock_utilization.rpt`
