from __future__ import annotations

import hashlib
import os
import stat
from pathlib import Path

from gaoyanjiu.errors import AppError


def is_regular_file(path: Path) -> bool:
    try:
        info = path.lstat()
    except OSError:
        return False
    if stat.S_ISLNK(info.st_mode):
        return False
    return stat.S_ISREG(info.st_mode)


def read_regular_bytes(path: Path, maximum: int) -> bytes:
    if not is_regular_file(path):
        raise AppError("unsafe_file")
    size = path.lstat().st_size
    if size < 0 or size > maximum:
        raise AppError("payload_too_large")
    with path.open("rb") as handle:
        data = handle.read(maximum + 1)
    if len(data) > maximum:
        raise AppError("payload_too_large")
    if len(data) != size:
        raise AppError("checksum_mismatch")
    return data


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".write-{os.getpid()}-{path.name}")
    try:
        with temporary.open("wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if temporary.exists():
            temporary.unlink()


def safe_component(value: str) -> str:
    if (
        not value
        or value in {".", ".."}
        or "/" in value
        or "\\" in value
        or "\x00" in value
        or len(value.encode("utf-8")) > 255
    ):
        raise AppError("unsafe_path")
    return value


def contained(root: Path, path: Path) -> Path:
    root_resolved = root.resolve()
    candidate = path.resolve()
    if candidate != root_resolved and root_resolved not in candidate.parents:
        raise AppError("unsafe_path")
    return candidate
