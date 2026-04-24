# Solana Integration Guide

## Scope

This repository implements Solana signature verification on the KV260 platform.

Current code paths:

- `tools/solana_sigverify_mvp.py` extracts exact serialized `Message` bytes and repeated `pubkey[32] || signature[64]` tuples from transactions
- `fpga/rtl/` contains the reusable Ed25519 verifier RTL
- `fpga/kv260_sigv/` wraps that verifier for a KV260 PS/PL integration path

## Ed25519 and Solana

Solana uses Ed25519 signatures:

- public key: 32 bytes
- signature: 64 bytes
- signed payload: the exact serialized `Message` bytes, not a SHA-256 digest

For verification, the relevant relation is:

```text
Ed25519_Verify(signature, signer_pubkey, serialized_message)
```

That exact-byte contract is what the host extractor, shared RTL, and KV260
control path are built around.

## Transaction Structure

At a high level, Solana transactions contain:

```rust
Transaction {
    signatures: Vec<Signature>,
    message: Message {
        header: MessageHeader,
        account_keys: Vec<Pubkey>,
        recent_blockhash: Hash,
        instructions: Vec<Instruction>,
    }
}
```

Validators verify each signature against the signer public key and the exact
serialized `message` bytes. The current repo mirrors that verification model.

## Current Repo Flow

```text
raw Solana transaction
        |
        v
tools/solana_sigverify_mvp.py
- decode transaction
- preserve exact serialized message bytes
- emit signer jobs as pubkey || signature
        |
        v
KV260 host / smoke tool
- write message bytes + jobs into BRAM windows
- program control/status registers
        |
        v
shared Ed25519 verifier RTL
- verify accepted jobs
- return result bits for accepted_job_count
```

Important details:

- `requested_job_count` is validated as a full 32-bit value; values `0` and `>255` are rejected
- `dispatch_limit` may reduce the accepted work for a batch
- only `result_mask[0:accepted_job_count-1]` is meaningful
- dispatch-limited jobs are counted separately as dropped jobs

## Out Of Scope

This repository is scoped to verification and batch filtering. It does not
implement:

- key management or long-term private-key storage
- transaction signing
- seed handling or derivation standards
- interactive end-user approval interfaces
