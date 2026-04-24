#!/usr/bin/env python3
"""Minimal userspace smoke tool for the KV260 sigverify shell."""

from __future__ import annotations

import argparse
import base64
import json
import mmap
import os
import select
import struct
import sys
import time
from dataclasses import dataclass
from pathlib import Path


TOOLS_DIR = Path(__file__).resolve().parent
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import solana_sigverify_mvp as mvp  # noqa: E402


CONTROL_BASE = 0xA0000000
MESSAGE_BASE = 0xA0010000
JOB_BASE = 0xA0020000

CONTROL_SIZE = 0x1000
MESSAGE_SIZE = 0x1000
JOB_SIZE = 0x8000

REG_CONTROL = 0x0000
REG_STATUS = 0x0004
REG_MESSAGE_LEN = 0x0008
REG_JOB_COUNT = 0x000C
REG_RESULT_MASK_BASE = 0x0010
REG_ERROR_CODE = 0x0030
REG_VERIFY_CFG = 0x0038
REG_DISPATCH_STATUS = 0x003C
REG_JOBS_STARTED = 0x0040
REG_JOBS_COMPLETED = 0x0044
REG_JOBS_DROPPED = 0x0048
REG_ACTIVE_CYCLES = 0x004C
REG_LAST_JOB_CYCLES = 0x0050
REG_MAX_JOB_CYCLES = 0x0054
REG_LAST_BATCH_CYCLES = 0x0058
REG_JOB_TIMEOUT_CYCLES = 0x005C
REG_IRQ_CTRL_STATUS = 0x0060
REG_BATCH_ID = 0x0064
REG_SNAPSHOT_BATCH_ID = 0x0068
REG_SNAPSHOT_ACCEPTED = 0x006C
REG_SNAPSHOT_COMPLETED = 0x0070
REG_SNAPSHOT_DROPPED = 0x0074
REG_SNAPSHOT_ERR_STATUS = 0x0078
REG_HW_MAGIC = 0x007C
REG_HW_BUILD = 0x0080

HW_MAGIC = 0x53494756
HW_MODE_FULL = 0
HW_MODE_BRINGUP = 1
HW_MODE_NAMES = {
    HW_MODE_FULL: "full",
    HW_MODE_BRINGUP: "bringup",
}
HW_MODE_VALUES = {name: value for value, name in HW_MODE_NAMES.items()}

CONTROL_CMD_START = 0x1
CONTROL_CMD_SOFT_RESET = 0x2
CONTROL_CMD_RESET_THEN_START = CONTROL_CMD_START | CONTROL_CMD_SOFT_RESET
IRQ_CTRL_ENABLE_AND_ACK = 0x3

DEFAULT_POLL_INTERVAL_S = 0.01
DEFAULT_TIMEOUT_S = 5.0
VERIFY_MODE_STRICT = 0
VERIFY_MODE_AGAVE_ZEBRA = 1

DEFAULT_PUBKEY = bytes.fromhex("c33fbaf9e0492af6ba001c65cb78c8dc2cc3f76b4c6a3eb17be941ae97eaf67f")
DEFAULT_MESSAGE = bytes.fromhex(
    "01000102c33fbaf9e0492af6ba001c65cb78c8dc2cc3f76b4c6a3eb17be941ae97eaf67f"
    "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f"
    "1111111111111111111111111111111111111111111111111111111111111111"
    "0101010002cafe"
)
DEFAULT_SIGNATURE = bytes.fromhex(
    "bcdd25ebb9e6546ea7bbfe47eb9c681b7cd94a53c6d90378c6f233662053eff8"
    "5325497ba6997d1db8b30dd6f3de4b419dd912395e81fde2a62c912581b8f80d"
)


@dataclass(frozen=True)
class RegionSpec:
    path: str
    offset: int
    size: int


@dataclass(frozen=True)
class HardwareLayout:
    control: RegionSpec
    message: RegionSpec
    job: RegionSpec


