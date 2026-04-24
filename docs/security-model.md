# Security Model

This repository implements a narrow verification pipeline:

- host-side Solana transaction extraction
- FPGA/KV260 Ed25519 signature verification
- PS/PL control and result reporting around that verifier

## Current Implemented Security Properties

- The shared RTL and KV260 path verify Ed25519 signatures over the exact serialized Solana `Message` bytes.
- Host-side tooling preserves the extracted message bytes and repeated `pubkey[32] || signature[64]` tuples that the verifier consumes.
- The KV260 control plane distinguishes between requested jobs, accepted jobs, and jobs dropped by the dispatch cap.
- Oversized message lengths and invalid job-count requests fail with explicit error/status reporting.
- The SHA-512 message reader rejects oversize lengths instead of silently wrapping BRAM addresses.
- The active verifier path does not manage long-term private keys.

## Out Of Scope

The repository does not currently implement any of the following:

- key generation or private-key storage
- transaction signing
- seed handling or derivation standards
- secure boot, firmware update signing, or rollback protection
- audited host isolation or production hardening

## Trust Boundary

For the KV260 verifier path, the trust model is intentionally narrow:

- host software prepares exact message bytes and signer tuples
- the PL verifier checks signature validity and returns pass/fail bits
- policy, networking, and transaction forwarding stay on the PS/host side and remain outside the verifier's trust boundary

## Developer Guidance

- Treat the KV260 verifier as a verification accelerator, not a key-management device.
- Keep documentation in present tense only for behavior that exists in code today.
- Keep scope statements tight: this repo verifies signatures; it does not manage user keys.
