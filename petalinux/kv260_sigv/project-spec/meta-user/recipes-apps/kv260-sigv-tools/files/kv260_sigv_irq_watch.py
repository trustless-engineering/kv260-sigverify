#!/usr/bin/env python3
"""Safe UIO-only interrupt watcher for the KV260 sigverify shell."""

from __future__ import annotations

import argparse
import json
import os
import select
import struct
import time
from dataclasses import dataclass
from pathlib import Path


CONTROL_BASE = 0xA0000000
CONTROL_UIO_NAME = "kv260_sigv_top@a0000000"


@dataclass(frozen=True)
class UioSpec:
    device_path: str
    name: str


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


def discover_control_uio(target_addr: int, target_name: str) -> UioSpec:
    sysfs_root = Path("/sys/class/uio")
    if not sysfs_root.exists():
        raise FileNotFoundError("/sys/class/uio")

    for uio_dir in sorted(sysfs_root.glob("uio*")):
        name = (uio_dir / "name").read_text().strip()
        addr = int((uio_dir / "maps" / "map0" / "addr").read_text().strip(), 0)
        if name == target_name or addr == target_addr:
            return UioSpec(str(Path("/dev") / uio_dir.name), name)

    raise RuntimeError(
        f"failed to locate control UIO region for {target_name!r} at 0x{target_addr:08x}"
    )


def proc_interrupt_total(name: str) -> tuple[int | None, str | None]:
    for line in Path("/proc/interrupts").read_text().splitlines():
        if name not in line:
            continue
        counts = []
        for token in line.split(":", 1)[1].split():
            if token.isdigit():
                counts.append(int(token))
            else:
                break
        return sum(counts), line.strip()
    return None, None


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=4)
    parser.add_argument("--timeout", type=float, default=2.0)
    parser.add_argument("--pause", type=float, default=0.0)
    parser.add_argument("--control-name", default=CONTROL_UIO_NAME)
    parser.add_argument("--control-base", type=lambda value: int(value, 0), default=CONTROL_BASE)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.samples <= 0:
        raise SystemExit("--samples must be greater than zero")
    if args.timeout <= 0:
        raise SystemExit("--timeout must be greater than zero")

    spec = discover_control_uio(args.control_base, args.control_name)
    before_total, before_line = proc_interrupt_total(spec.name)
    watcher = UioInterrupt(spec.device_path)
    events: list[dict[str, int | None | str]] = []

    try:
        previous_total = before_total
        for sample_index in range(args.samples):
            watcher.arm()
            event_count = watcher.wait(args.timeout)
            current_total, current_line = proc_interrupt_total(spec.name)
            if args.pause > 0:
                time.sleep(args.pause)
            events.append(
                {
                    "sample": sample_index,
                    "event_count": event_count,
                    "proc_interrupt_total": current_total,
                    "proc_interrupt_delta": (
                        None
                        if current_total is None or previous_total is None
                        else current_total - previous_total
                    ),
                    "proc_interrupt_line": current_line,
                }
            )
            previous_total = current_total
    finally:
        watcher.close()

    after_total, after_line = proc_interrupt_total(spec.name)
    payload = {
        "ok": True,
        "uio_device": spec.device_path,
        "uio_name": spec.name,
        "proc_interrupts_before": before_total,
        "proc_interrupts_before_line": before_line,
        "proc_interrupts_after": after_total,
        "proc_interrupts_after_line": after_line,
        "events": events,
    }
    print(json.dumps(payload, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