class MappedRegion:
    def __init__(self, spec: RegionSpec) -> None:
        page_size = mmap.PAGESIZE
        aligned_offset = spec.offset - (spec.offset % page_size)
        self._delta = spec.offset - aligned_offset
        self._size = spec.size
        self._fd = os.open(spec.path, os.O_RDWR | os.O_SYNC)
        self._mapping = mmap.mmap(
            self._fd,
            self._delta + self._size,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
            offset=aligned_offset,
        )

    def close(self) -> None:
        self._mapping.close()
        os.close(self._fd)

    def read_u32(self, offset: int) -> int:
        return struct.unpack_from("<I", self._mapping, self._delta + offset)[0]

    def write_u32(self, offset: int, value: int) -> None:
        struct.pack_into("<I", self._mapping, self._delta + offset, value & 0xFFFFFFFF)

    def write_bytes(self, data: bytes) -> None:
        if len(data) > self._size:
            raise ValueError(f"payload is too large for mapped region ({len(data)} > {self._size})")
        # MMIO-backed UIO mappings can fault on bulk memcpy-style writes and do
        # not support mmap.flush(); use explicit aligned word stores instead.
        offset = 0
        full_word_limit = len(data) & ~0x3
        while offset < full_word_limit:
            struct.pack_into(
                "<I",
                self._mapping,
                self._delta + offset,
                struct.unpack_from("<I", data, offset)[0],
            )
            offset += 4

        if offset < len(data):
            tail = data[offset:] + (b"\x00" * (4 - (len(data) - offset)))
            struct.pack_into("<I", self._mapping, self._delta + offset, struct.unpack("<I", tail)[0])
            offset += 4

        while offset < self._size:
            struct.pack_into("<I", self._mapping, self._delta + offset, 0)
            offset += 4


class UioInterrupt:
    def __init__(self, device_path: str) -> None:
        self._fd = os.open(device_path, os.O_RDWR)

    def close(self) -> None:
        os.close(self._fd)

    def arm(self) -> None:
        os.write(self._fd, struct.pack("<I", 1))

    def wait(self, timeout_s: float) -> int:
        ready, _, _ = select.select([self._fd], [], [], timeout_s)
        if not ready:
            raise TimeoutError(f"timed out waiting for interrupt after {timeout_s:.2f}s")
        data = os.read(self._fd, 4)
        if len(data) != 4:
            raise RuntimeError("short read from /dev/uio while waiting for interrupt")
        return struct.unpack("<I", data)[0]


def _decode_status(word: int) -> dict[str, bool]:
    return {
        "busy": bool(word & 0x1),
        "done": bool(word & 0x2),
        "error": bool(word & 0x4),
        "result_valid": bool(word & 0x8),
        "irq_pending": bool(word & 0x10),
        "config_write_ignored": bool(word & 0x20),
        "config_locked": bool(word & 0x40),
    }


def _decode_irq_status(word: int) -> dict[str, bool]:
    return {
        "enabled": bool(word & 0x1),
        "pending": bool(word & 0x2),
    }


def _read_result_mask(control: MappedRegion) -> int:
    value = 0
    for word_index in range(8):
        word = control.read_u32(REG_RESULT_MASK_BASE + (word_index * 4))
        value |= word << (word_index * 32)
    return value


def _mask_bits(mask_value: int, job_count: int) -> list[bool]:
    return [bool((mask_value >> bit) & 0x1) for bit in range(job_count)]


def _verify_mode_from_args(value: str) -> int:
    lookup = {
        "strict": VERIFY_MODE_STRICT,
        "agave": VERIFY_MODE_AGAVE_ZEBRA,
        "agave_zebra": VERIFY_MODE_AGAVE_ZEBRA,
    }
    return lookup[value]


def _decode_verify_mode(value: int) -> str:
    if value == VERIFY_MODE_STRICT:
        return "strict"
    if value == VERIFY_MODE_AGAVE_ZEBRA:
        return "agave_zebra"
    return f"unknown({value})"


def _decode_dispatch_status(word: int) -> dict[str, int]:
    return {
        "accepted_job_count": word & 0xFF,
        "current_job_index": (word >> 8) & 0xFF,
        "inflight_jobs": (word >> 16) & 0xFF,
    }


def _read_snapshot(control: MappedRegion) -> dict[str, int | bool]:
    err_status = control.read_u32(REG_SNAPSHOT_ERR_STATUS)
    return {
        "batch_id": control.read_u32(REG_SNAPSHOT_BATCH_ID),
        "accepted_job_count": control.read_u32(REG_SNAPSHOT_ACCEPTED) & 0xFF,
        "jobs_completed": control.read_u32(REG_SNAPSHOT_COMPLETED),
        "jobs_dropped": control.read_u32(REG_SNAPSHOT_DROPPED),
        "error": bool((err_status >> 8) & 0x1),
        "result_valid": bool((err_status >> 9) & 0x1),
        "error_code": err_status & 0xFF,
    }


