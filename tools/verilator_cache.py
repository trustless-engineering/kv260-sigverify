from __future__ import annotations

import hashlib
import subprocess
from pathlib import Path
from typing import Iterable


def _normalize_paths(paths: Iterable[Path]) -> list[Path]:
    return sorted(Path(path).resolve(strict=False) for path in paths)


def _probe_verilator_version() -> str:
    try:
        completed = subprocess.run(
            ["verilator", "--version"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return "verilator-unavailable"
    if completed.returncode != 0:
        return "verilator-unavailable"
    version = completed.stdout.strip() or completed.stderr.strip()
    return version or "verilator-unavailable"


def build_verilator_cache_key(
    tb_source: str,
    source_paths: Iterable[Path],
    include_dirs: Iterable[Path],
) -> str:
    normalized_sources = _normalize_paths(source_paths)
    normalized_include_dirs = _normalize_paths(include_dirs)
    h = hashlib.sha256()
    h.update(b"tb_source\0")
    h.update(tb_source.encode("utf-8"))
    h.update(b"\0source_paths\0")
    for source_path in normalized_sources:
        h.update(str(source_path).encode("utf-8"))
        h.update(b"\0")
        h.update(source_path.read_bytes())
        h.update(b"\0")
    h.update(b"include_dirs\0")
    for include_dir in normalized_include_dirs:
        h.update(str(include_dir).encode("utf-8"))
        h.update(b"\0")
    h.update(b"include_headers\0")
    for include_dir in normalized_include_dirs:
        if not include_dir.is_dir():
            continue
        for header_path in sorted(include_dir.rglob("*.vh")):
            normalized_header = header_path.resolve(strict=False)
            h.update(str(normalized_header).encode("utf-8"))
            h.update(b"\0")
            h.update(normalized_header.read_bytes())
            h.update(b"\0")
    h.update(b"verilator_version\0")
    h.update(_probe_verilator_version().encode("utf-8"))
    return h.hexdigest()
