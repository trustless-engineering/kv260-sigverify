# KV260 Port Plan

## Goal

Define the current Solana sigverify design for the AMD Kria KV260 so the verifier can run on a K26-class platform with:

- enough programmable logic to fit the full RTL verifier
- an onboard Linux-capable PS for QUIC termination, transaction parsing, and forwarding
- a PS/PL interface built for batched verification

The target outcome is a `KV260` relay appliance design, not a transparent inline Ethernet bump-in-the-wire.

## Assumptions

- Compatibility target is current Solana transaction signature behavior: verify Ed25519 signatures over the exact serialized message bytes.
- The current cryptographic RTL is kept as the starting point unless timing or fit on the K26 says otherwise.
- QUIC termination, transaction parsing, policy, and forwarding stay on the KV260 `PS` under Linux.
- The `PL` is used for Ed25519 verification work, not for QUIC, TLS, or full Solana parsing.
- The single RJ45 on the KV260 is treated as the network interface for a relay/proxy endpoint. This plan does not assume dual-port inline forwarding hardware.
- This workstation does not currently expose `vivado`, `xsct`, or `petalinux-create`, so the immediate output is a port plan and repo preparation, not a built KV260 image.

## KV260 Facts That Matter

- The KV260 starter kit uses a `K26` SOM with `256,200` system logic cells, `117,120` CLB LUTs, `234,240` CLB flip-flops, `144` BRAM blocks, `64` UltraRAM blocks, and `1,248` DSP slices.
- The starter kit exposes one `10/100/1000` Ethernet interface, one integrated FTDI `UART/JTAG` interface on `J4`, a direct `JTAG` header on `J3`, a `Pmod` header, `microSD`, and reset/boot controls.
- AMD supports the board through `Vivado` board flow and the Linux image includes `xmutil` for SOM/platform management.

These facts drive the right system architecture: the KV260 should be treated as a Linux appliance with a PL accelerator, not as a standalone serial coprocessor.

Sources:

- [K26 SOM Data Sheet DS987](https://docs.amd.com/r/en-US/ds987-k26-som/Programmable-Logic)
- [KV260 Starter Kit User Guide UG1089](https://docs.amd.com/r/en-US/ug1089-kv260-starter-kit)
- [KV260 Product Page](https://www.amd.com/en/products/system-on-modules/kria/k26/kv260-vision-starter-kit.html)

For the supported host/toolchain setup, see [kv260-toolchain-setup.md](kv260-toolchain-setup.md).

## Current Starting Point

The reusable verifier RTL lives under `fpga/rtl/`. The portable crypto-heavy core is:

- `ed25519_verify_engine.v`
- `ed25519_point_core.v`
- `fe25519_mul_core.v`
- `fe25519_aux_core.v`
- `sha512_stream_engine.v`
- `sha512_compress_core.v`
- `scalar_reduce_mod_l.v`

The board-specific shell lives under `fpga/kv260_sigv/`. The reusable RTL
boundary should stay at the verifier, field arithmetic, and point-ops layers.

## Recommended Architecture

```text
clients / upstream senders
        |
      QUIC
        |
KV260 PS Linux relay
- terminate QUIC/TLS
- parse Solana transaction bytes
- extract exact message/signer tuples
- write jobs into PL-visible memory
        |
AXI-Lite + AXI BRAM
        |
KV260 PL verifier block
- iterate jobs
- run Ed25519 verify
- produce pass/fail bitmask
        |
KV260 PS Linux relay
- drop failed txs
- forward passing txs
```

### Why this split

- The KV260 has one onboard Ethernet port, so it is naturally a relay endpoint, not a dual-port inline filter.
- The verifier is iterative and message sizes are small enough that a simple PS-to-PL memory-mapped interface is acceptable for v1.
- Using a serial request protocol as the main KV260 data path would add unnecessary serialization and software complexity.

## Interface Decision

### External API

Keep the existing logical batch format at the software boundary:

- exact `message_bytes`
- repeated `pubkey[32] || signature[64]`
- per-job bitmask result

The current Python extractor and future Rust relay can continue to think in those terms.

### Internal PS/PL API

Do **not** keep UART framing between PS and PL on the KV260.

Use:

- `AXI-Lite` control/status registers
- `AXI BRAM Controller` windows for message bytes, job tuples, and result bits
- optional interrupt from PL to PS on completion

This is simpler than AXI DMA for the initial port and fits the current workload better.

## Proposed PL Memory Map

This is the initial control plane to implement.

### AXI-Lite registers

- `0x0000 CONTROL`
  - `0x1`: `start`
  - `0x2`: `soft_reset`
  - `0x3`: `reset_then_start`
- `0x0004 STATUS`
  - bit `0`: busy
  - bit `1`: done
  - bit `2`: error
  - bit `3`: result_valid
- `0x0008 MESSAGE_LEN`
- `0x000C JOB_COUNT`
- `JOB_COUNT` is the full 32-bit requested batch size; values `0` and `>255`
  are rejected instead of being truncated
- `0x0010 RESULT_MASK_WORD0`
- `0x0014 RESULT_MASK_WORD1`
- `0x0018 RESULT_MASK_WORD2`
- `0x001C RESULT_MASK_WORD3`
- `0x0020 RESULT_MASK_WORD4`
- `0x0024 RESULT_MASK_WORD5`
- `0x0028 RESULT_MASK_WORD6`
- `0x002C RESULT_MASK_WORD7`
- `0x0030 ERROR_CODE`
- `0x0034 LED_CONTROL`
  - optional debug/override register for bring-up

Accepted control writes clear `STATUS.done`, `STATUS.error`, and
`STATUS.result_valid` before the next launch so software does not observe stale
completion bits after a restart.

Only `result_mask[0:accepted_job_count-1]` is meaningful for a batch.
Dispatch-limited jobs should be counted separately as dropped jobs rather than
materialized as verification failures.

### BRAM windows

- `message_bram`
  - size: `4096` bytes
  - payload: exact serialized message bytes
- `job_bram`
  - size: `24576` bytes minimum for `255 * 96`
  - payload: `pubkey[32] || signature[64]` repeated

If later profiling says this is too small or awkward, the next step is AXI DMA from PS DDR into streaming PL logic. That should be phase two, not phase one.

## Software Plan on the PS

### Bring-up tool

Add a simple userspace test tool on the KV260 Linux side that:

- mmaps the AXI-Lite registers and BRAM windows through UIO or a simple character driver
- copies a known-good or known-bad job set into BRAM
- starts the PL verifier
- polls or waits for completion
- prints the result bitmask

This tool exercises the KV260 path from Linux userspace during bring-up.

### Relay process

After the bring-up tool works:

- terminate QUIC on the KV260 PS
- deserialize Solana transactions
- preserve the exact raw transaction bytes for forwarding
- extract signature jobs from the exact serialized message
- submit jobs to PL
- forward only passing transactions

The relay can start life in Python for correctness work, but the intended steady-state direction should be Rust.

## RTL Porting Strategy

### What stays reusable

- field arithmetic
- scalar reduction
- SHA-512 challenge generation
- point decompression and point operations
- the top-level verifier state machine

### What gets replaced

- board wrapper
- transport/parser front end
- LED driver integration
- build system and constraints

### New KV260 RTL blocks

Add these as the first concrete port artifacts:

- `kv260_sigv_top.v`
  - Vivado top-level wrapper
  - clocks, resets, AXI-facing wrapper, optional debug LED
- `sigv_axi_regs.v`
  - AXI-Lite register file for control and status
- `sigv_axi_bram_if.v`
  - BRAM-facing glue between PS-visible memory and the verifier
- `sigv_kv260_core.v`
  - thin orchestration layer that loads jobs from BRAM and drives `ed25519_verify_engine`

Do not embed Zynq PS hand wiring directly into the crypto modules.

## Vivado / Platform Plan

### Phase 1: Board-flow hardware shell

- create a Vivado project using the KV260 board flow
- instantiate the Zynq UltraScale+ MPSoC processing system
- enable PS DDR, UART/JTAG, and one GP master AXI port from PS to PL
- add AXI interconnect, AXI-Lite register block, and AXI BRAM controller(s)
- export a bitstream and hardware handoff for Linux

### Phase 2: PL verifier integration

- connect `sigv_kv260_core` behind the BRAM and register blocks
- verify a one-job known-good and known-bad vector from PS software
- confirm result-mask and status behavior

### Phase 3: Linux integration

- expose the memory map through `uio_pdrv_genirq` or a tiny platform driver
- add a PS-side smoke test app
- add an optional IRQ path for completion

### Phase 4: Relay integration

- port the existing host transaction extractor logic into a KV260-resident process
- run real Solana transaction vectors end to end
- add metrics and software fallback

## Bring-Up Order

Do not jump straight to a QUIC relay.

Use this order:

1. `Vivado shell only`
   - prove the board boots and the PL region loads
2. `Register access only`
   - read/write AXI-Lite registers from Linux
3. `BRAM path only`
   - read/write test patterns through BRAM windows
4. `Verifier lane only`
   - verify one job
5. `Batch verification`
   - verify multiple jobs against one message
6. `Transaction extractor integration`
   - feed real serialized Solana transactions
7. `QUIC relay`
   - only after the lower layers are stable

## Testing Plan

### Simulation

Keep the existing RTL unit tests and add KV260-specific integration tests for:

- register writes and reads
- BRAM job/message loading
- start/busy/done/error behavior
- result-mask ordering across multi-job batches

### On-hardware smoke tests

- boot Linux on the KV260
- confirm `J4` UART console access
- load the PL image
- run the PS-side smoke-test utility against:
  - one valid Ed25519 vector
  - the same vector with a flipped signature bit
  - one real serialized Solana transaction with one signer
  - one multi-signer batch

### End-to-end relay tests

- malformed transaction rejected in software before PL submission
- bad signature rejected by PL
- good transaction forwarded unchanged
- PL unavailable path falls back cleanly to software verification

## Risks and Limits

- The KV260 has only one onboard Ethernet port, so this design is a network relay, not a transparent inline filter appliance.
- The current verifier is still heavily iterative. It may fit on the KV260 and still need pipelining or cleanup for clock closure.
- AXI BRAM is the right first interface, but it may become the next bottleneck if batching grows large or if multiple verifier lanes are added later.
- If real throughput matters more than simplicity, the long-term KV260 path likely becomes:
  - PS software parsing
  - DMA-fed PL verifier
  - multiple verifier lanes

## Immediate Repo Tasks

These are the next concrete changes to make after this plan is accepted:

1. Keep the reusable verifier modules isolated from board-specific transport assumptions.
2. Add a new `fpga/kv260_sigv/` directory with:
   - `README.md`
   - `tcl/create_project.tcl`
   - `src/kv260_sigv_top.v`
   - `src/sigv_axi_regs.v`
   - `src/sigv_kv260_core.v`
   - `xdc/kv260_sigv.xdc`
3. Add a PS-side smoke-test utility under `tools/`.
4. Keep the repo focused on the KV260 shell and shared RTL only.