def _build_default_batch(mode: str) -> tuple[bytes, bytes, int]:
    if mode == "valid":
        jobs = DEFAULT_PUBKEY + DEFAULT_SIGNATURE
        return DEFAULT_MESSAGE, jobs, 1

    bad_signature = bytearray(DEFAULT_SIGNATURE)
    bad_signature[0] ^= 0x01
    if mode == "invalid":
        jobs = DEFAULT_PUBKEY + bytes(bad_signature)
        return DEFAULT_MESSAGE, jobs, 1

    if mode == "pair":
        jobs = DEFAULT_PUBKEY + DEFAULT_SIGNATURE + DEFAULT_PUBKEY + bytes(bad_signature)
        return DEFAULT_MESSAGE, jobs, 2

    raise ValueError(f"unsupported default mode: {mode}")


def _load_blob(args: argparse.Namespace) -> bytes:
    if args.input_file:
        if args.input_file == "-":
            raw = sys.stdin.buffer.read()
        else:
            raw = Path(args.input_file).read_bytes()
    elif args.input:
        raw = args.input.encode("utf-8")
    else:
        raise SystemExit("either --input or --input-file is required")

    if args.encoding == "binary":
        return raw
    if args.encoding == "hex":
        return bytes.fromhex(raw.decode("utf-8").strip())
    if args.encoding == "base64":
        return base64.b64decode(raw, validate=True)
    raise SystemExit(f"unsupported encoding: {args.encoding}")


def _build_transaction_batch(args: argparse.Namespace) -> tuple[bytes, bytes, int]:
    transaction = _load_blob(args)
    parsed = mvp.parse_transaction(transaction)
    jobs = b"".join(job.pubkey + job.signature for job in parsed.jobs)
    return parsed.message_bytes, jobs, len(parsed.jobs)


def _discover_uio_region(target_addr: int, requested_size: int) -> RegionSpec | None:
    sysfs_root = Path("/sys/class/uio")
    if not sysfs_root.exists():
        return None

    for uio_dir in sorted(sysfs_root.glob("uio*")):
        addr_path = uio_dir / "maps" / "map0" / "addr"
        size_path = uio_dir / "maps" / "map0" / "size"
        if not addr_path.exists() or not size_path.exists():
            continue

        region_addr = int(addr_path.read_text().strip(), 0)
        region_size = int(size_path.read_text().strip(), 0)
        if region_addr != target_addr or region_size < requested_size:
            continue

        return RegionSpec(str(Path("/dev") / uio_dir.name), 0, requested_size)
    return None


def _resolve_region(path_value: str, offset: int, size: int) -> RegionSpec:
    if path_value != "auto":
        effective_offset = 0 if Path(path_value).name.startswith("uio") else offset
        return RegionSpec(path_value, effective_offset, size)

    discovered = _discover_uio_region(offset, size)
    if discovered is not None:
        return discovered
    return RegionSpec("/dev/mem", offset, size)


def _layout_from_args(args: argparse.Namespace) -> HardwareLayout:
    return HardwareLayout(
        control=_resolve_region(args.control_path, args.control_offset, CONTROL_SIZE),
        message=_resolve_region(args.message_path, args.message_offset, MESSAGE_SIZE),
        job=_resolve_region(args.job_path, args.job_offset, JOB_SIZE),
    )


def _wait_mode_for_layout(wait_mode: str, layout: HardwareLayout) -> str:
    control_name = Path(layout.control.path).name
    supports_irq = control_name.startswith("uio")
    if wait_mode == "auto":
        return "poll"
    if wait_mode == "irq" and not supports_irq:
        raise RuntimeError("interrupt-driven wait requires the control region to be mapped through /dev/uio")
    return wait_mode


def _decode_hw_mode(value: int) -> str:
    return HW_MODE_NAMES.get(value, f"unknown({value})")


def _probe_payload(control: MappedRegion) -> dict[str, object]:
    magic = control.read_u32(REG_HW_MAGIC)
    build = control.read_u32(REG_HW_BUILD)
    mode_value = build & 0xFF
    return {
        "magic": f"0x{magic:08x}",
        "magic_ok": magic == HW_MAGIC,
        "api_version": (build >> 8) & 0xFF,
        "hw_mode": _decode_hw_mode(mode_value),
        "hw_mode_value": mode_value,
        "build": f"0x{build:08x}",
    }


def _probe_or_raise(control: MappedRegion, expected_hw_mode: str) -> dict[str, object]:
    payload = _probe_payload(control)
    if not payload["magic_ok"]:
        raise RuntimeError(f"unexpected hardware magic {payload['magic']}; expected 0x{HW_MAGIC:08x}")
    if expected_hw_mode != "any" and payload["hw_mode"] != expected_hw_mode:
        raise RuntimeError(f"unexpected hardware mode {payload['hw_mode']}; expected {expected_hw_mode}")
    return payload


