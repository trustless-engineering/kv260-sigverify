# KV260 Sigverify Daemon

`kv260_sigv_daemon` is a Rust Unix-socket HTTP service for the KV260 sigverify
path. It runs on the PS/Linux side, parses serialized Solana transactions, and
submits exact `message_bytes` plus repeated `pubkey[32] || signature[64]`
verification jobs to the PL accelerator through the existing UIO or `/dev/mem`
control path.

The PetaLinux image installs a `systemd` unit named `kv260_sigv_daemon.service`
that starts the daemon on boot and binds `/run/kv260-sigv.sock`.

## Build

```bash
cargo build -p kv260_sigv_daemon
```

## Run

```bash
cargo run -p kv260_sigv_daemon -- serve --socket-path /tmp/kv260-sigv.sock
```

On target, the packaged service can be inspected with:

```bash
systemctl status kv260_sigv_daemon
```

The daemon defaults to:

- `--control-path auto`
- `--message-path auto`
- `--job-path auto`
- `--wait-mode auto`

When `auto` is used it prefers `/dev/uio*` regions discovered under
`/sys/class/uio` and falls back to `/dev/mem` plus polling if UIO is not
available.

## API

### `GET /v1/status`

```bash
curl --unix-socket /tmp/kv260-sigv.sock http://localhost/v1/status
```

### `POST /v1/verify-transaction`

```bash
curl --unix-socket /tmp/kv260-sigv.sock \
  -H 'content-type: application/json' \
  -d '{
        "transaction": {
          "encoding": "base64",
          "data": "AQAB..."
        },
        "verify_mode": "strict",
        "include_parse_summary": true
      }' \
  http://localhost/v1/verify-transaction
```

### `POST /v1/verify-batch`

`message.encoding` accepts `base64` or `hex`. Each `jobs[*].pubkey` and
`jobs[*].signature` is base64-encoded.

```bash
curl --unix-socket /tmp/kv260-sigv.sock \
  -H 'content-type: application/json' \
  -d '{
        "message": {
          "encoding": "base64",
          "data": "AQID"
        },
        "jobs": [
          {
            "pubkey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "signature": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=="
          }
        ]
      }' \
  http://localhost/v1/verify-batch
```
