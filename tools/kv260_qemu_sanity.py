#!/usr/bin/env python3
"""Run a non-hardware KV260 boot sanity check under PetaLinux QEMU."""

from __future__ import annotations

import argparse
import shlex
import subprocess
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PROJECT_DIR = REPO_ROOT / "petalinux" / "kv260_sigv"
DEFAULT_DOCKER_WRAPPER = REPO_ROOT / "tools" / "kv260_petalinux_docker.sh"
DEFAULT_ROOTFS = "images/linux/rootfs.cpio.gz.u-boot"
DEFAULT_TIMEOUT_S = 30
DEFAULT_MARKERS = (
    "Starting kernel ...",
    "Run /init as init process",
    "systemd[1]: systemd ",
)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project-dir", type=Path, default=DEFAULT_PROJECT_DIR)
    parser.add_argument("--docker-wrapper", type=Path, default=DEFAULT_DOCKER_WRAPPER)
    parser.add_argument("--rootfs", default=DEFAULT_ROOTFS)
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT_S)
    parser.add_argument("--log-file", type=Path)
    parser.add_argument("--marker", action="append", default=list(DEFAULT_MARKERS))
    return parser


def build_inner_command(project_dir: Path, rootfs: str, timeout_s: int) -> str:
    rootfs_arg = rootfs
    if not Path(rootfs).is_absolute():
        rootfs_arg = rootfs

    return " && ".join(
        [
            "set -euo pipefail",
            f"cd {shlex.quote(str(project_dir))}",
            'source "$HOME/Xilinx/PetaLinux/2025.2/settings.sh" >/dev/null 2>&1',
            (
                f"timeout --signal=INT {timeout_s}s "
                f"petalinux-boot qemu --kernel --rootfs {shlex.quote(rootfs_arg)} --qemu-no-gdb"
            ),
        ]
    )


def clean_timeout_noise(output: str, timed_out: bool) -> str:
    if not timed_out:
        return output

    timeout_markers = [
        "\nTraceback (most recent call last):",
        "\nqemu-system-microblazeel: terminating on signal",
    ]
    cleaned = output
    for marker in timeout_markers:
        index = cleaned.find(marker)
        if index != -1:
            cleaned = cleaned[:index]
    return cleaned.rstrip() + ("\n" if cleaned.strip() else "")


def main() -> int:
    args = build_parser().parse_args()

    command = [
        str(args.docker_wrapper),
        "exec",
        build_inner_command(args.project_dir.resolve(), args.rootfs, args.timeout),
    ]
    completed = subprocess.run(command, capture_output=True, text=True, cwd=REPO_ROOT)
    raw_output = completed.stdout
    if completed.stderr:
        raw_output += completed.stderr

    if args.log_file:
        args.log_file.parent.mkdir(parents=True, exist_ok=True)
        args.log_file.write_text(raw_output)

    timed_out = completed.returncode == 124
    cleaned_output = clean_timeout_noise(raw_output, timed_out)
    if cleaned_output:
        sys.stdout.write(cleaned_output)
        if not cleaned_output.endswith("\n"):
            sys.stdout.write("\n")

    missing = [marker for marker in args.marker if marker not in raw_output]
    if missing:
        sys.stderr.write("QEMU sanity check failed. Missing boot markers:\n")
        for marker in missing:
            sys.stderr.write(f"  - {marker}\n")
        if args.log_file:
            sys.stderr.write(f"Raw log: {args.log_file}\n")
        return 1

    if completed.returncode not in (0, 124):
        sys.stderr.write(f"QEMU sanity check failed with exit code {completed.returncode}.\n")
        if args.log_file:
            sys.stderr.write(f"Raw log: {args.log_file}\n")
        return completed.returncode

    sys.stderr.write("QEMU sanity check passed.\n")
    if args.log_file:
        sys.stderr.write(f"Raw log: {args.log_file}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