def _status_payload(control: MappedRegion, *, include_live_mask_bits: bool = True) -> dict[str, object]:
    probe = _probe_payload(control)
    status_word = control.read_u32(REG_STATUS)
    verify_cfg = control.read_u32(REG_VERIFY_CFG)
    dispatch_status = _decode_dispatch_status(control.read_u32(REG_DISPATCH_STATUS))
    mask_value = _read_result_mask(control)
    return {
        "status": _decode_status(status_word),
        "hardware": probe,
        "irq": _decode_irq_status(control.read_u32(REG_IRQ_CTRL_STATUS)),
        "message_length": control.read_u32(REG_MESSAGE_LEN) & 0xFFFF,
        "requested_job_count": control.read_u32(REG_JOB_COUNT),
        "verify_mode": _decode_verify_mode(verify_cfg & 0x3),
        "dispatch_limit": (verify_cfg >> 8) & 0xFF,
        "job_timeout_cycles": control.read_u32(REG_JOB_TIMEOUT_CYCLES),
        "dispatch_status": dispatch_status,
        "error_code": control.read_u32(REG_ERROR_CODE) & 0xFF,
        "batch_id": control.read_u32(REG_BATCH_ID),
        "result_mask_hex": f"{mask_value:064x}",
        "result_bits": _mask_bits(mask_value, dispatch_status["accepted_job_count"]) if include_live_mask_bits else [],
        "jobs_started": control.read_u32(REG_JOBS_STARTED),
        "jobs_completed": control.read_u32(REG_JOBS_COMPLETED),
        "jobs_dropped": control.read_u32(REG_JOBS_DROPPED),
        "active_cycles": control.read_u32(REG_ACTIVE_CYCLES),
        "last_job_cycles": control.read_u32(REG_LAST_JOB_CYCLES),
        "max_job_cycles": control.read_u32(REG_MAX_JOB_CYCLES),
        "last_batch_cycles": control.read_u32(REG_LAST_BATCH_CYCLES),
        "snapshot": _read_snapshot(control),
    }


