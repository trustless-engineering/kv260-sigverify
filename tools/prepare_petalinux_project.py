#!/usr/bin/env python3
"""Prepare local, generated PetaLinux project metadata for this checkout."""

from __future__ import annotations

import argparse
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
PETALINUX_PROJECT = REPO_ROOT / "petalinux" / "kv260_sigv"
METADATA_PATH = PETALINUX_PROJECT / ".petalinux" / "metadata"
XSA_PATH = REPO_ROOT / "fpga" / "kv260_sigv" / "build" / "hw" / "kv260_sigv.xsa"
PETALINUX_VERSION = "2025.2"
YOCTO_SDK = "8576b661a268f6a1638f445924bb6001e14cdc81b43e38c84762381e5ff54d50"


def build_metadata_text(xsa_path: Path = XSA_PATH) -> str:
    return "\n".join(
        [
            f"PETALINUX_VER={PETALINUX_VERSION}",
            "VALIDATE_HW_CHKSUM=1",
            f"HARDWARE_PATH={xsa_path.resolve()}",
            "HDF_EXT=xsa",
            f"YOCTO_SDK={YOCTO_SDK}",
            "",
        ]
    )


def write_metadata(metadata_path: Path = METADATA_PATH, xsa_path: Path = XSA_PATH) -> None:
    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    metadata_path.write_text(build_metadata_text(xsa_path))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--metadata-path",
        type=Path,
        default=METADATA_PATH,
        help="metadata file to write",
    )
    parser.add_argument(
        "--xsa-path",
        type=Path,
        default=XSA_PATH,
        help="XSA path to record in the generated metadata",
    )
    parser.add_argument(
        "--require-xsa",
        action="store_true",
        help="fail if the XSA path does not exist",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    xsa_path = args.xsa_path.resolve()
    if args.require_xsa and not xsa_path.exists():
        raise FileNotFoundError(xsa_path)

    write_metadata(args.metadata_path, xsa_path)
    print(f"Wrote {args.metadata_path}")
    print(f"HARDWARE_PATH={xsa_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
