#!/usr/bin/env python3
"""Enable the KV260 sigverify PL0 reference clock from Linux userspace."""

from __future__ import annotations

import argparse
import json
import mmap
import os
import struct
from dataclasses import dataclass


CRL_APB_BASE = 0xFF5E0000
CRL_APB_SIZE = 0x1000
PL0_REF_CTRL_OFFSET = 0x00C0
PL0_REF_CTRL_MASK = 0x013F3F07
PL0_REF_CTRL_VALUE = 0x01010F00


@dataclass(frozen=True)
class RegisterUpdate:
    address: int
    mask: int
    value: int


def _read_u32(mapping: mmap.mmap, offset: int) -> int:
    return struct.unpack_from("<I", mapping, offset)[0]


def _write_u32(mapping: mmap.mmap, offset: int, value: int) -> None:
    struct.pack_into("<I", mapping, offset, value & 0xFFFFFFFF)


def apply_update(update: RegisterUpdate, *, dry_run: bool) -> dict[str, int | bool]:
    page_size = mmap.PAGESIZE
    aligned_base = update.address & ~(page_size - 1)
    register_offset = update.address - aligned_base
    map_size = ((register_offset + 4 + page_size - 1) // page_size) * page_size

    fd = os.open("/dev/mem", os.O_RDWR | os.O_SYNC)
    try:
        mapping = mmap.mmap(
            fd,
            map_size,
            flags=mmap.MAP_SHARED,
            prot=mmap.PROT_READ | mmap.PROT_WRITE,
            offset=aligned_base,
        )
        try:
            before = _read_u32(mapping, register_offset)
            after = (before & ~update.mask) | update.value
            changed = before != after
            if changed and not dry_run:
                _write_u32(mapping, register_offset, after)
                verify = _read_u32(mapping, register_offset)
            else:
                verify = before
            return {
                "address": update.address,
                "before": before,
                "after": after,
                "verify": verify,
                "changed": changed,
                "applied": changed and not dry_run,
            }
        finally:
            mapping.close()
    finally:
        os.close(fd)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true", help="report the intended write without applying it")
    parser.add_argument("--quiet", action="store_true", help="suppress JSON output on success")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    result = apply_update(
        RegisterUpdate(
            address=CRL_APB_BASE + PL0_REF_CTRL_OFFSET,
            mask=PL0_REF_CTRL_MASK,
            value=PL0_REF_CTRL_VALUE,
        ),
        dry_run=args.dry_run,
    )
    if result["verify"] != result["after"]:
        raise SystemExit(
            f"failed to program PL0_REF_CTRL: expected 0x{result['after']:08x}, got 0x{result['verify']:08x}"
        )
    if not args.quiet:
        print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