def _print_probe(layout: HardwareLayout, expected_hw_mode: str) -> None:
    control = MappedRegion(layout.control)
    try:
        payload = _probe_or_raise(control, expected_hw_mode)
        payload["layout"] = {
            "control": layout.control.path,
            "message": layout.message.path,
            "job": layout.job.path,
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
    finally:
        control.close()


def _print_status(layout: HardwareLayout, expected_hw_mode: str) -> None:
    control = MappedRegion(layout.control)
    try:
        _probe_or_raise(control, expected_hw_mode)
        payload = _status_payload(control)
        payload["layout"] = {
            "control": layout.control.path,
            "message": layout.message.path,
            "job": layout.job.path,
        }
        print(json.dumps(payload, indent=2, sort_keys=True))
    finally:
        control.close()


def _run_batch(
    layout: HardwareLayout,
    message: bytes,
    jobs: bytes,
    job_count: int,
    timeout_s: float,
    verify_mode: int,
    dispatch_limit: int,
    job_timeout_cycles: int,
    wait_mode: str,
    expected_hw_mode: str,
) -> dict[str, object]:
    if len(message) > MESSAGE_SIZE:
        raise ValueError(f"message is too large for the mapped BRAM window ({len(message)} > {MESSAGE_SIZE})")
    if len(jobs) > JOB_SIZE:
        raise ValueError(f"jobs payload is too large for the mapped BRAM window ({len(jobs)} > {JOB_SIZE})")

    control = MappedRegion(layout.control)
    message_region = MappedRegion(layout.message)
    job_region = MappedRegion(layout.job)
    try:
        probe = _probe_or_raise(control, expected_hw_mode)
        message_region.write_bytes(message)
        job_region.write_bytes(jobs)
        control.write_u32(REG_MESSAGE_LEN, len(message))
        control.write_u32(REG_JOB_COUNT, job_count)
        control.write_u32(REG_VERIFY_CFG, (dispatch_limit << 8) | (verify_mode & 0x3))
        control.write_u32(REG_JOB_TIMEOUT_CYCLES, job_timeout_cycles)

        expected_batch_id = (control.read_u32(REG_BATCH_ID) + 1) & 0xFFFFFFFF
        effective_wait_mode = _wait_mode_for_layout(wait_mode, layout)
        deadline = time.monotonic() + timeout_s

        if effective_wait_mode == "irq":
            interrupt = UioInterrupt(layout.control.path)
            try:
                control.write_u32(REG_IRQ_CTRL_STATUS, IRQ_CTRL_ENABLE_AND_ACK)
                interrupt.arm()
                control.write_u32(REG_CONTROL, CONTROL_CMD_RESET_THEN_START)
                interrupt.wait(timeout_s)
                control.write_u32(REG_IRQ_CTRL_STATUS, IRQ_CTRL_ENABLE_AND_ACK)

                status_word = control.read_u32(REG_STATUS)
                status = _decode_status(status_word)
                if not (status["done"] or status["error"]):
                    while time.monotonic() < deadline:
                        status_word = control.read_u32(REG_STATUS)
                        status = _decode_status(status_word)
                        if status["done"] or status["error"]:
                            break
                    else:
                        raise TimeoutError(f"interrupt fired but completion was not visible before {timeout_s:.2f}s")
            finally:
                interrupt.close()
        else:
            control.write_u32(REG_CONTROL, CONTROL_CMD_RESET_THEN_START)
            while time.monotonic() < deadline:
                status_word = control.read_u32(REG_STATUS)
                status = _decode_status(status_word)
                if status["done"] or status["error"]:
                    break
                time.sleep(DEFAULT_POLL_INTERVAL_S)
            else:
                raise TimeoutError(f"timed out waiting for completion after {timeout_s:.2f}s")

        payload = _status_payload(control)
        payload.update(
            {
                "expected_batch_id": expected_batch_id,
                "hardware": probe,
                "requested_job_count": job_count,
                "wait_mode": effective_wait_mode,
            }
        )

        snapshot = payload["snapshot"]
        if snapshot["batch_id"] != expected_batch_id:
            raise RuntimeError(
                f"snapshot batch_id mismatch: expected {expected_batch_id}, got {snapshot['batch_id']}"
            )

        payload["status"] = _decode_status(status_word)
        payload["result_bits"] = _mask_bits(payload["result_mask_hex"] and int(payload["result_mask_hex"], 16), snapshot["accepted_job_count"])
        return payload
    finally:
        control.close()
        message_region.close()
        job_region.close()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--control-path", default="auto")
    parser.add_argument("--message-path", default="auto")
    parser.add_argument("--job-path", default="auto")
    parser.add_argument("--control-offset", type=lambda value: int(value, 0), default=CONTROL_BASE)
    parser.add_argument("--message-offset", type=lambda value: int(value, 0), default=MESSAGE_BASE)
    parser.add_argument("--job-offset", type=lambda value: int(value, 0), default=JOB_BASE)
    parser.add_argument("--wait-mode", choices=["auto", "irq", "poll"], default="poll")
    parser.add_argument("--expected-hw-mode", choices=["full", "bringup", "any"], default="full")

    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("probe", help="read only the hardware identity registers")
    subparsers.add_parser("status", help="read the control/status window")

    defaults_parser = subparsers.add_parser("run-default", help="run a built-in known-good or known-bad vector")
    defaults_parser.add_argument("--mode", choices=["valid", "invalid", "pair"], default="pair")
    defaults_parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    defaults_parser.add_argument("--verify-mode", choices=["strict", "agave", "agave_zebra"], default="strict")
    defaults_parser.add_argument("--dispatch-limit", type=int, default=0)
    defaults_parser.add_argument("--job-timeout-cycles", type=int, default=0)

    tx_parser = subparsers.add_parser("run-transaction", help="load a serialized Solana transaction")
    tx_parser.add_argument("--input")
    tx_parser.add_argument("--input-file")
    tx_parser.add_argument("--encoding", choices=["base64", "binary", "hex"], default="base64")
    tx_parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT_S)
    tx_parser.add_argument("--verify-mode", choices=["strict", "agave", "agave_zebra"], default="strict")
    tx_parser.add_argument("--dispatch-limit", type=int, default=0)
    tx_parser.add_argument("--job-timeout-cycles", type=int, default=0)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    layout = _layout_from_args(args)

    if args.command == "probe":
        _print_probe(layout, args.expected_hw_mode)
        return

    if args.command == "status":
        _print_status(layout, args.expected_hw_mode)
        return

    if args.command == "run-default":
        message, jobs, job_count = _build_default_batch(args.mode)
    elif args.command == "run-transaction":
        message, jobs, job_count = _build_transaction_batch(args)
    else:
        raise SystemExit(f"unsupported command: {args.command}")

    result = _run_batch(
        layout,
        message,
        jobs,
        job_count,
        args.timeout,
        _verify_mode_from_args(args.verify_mode),
        args.dispatch_limit,
        args.job_timeout_cycles,
        args.wait_mode,
        args.expected_hw_mode,
    )
    print(json.dumps(result, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
