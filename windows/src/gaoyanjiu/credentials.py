from __future__ import annotations

import base64
import ctypes
import os
import sys
from pathlib import Path

from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import atomic_write, safe_component


def _identity_protect(data: bytes) -> bytes:
    return b"PY1:" + base64.b64encode(data)


def _identity_unprotect(data: bytes) -> bytes:
    if not data.startswith(b"PY1:"):
        raise AppError("unreadable")
    return base64.b64decode(data[4:])


def _dpapi_protect(data: bytes) -> bytes:
    blob = _crypt(data, protect=True)
    return b"DPAPI:" + blob


def _dpapi_unprotect(data: bytes) -> bytes:
    if not data.startswith(b"DPAPI:"):
        raise AppError("unreadable")
    return _crypt(data[6:], protect=False)


def _crypt(data: bytes, protect: bool) -> bytes:
    class DATA_BLOB(ctypes.Structure):
        _fields_ = [("cbData", ctypes.c_ulong), ("pbData", ctypes.POINTER(ctypes.c_byte))]

    crypt32 = ctypes.windll.crypt32
    kernel32 = ctypes.windll.kernel32
    buffer = ctypes.create_string_buffer(data)
    source = DATA_BLOB(len(data), ctypes.cast(buffer, ctypes.POINTER(ctypes.c_byte)))
    result = DATA_BLOB()
    function = crypt32.CryptProtectData if protect else crypt32.CryptUnprotectData
    ok = function(
        ctypes.byref(source),
        None,
        None,
        None,
        None,
        0,
        ctypes.byref(result),
    )
    if not ok:
        raise AppError("unreadable")
    try:
        return ctypes.string_at(result.pbData, result.cbData)
    finally:
        kernel32.LocalFree(result.pbData)


def platform_protect(data: bytes) -> bytes:
    if sys.platform == "win32":
        return _dpapi_protect(data)
    return _identity_protect(data)


def platform_unprotect(data: bytes) -> bytes:
    if data.startswith(b"DPAPI:") and sys.platform == "win32":
        return _dpapi_unprotect(data)
    if data.startswith(b"PY1:"):
        return _identity_unprotect(data)
    if data.startswith(b"DPAPI:"):
        raise AppError("unreadable")
    raise AppError("unreadable")


class SecretStore:
    """门户密码和 EasyScholar 密钥不进入 library.json。

    Windows 上使用 DPAPI。其他系统只用于开发测试，文件权限收紧到当前用户。
    """

    def __init__(self, root: Path, protect=None, unprotect=None):
        self.root = Path(root) / "secrets"
        self.protect = protect or platform_protect
        self.unprotect = unprotect or platform_unprotect

    def _path(self, name: str) -> Path:
        parts = name.split("/")
        if not parts or any(part in {"", ".", ".."} for part in parts):
            raise AppError("unsafe_path")
        current = self.root
        for part in parts:
            current = current / safe_component(part)
        return current

    def set(self, name: str, value: str) -> None:
        path = self._path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        atomic_write(path, self.protect(value.encode("utf-8")))
        try:
            os.chmod(path, 0o600)
        except OSError:
            pass

    def get(self, name: str) -> str:
        path = self._path(name)
        if not path.exists():
            return ""
        return self.unprotect(path.read_bytes()).decode("utf-8")

    def delete(self, name: str) -> None:
        path = self._path(name)
        if path.exists():
            path.unlink()

    def exists(self, name: str) -> bool:
        return self._path(name).exists()
