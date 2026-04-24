# txnverify-fpga

`txnverify-fpga` is an experimental Solana Ed25519 signature-verification project targeting the AMD Xilinx KV260.

The active implementation track is a KV260-based verifier appliance:

- shared reusable RTL lives in `fpga/rtl/`
- the KV260 shell, AXI register block, and PS/PL control plane live in `fpga/kv260_sigv/`
- host-side extraction, framing, and smoke-test tools live in `tools/`
- PetaLinux packaging for the board image lives in `petalinux/kv260_sigv/`

## Repo Layout

```
txnverify-fpga/
├── fpga/
│   ├── rtl/                 # Shared Ed25519 verifier RTL
│   └── kv260_sigv/          # KV260 shell, AXI regs, Vivado flow
├── tools/                   # Host-side extraction, framing, and bring-up tools
├── petalinux/kv260_sigv/    # PetaLinux recipes and staged image content
└── docs/                    # Architecture, bring-up, and integration documents
```

## Development Status

### Active Implementation

- KV260 Ed25519 verification path and control plane
- Shared verifier RTL and Verilator regression coverage
- Host-side Solana transaction extraction and KV260 smoke tooling
- PetaLinux packaging for the canonical userspace tools

## Pointers

- KV260 overview: `fpga/kv260_sigv/README.md`
- Toolchain notes: `docs/kv260-toolchain-setup.md`
- Porting/background plan: `docs/kv260-port-plan.md`
- Solana integration notes: `docs/solana-integration.md`
- Security model: `docs/security-model.md`

## License

TBD

## Security Notice

This repository is experimental. Do not use it to protect or move real funds until the relevant path has been fully implemented, audited, and tested.
