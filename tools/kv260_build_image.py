#!/usr/bin/env python3
"""Build, package, stage, and optionally QEMU-check the KV260 image."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shlex
import shutil
import subprocess
import zipfile
from datetime import UTC, datetime
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
FPGA_DIR = REPO_ROOT / "fpga" / "kv260_sigv"
PETALINUX_PROJECT = REPO_ROOT / "petalinux" / "kv260_sigv"
XSA_PATH = FPGA_DIR / "build" / "hw" / "kv260_sigv.xsa"
VIVADO_BIT_PATH = FPGA_DIR / "build" / "hw" / "system.bit"
HW_MODE_PATH = FPGA_DIR / "build" / "hw" / "hw_mode.txt"
IMAGES_DIR = PETALINUX_PROJECT / "images" / "linux"
DEFAULT_STAGE_DIR = REPO_ROOT / "artifacts" / "kv260_sigv"
DEFAULT_SETTINGS = Path.home() / "Xilinx" / "settings-kv260.sh"
PREPARE_PETALINUX = REPO_ROOT / "tools" / "prepare_petalinux_project.py"
DOCKER_WRAPPER = REPO_ROOT / "tools" / "kv260_petalinux_docker.sh"
QEMU_SANITY = REPO_ROOT / "tools" / "kv260_qemu_sanity.py"
REPORTS_DIR = FPGA_DIR / "build" / "hw" / "reports"
LEGACY_REPORTS_DIR = FPGA_DIR / "build" / "vivado" / "kv260_sigv.runs" / "impl_1"

STAGED_FILES = (
    "BOOT.BIN",
    "Image",
    "Image.gz",
    "bl31.elf",
    "boot.scr",
    "image.ub",
    "pmufw.elf",
    "rootfs.cpio.gz.u-boot",
    "rootfs.ext4",
    "rootfs.tar.gz",
    "system.bit",
    "system.dtb",
    "u-boot.elf",
    "zynqmp_fsbl.elf",
)
UENV_FILENAME = "uEnv.txt"
UENV_CONTENT = """initrd_high=0xffffffffffffffff
uenvcmd=fatload ${devtype} ${devnum}:${distro_bootpart} 0x30000000 system.bit && fpga loadb 0 0x30000000 ${filesize}
"""
STAGED_REPORT_FILES = (
    "timing_summary.rpt",
    "utilization.rpt",
    "clock_utilization.rpt",
)
LEGACY_REPORT_FILE_MAP = {
    "timing_summary.rpt": "kv260_sigv_bd_wrapper_timing_summary_routed.rpt",
    "utilization.rpt": "kv260_sigv_bd_wrapper_utilization_placed.rpt",
    "clock_utilization.rpt": "kv260_sigv_bd_wrapper_clock_utilization_routed.rpt",
}
VALID_HW_MODES = {"full", "bringup"}


def run(cmd: list[str], *, cwd: Path | None = None) -> None:
    subprocess.run(cmd, cwd=cwd, check=True)


def run_host_bash(command: str) -> None:
    run(["bash", "-lc", command], cwd=REPO_ROOT)


def run_docker_exec(command: str) -> None:
    run([str(DOCKER_WRAPPER), "exec", command], cwd=REPO_ROOT)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--settings", type=Path, default=DEFAULT_SETTINGS)
    parser.add_argument("--stage-dir", type=Path, default=DEFAULT_STAGE_DIR)
    parser.add_argument("--skip-bitstream", action="store_true")
    parser.add_argument("--skip-petalinux-build", action="store_true")
    parser.add_argument("--skip-qemu", action="store_true")
    parser.add_argument("--qemu-timeout", type=int, default=30)
    return parser


def current_hw_mode() -> str:
    if HW_MODE_PATH.exists():
        mode = HW_MODE_PATH.read_text().strip().lower()
    else:
        mode = "full"
    if mode not in VALID_HW_MODES:
        raise RuntimeError(f"unsupported hardware mode {mode!r}; expected one of {sorted(VALID_HW_MODES)}")
    return mode


def source_settings(settings: Path) -> str:
    return f"source {shlex.quote(str(settings))} >/dev/null 2>&1"


def strict_bash_prelude(*, nounset: bool = False) -> str:
    if nounset:
        return "set -euo pipefail"
    return "set -eo pipefail"


def ensure_bitstream(settings: Path) -> None:
    command = " && ".join(
        [
            strict_bash_prelude(),
            source_settings(settings.resolve()),
            f"make -C {shlex.quote(str(FPGA_DIR))} bitstream",
        ]
    )
    run_host_bash(command)


def petalinux_build() -> None:
    command = " && ".join(
        [
            strict_bash_prelude(),
            f"{shlex.quote(str(PREPARE_PETALINUX))} --require-xsa",
            f"cd {shlex.quote(str(PETALINUX_PROJECT))}",
            'source "$HOME/Xilinx/PetaLinux/2025.2/settings.sh" >/dev/null 2>&1',
            (
                "petalinux-config --silentconfig "
                f"--get-hw-description {shlex.quote(str(XSA_PATH))}"
            ),
            "petalinux-build",
            f"cp {shlex.quote(str(VIVADO_BIT_PATH))} images/linux/system.bit",
            (
                "petalinux-package boot --force "
                "--fsbl images/linux/zynqmp_fsbl.elf "
                "--u-boot "
                "--fpga images/linux/system.bit "
                "--pmufw images/linux/pmufw.elf "
                "--atf images/linux/bl31.elf"
            ),
        ]
    )
    run_docker_exec(command)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _read_xsa_json(xsa_path: Path) -> dict[str, object]:
    if not xsa_path.exists():
        raise FileNotFoundError(xsa_path)
    with zipfile.ZipFile(xsa_path) as archive:
        try:
            with archive.open("xsa.json") as handle:
                return json.loads(handle.read().decode("utf-8"))
        except KeyError as exc:
            raise RuntimeError(f"{xsa_path} does not contain xsa.json") from exc


def _xsa_declares_full_bitstream(xsa_json: dict[str, object]) -> bool:
    accelerator_binary_content = str(xsa_json.get("acceleratorBinaryContent", "")).lower()
    if accelerator_binary_content == "bitstream":
        return True

    files = xsa_json.get("files", [])
    if not isinstance(files, list):
        return False
    for file_entry in files:
        if not isinstance(file_entry, dict):
            continue
        if str(file_entry.get("type", "")).upper() == "FULL_BIT":
            return True
    return False


def validate_implementation_artifacts() -> dict[str, object]:
    if not VIVADO_BIT_PATH.exists() or VIVADO_BIT_PATH.stat().st_size == 0:
        raise RuntimeError(f"missing implemented Vivado bitstream: {VIVADO_BIT_PATH}")

    for report_name in STAGED_REPORT_FILES:
        report_path = REPORTS_DIR / report_name
        if not report_path.exists() or report_path.stat().st_size == 0:
            raise RuntimeError(f"missing implementation report: {report_path}")

    timing_summary = _require_timing_closed(REPORTS_DIR / "timing_summary.rpt")

    xsa_json = _read_xsa_json(XSA_PATH)
    platform_state = str(xsa_json.get("platformState", "")).lower()

    with zipfile.ZipFile(XSA_PATH) as archive:
        bit_members = [name for name in archive.namelist() if name.endswith(".bit")]
    if not bit_members:
        raise RuntimeError(f"{XSA_PATH} does not contain an included bitstream")
    if not _xsa_declares_full_bitstream(xsa_json):
        raise RuntimeError(
            f"{XSA_PATH} does not describe an implemented full-bit export "
            f"(platformState={platform_state!r})"
        )

    return {
        "hw_mode": current_hw_mode(),
        "vivado_bit": str(VIVADO_BIT_PATH),
        "vivado_bit_sha256": sha256(VIVADO_BIT_PATH),
        "xsa_sha256": sha256(XSA_PATH),
        "xsa_platform_state": xsa_json.get("platformState"),
        "xsa_bit_members": bit_members,
        "timing_summary": timing_summary,
    }


def validate_packaged_bitstream() -> dict[str, object]:
    image_bit = IMAGES_DIR / "system.bit"
    if not image_bit.exists() or image_bit.stat().st_size == 0:
        raise RuntimeError(f"missing packaged PetaLinux bitstream: {image_bit}")
    vivado_hash = sha256(VIVADO_BIT_PATH)
    image_hash = sha256(image_bit)
    if image_hash != vivado_hash:
        raise RuntimeError(
            "PetaLinux system.bit does not match the implemented Vivado bitstream "
            f"({image_bit} != {VIVADO_BIT_PATH})"
        )
    if image_bit.stat().st_mtime < VIVADO_BIT_PATH.stat().st_mtime:
        raise RuntimeError(f"packaged system.bit is older than implemented bitstream: {image_bit}")
    return {
        "system_bit": str(image_bit),
        "system_bit_sha256": image_hash,
    }


def artifact_metadata(path: Path) -> dict[str, int | str]:
    return {
        "name": path.name,
        "sha256": sha256(path),
        "size_bytes": path.stat().st_size,
    }


def stage_artifacts(stage_dir: Path) -> None:
    if stage_dir.exists():
        shutil.rmtree(stage_dir)
    stage_dir.mkdir(parents=True)

    for name in STAGED_FILES:
        src = IMAGES_DIR / name
        if not src.exists():
            raise FileNotFoundError(src)
        dst = stage_dir / name
        shutil.copy2(src, dst)

    (stage_dir / UENV_FILENAME).write_text(UENV_CONTENT)

    shutil.copy2(XSA_PATH, stage_dir / XSA_PATH.name)

    for name in STAGED_REPORT_FILES:
        preferred = REPORTS_DIR / name
        if not preferred.exists():
            raise FileNotFoundError(preferred)

    staged_reports_dir = stage_dir / "reports"
    staged_reports_dir.mkdir(exist_ok=True)
    for name in STAGED_REPORT_FILES:
        shutil.copy2(REPORTS_DIR / name, staged_reports_dir / name)


def _parse_timing_summary(report_path: Path) -> dict[str, float | int] | None:
    if not report_path.exists():
        return None

    match = re.search(
        r"^\s*([-+]?\d+\.\d+)\s+([-+]?\d+\.\d+)\s+(\d+)\s+(\d+)\s+"
        r"([-+]?\d+\.\d+)\s+([-+]?\d+\.\d+)\s+(\d+)\s+(\d+)\s+"
        r"([-+]?\d+\.\d+)\s+([-+]?\d+\.\d+)\s+(\d+)\s+(\d+)\s*$",
        report_path.read_text(),
        re.MULTILINE,
    )
    if match is None:
        return None

    return {
        "wns_ns": float(match.group(1)),
        "tns_ns": float(match.group(2)),
        "tns_failing_endpoints": int(match.group(3)),
        "tns_total_endpoints": int(match.group(4)),
        "whs_ns": float(match.group(5)),
        "ths_ns": float(match.group(6)),
        "ths_failing_endpoints": int(match.group(7)),
        "ths_total_endpoints": int(match.group(8)),
        "wpws_ns": float(match.group(9)),
        "tpws_ns": float(match.group(10)),
        "tpws_failing_endpoints": int(match.group(11)),
        "tpws_total_endpoints": int(match.group(12)),
    }


def _require_timing_closed(report_path: Path) -> dict[str, float | int]:
    timing = _parse_timing_summary(report_path)
    if timing is None:
        raise RuntimeError(f"unable to parse timing summary: {report_path}")

    failed = (
        timing["wns_ns"] < 0.0
        or timing["whs_ns"] < 0.0
        or timing["wpws_ns"] < 0.0
        or timing["tns_failing_endpoints"] != 0
        or timing["ths_failing_endpoints"] != 0
        or timing["tpws_failing_endpoints"] != 0
    )
    if failed:
        raise RuntimeError(
            "implemented Vivado bitstream failed timing closure "
            f"(WNS={timing['wns_ns']} ns, WHS={timing['whs_ns']} ns, "
            f"WPWS={timing['wpws_ns']} ns, setup_failures={timing['tns_failing_endpoints']}, "
            f"hold_failures={timing['ths_failing_endpoints']}, "
            f"pulse_width_failures={timing['tpws_failing_endpoints']})"
        )
    return timing


def _parse_utilization_summary(report_path: Path) -> dict[str, dict[str, float | int]] | None:
    if not report_path.exists():
        return None

    text = report_path.read_text()
    labels = ("CLB LUTs", "CLB Registers", "Block RAM Tile", "DSPs")
    parsed: dict[str, dict[str, float | int]] = {}
    for label in labels:
        match = re.search(
            rf"^\|\s*{re.escape(label)}\s*\|\s*(\d+)\s*\|\s*\d+\s*\|\s*\d+\s*\|\s*(\d+)\s*\|\s*([<]?\d+\.\d+)\s*\|$",
            text,
            re.MULTILINE,
        )
        if match is None:
            continue

        util_percent = match.group(3)
        parsed[label] = {
            "used": int(match.group(1)),
            "available": int(match.group(2)),
            "util_percent": float(util_percent.lstrip("<")),
        }

    return parsed or None


def write_stage_metadata(
    stage_dir: Path,
    qemu_timeout: int,
    qemu_enabled: bool,
    hardware_metadata: dict[str, object] | None = None,
) -> None:
    staged_paths = [path for path in sorted(stage_dir.rglob("*")) if path.is_file()]
    artifacts = [
        {
            **artifact_metadata(path),
            "name": str(path.relative_to(stage_dir)),
        }
        for path in staged_paths
        if path.name not in {"SHA256SUMS", "manifest.json"}
    ]
    checksums = [f"{artifact['sha256']}  {artifact['name']}" for artifact in artifacts]
    (stage_dir / "SHA256SUMS").write_text("\n".join(checksums) + "\n")

    manifest = {
        "artifacts": artifacts,
        "generated_at": datetime.now(UTC).isoformat(),
        "images_dir": str(IMAGES_DIR),
        "files": [artifact["name"] for artifact in artifacts] + ["SHA256SUMS", "manifest.json"],
        "manifest_file": "manifest.json",
        "xsa": XSA_PATH.name,
        "qemu_timeout_s": qemu_timeout,
        "qemu_enabled": qemu_enabled,
        "sha256sums_file": "SHA256SUMS",
        "stage_dir": str(stage_dir),
    }
    if hardware_metadata is not None:
        manifest["hardware"] = hardware_metadata

    staged_reports_dir = stage_dir / "reports"
    timing_summary = _parse_timing_summary(staged_reports_dir / "timing_summary.rpt")
    utilization_summary = _parse_utilization_summary(staged_reports_dir / "utilization.rpt")
    if timing_summary is not None or utilization_summary is not None:
        manifest["implementation_reports"] = {
            "timing_summary": timing_summary,
            "utilization": utilization_summary,
        }
    (stage_dir / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n")


def run_qemu_sanity(stage_dir: Path, timeout_s: int) -> None:
    run(
        [
            str(QEMU_SANITY),
            "--timeout",
            str(timeout_s),
            "--log-file",
            str(stage_dir / "qemu-sanity.raw.log"),
        ],
        cwd=REPO_ROOT,
    )


def main() -> int:
    args = build_parser().parse_args()

    if not args.skip_bitstream:
        ensure_bitstream(args.settings)
    hardware_metadata = validate_implementation_artifacts()

    if not args.skip_petalinux_build:
        petalinux_build()
    hardware_metadata = {**hardware_metadata, **validate_packaged_bitstream()}

    stage_dir = args.stage_dir.resolve()
    stage_artifacts(stage_dir)

    if not args.skip_qemu:
        run_qemu_sanity(stage_dir, args.qemu_timeout)

    write_stage_metadata(stage_dir, args.qemu_timeout, not args.skip_qemu, hardware_metadata)

    print(f"Staged KV260 artifacts in {stage_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
