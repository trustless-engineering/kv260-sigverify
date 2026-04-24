# KV260 Improvement Plan

This document captures the next high-value improvements for the KV260
implementation after the current control-path cleanup and the first 100 MHz
resource/performance refactor.

The emphasis is on correctness and system behavior first, then PS/PL data-path
efficiency, and only after that on scaling throughput.

## Priorities

### 1. Make `soft_reset` abort the in-flight verifier

Why this matters:

- `soft_reset` currently resets the KV260 wrapper state in
  `fpga/kv260_sigv/src/sigv_kv260_core.v`
- the shared `ed25519_verify_engine` only resets on `rst_n`
- this creates a mismatch where the wrapper can return to idle while the
  sub-engine is still internally active

Recommended work:

- add an explicit local reset/abort path into the verifier instance
- define the post-abort contract for `busy`, `done`, `error`, and counters
- add a regression that asserts reset during `ST_VERIFY_WAIT`

### 2. Freeze or shadow batch configuration while `busy`

Why this matters:

- the AXI register block still accepts writes to `MESSAGE_LEN`, `JOB_COUNT`, and
  `VERIFY_CFG` during an active batch
- software can mutate the visible configuration while hardware is still working
  on the previous launch

Recommended work:

- either reject config writes while `busy`
- or stage them into shadow registers and commit only on `start`
- expose a clear software-visible rule in the register documentation

### 3. Add a completion interrupt and stop polling

Why this matters:

- the current shell has no IRQ output
- the userspace smoke tool polls control registers through `/dev/mem`
- polling is acceptable for bring-up but not for a production relay appliance

Recommended work:

- add a `done/error` interrupt output from the PL shell
- route it through `UIO` or a minimal platform driver
- convert userspace waiting from polling to blocking interrupt-driven handling

### 4. Replace the byte-at-a-time job loader

Why this matters:

- the core currently spends three states per byte loading a `96`-byte job from
  BRAM
- the BRAM datapath is already `32` bits wide
- the wrapper is leaving throughput on the table before the verifier even
  starts work

Recommended work:

- first step: load jobs a word at a time instead of a byte at a time
- second step: prefetch the next job into a second register bank while the
  current job is running
- keep the external BRAM layout unchanged during this refactor

### 5. Move from fixed BRAM windows to DMA-backed buffering

Why this matters:

- the current path rewrites fixed message/job windows for every batch
- this is good for bring-up but scales poorly once the PS is feeding real
  traffic
- the current architecture copies data more than necessary

Recommended work:

- introduce a PS DDR descriptor/ring format
- use AXI DMA or an equivalent streaming path into the verifier shell
- support double-buffering so software can fill the next batch while PL works on
  the current one

### 6. Add a per-job watchdog and explicit timeout error

Why this matters:

- `sigv_kv260_core` currently waits indefinitely for `verifier_done`
- a hung sub-engine or unexpected integration bug can wedge the batch forever

Recommended work:

- add a configurable per-job cycle timeout
- introduce an explicit timeout error code
- define whether timed-out jobs abort the whole batch or fail only the current
  job

### 7. Add a batch sequence ID and atomic completion snapshot

Why this matters:

- the register file exposes counters and result bits, but not a stable batch
  identity
- once interrupts, retries, or multiple host processes exist, software needs a
  way to prove that a result belongs to the launch it initiated

Recommended work:

- add a monotonically increasing `batch_id`
- latch final batch metadata atomically at completion
- include `batch_id`, accepted-job count, dropped-job count, and final error
  state in the snapshot

### 8. Close the 100 MHz point-core timing path

Why this matters:

- the 100 MHz RTL now verifies in under `100,000` cycles, which is the cycle
  budget for sub-`1 ms` verification
- the latest placed KV260 implementation is resource-feasible but not
  timing-clean
- the previous `fe_a`/`fe_b` operand hold-enable path is removed, but the
  remaining worst paths are still point-core control enables, not DSP
  exhaustion

Recommended work:

- split the monolithic point-core FSM into narrower operation controllers, or
  otherwise localize the output register and aux-reduction enable logic
- add one or more control pipeline stages only where the cycle budget can absorb
  them
- rerun placed timing after each control-path cut before investing in routing

### 9. Scale out with multiple verifier lanes

Why this matters:

- the KV260 bitstream path currently instantiates a single
  `ed25519_verify_engine` to keep the 100 MHz design inside the K26 timing and
  area envelope
- the RTL wrapper still supports multiple lanes for simulation and later
  exploration
- once single-lane timing is closed, the K26 may have room for multiple lanes
- lane-level parallelism will likely outperform small wrapper-only tuning

Recommended work:

- measure LUT/BRAM/DSP usage and timing for the single-lane design first
- add a simple multi-lane dispatcher over the existing job format
- preserve the current software-visible batch contract while parallelizing the
  internals

### 10. Track timing and utilization as first-class outputs

Why this matters:

- the shell now targets a `100 MHz` PL clock for the sub-`1 ms` verification
  goal
- further architectural changes should be driven by data, not assumptions

Recommended work:

- add repeatable Vivado reporting for utilization and worst negative slack
- record results for the single-lane baseline before major restructuring
- use those reports to decide whether to prioritize DMA, lane replication, or
  verifier-core tuning

## Suggested Execution Order

1. Fix `soft_reset` correctness.
2. Freeze or shadow config writes while `busy`.
3. Add a per-job watchdog and explicit timeout handling.
4. Add PL completion interrupt support and move software off polling.
5. Replace the byte-at-a-time loader with word-wide loading and prefetch.
6. Add batch sequence IDs and atomic completion snapshots.
7. Establish automated timing/utilization reporting.
8. Close the 100 MHz point-core timing path.
9. Introduce DMA-backed buffering.
10. Evaluate and, if justified by measurements, add multiple verifier lanes.

## Implementation Status

Implemented in the current KV260 control-path revision:

- `soft_reset` now asserts a local abort into `ed25519_verify_engine` and clears
  the live wrapper state.
- `MESSAGE_LEN`, `JOB_COUNT`, `VERIFY_CFG`, and `JOB_TIMEOUT_CYCLES` writes are
  ignored while a batch is busy, with a sticky status bit for software.
- The control block exposes a level-high completion IRQ with explicit enable and
  acknowledge bits.
- The job loader reads aligned `32`-bit words and prefetches the next job into a
  shadow bank while the current job verifies.
- A configurable per-job watchdog reports `ERR_JOB_TIMEOUT`.
- `batch_id` and atomic completion snapshot registers are exposed to software.
- Vivado timing, utilization, and clock-utilization reports are generated and
  staged with the image metadata.

Implemented in the 100 MHz resource/performance refactor:

- The KV260 full bitstream path is limited to one verifier lane while the RTL
  wrapper remains parameterized for one or two lanes.
- The PL clock metadata and Linux clock helper now target the 100 MHz `pl0_ref`
  configuration (`PL0_REF_CTRL=0x01010F00`, Vivado interface metadata
  `FREQ_HZ=99999001`).
- `ed25519_point_core` now uses `fe25519_mul_wide_core`, a 5x51 limb
  multiplier that consumes `45` DSP48E2 blocks in the single-lane KV260 image.
- The wide multiplier registers each diagonal product set before summing and
  reducing, which trades a small cycle increase for much lower DSP/LUT timing
  pressure.
- `fe25519_aux_core` uses reduction formulas specialized for
  `p = 2^255 - 19`, and decompression no longer stores a full encoded-point
  copy only to clear the sign bit.
- RTL cycle tests now enforce the sub-`1 ms` budget at 100 MHz:
  strict valid verify is `97,680` cycles, Agave/Zebra-mode valid verify is
  `98,340` cycles, invalid decode rejection is `14,732` cycles, and the KV260
  wrapper reports `97,709` cycles for the last processed job.

Latest implementation result:

- A physopt KV260 checkpoint used `58,634` LUTs, `42,118` FFs, `33` RAMB36
  blocks, and `45` DSP48E2 blocks, so the refactor fits the K26 resource
  envelope.
- Timing is not closed yet at 100 MHz. After defaulting `fe_a`/`fe_b` every
  cycle, the previous `point_core/fe_a_reg[*]/CE` worst path is gone, but the
  checkpoint still reports `WNS=-2.403 ns` and `2,492` failing setup endpoints.
  The current worst paths run from `point_core/step_reg[1]_rep__2` to
  `point_core/out_z_reg[*]/CE`, with related `fe_a_reg[*]/D` and
  point/aux step-control paths nearby.
- A one-cycle public output/done bus experiment was rejected after it worsened
  physopt WNS to about `-3.16 ns`; the next high-value refactor should target
  output/aux control localization without moving the wide public result bus
  directly onto a worse aux-reduction path.

Still deferred:

- DMA-backed buffering and descriptor rings remain a later data-path change.
- Multiple verifier lanes should wait until the single-lane 100 MHz design
  closes timing and the utilization reports justify the extra area and
  dispatcher complexity.

## Notes

- Correctness work should land before throughput work.
- The current software-visible batch contract should remain stable unless there
  is a strong reason to change it.
- Architectural changes should be validated with both RTL regressions and
  measured Vivado reports on the KV260 target.
