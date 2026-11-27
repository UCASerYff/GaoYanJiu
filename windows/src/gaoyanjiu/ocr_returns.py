"""Protected file handoff for automatically returned GaoAction OCR results."""

from __future__ import annotations

import ctypes
import os
import re
import stat
import uuid
from contextlib import ExitStack, contextmanager
from datetime import datetime, timedelta
from functools import lru_cache
from pathlib import Path

from gaoyanjiu import BUNDLE_ID
from gaoyanjiu.errors import AppError
from gaoyanjiu.gaoaction import (
    MAX_MANIFEST_BYTES, TTL_SECONDS, decode_json, encode_json, identifier, payload_parts, read_bytes,
    validate_manifest,
)
from gaoyanjiu.timeutil import parse_iso

PROVIDER = "com.gaoseries.GaoCaoZuo"
ACTION = "ocr.files"
TICKET_LIMIT = 4096
TICKET_KEYS = {
    "schemaVersion", "requestID", "action", "sourceBundleID", "targetBundleID",
    "requestManifestSHA256", "expiresAt",
}


@lru_cache(maxsize=1)
def _file_api():
    from ctypes import wintypes as w

    class FileInformation(ctypes.Structure):
        _fields_ = [
            ("attributes", w.DWORD), ("created", w.FILETIME), ("accessed", w.FILETIME),
            ("written", w.FILETIME), ("volume", w.DWORD), ("size_high", w.DWORD), ("size_low", w.DWORD),
            ("links", w.DWORD), ("index_high", w.DWORD), ("index_low", w.DWORD),
        ]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    create = kernel.CreateFileW
    create.argtypes = (w.LPCWSTR, w.DWORD, w.DWORD, w.LPVOID, w.DWORD, w.DWORD, w.HANDLE)
    create.restype = w.HANDLE
    info = kernel.GetFileInformationByHandle
    info.argtypes = (w.HANDLE, ctypes.POINTER(FileInformation))
    info.restype = w.BOOL
    close = kernel.CloseHandle
    close.argtypes = (w.HANDLE,)
    close.restype = w.BOOL
    return create, info, close, FileInformation


@contextmanager
def _pin(path: Path, *, directory: bool, allow_children=False):
    if os.name != "nt":
        info = path.lstat()
        matches = stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode) and info.st_nlink == 1
        if not matches:
            raise AppError("unsafe_file")
        yield
        return

    create, information, close, info_type = _file_api()
    # Open the link itself. Directory publication needs write sharing for its child rename.
    share = 0x03 if directory and allow_children else 0x01
    handle = create(str(path), 0x80000000, share, None, 3, 0x02200000, None)
    if handle in {None, ctypes.c_void_p(-1).value}:
        if ctypes.get_last_error() in {2, 3}:
            raise FileNotFoundError(path)
        raise AppError("unsafe_file")
    try:
        info = info_type()
        if (not information(handle, ctypes.byref(info)) or info.attributes & 0x400
                or bool(info.attributes & 0x10) != directory or (not directory and info.links != 1)):
            raise AppError("unsafe_file")
        yield
    finally:
        close(handle)


def _pin_directory(path: Path, stack: ExitStack, *, create=False, allow_children=False) -> None:
    try:
        stack.enter_context(_pin(path, directory=True, allow_children=allow_children))
    except FileNotFoundError:
        if not create:
            raise
        path.mkdir(exist_ok=True)
        stack.enter_context(_pin(path, directory=True, allow_children=allow_children))


def _ticket(request_id: str, digest: str, expires_at: str) -> dict:
    if (request_id != identifier(request_id) or not isinstance(digest, str)
            or re.fullmatch(r"[0-9a-f]{64}", digest, re.ASCII) is None or not isinstance(expires_at, str)):
        raise AppError("invalid_manifest")
    return {
        "schemaVersion": 1, "requestID": request_id, "action": ACTION,
        "sourceBundleID": BUNDLE_ID, "targetBundleID": PROVIDER,
        "requestManifestSHA256": digest, "expiresAt": expires_at,
    }


def _current(ticket: dict, now: datetime) -> bool:
    try:
        expires = parse_iso(ticket["expiresAt"])
        return now < expires <= now + timedelta(seconds=TTL_SECONDS)
    except (ValueError, TypeError):
        return False


class OcrReturns:
    def __init__(self, root: Path | None = None):
        local = os.environ.get("LOCALAPPDATA") if os.name == "nt" else None
        self.root = Path(root) if root is not None else (
            Path(local) / "GaoSeries" / "GaoAction" / "OcrReturns-v1" if local else None
        )
        self._create_boundary = self.root if root is not None else Path(local) if local else None

    def _session(self, request_id: str, stack: ExitStack, *, create=False) -> Path:
        if request_id != identifier(request_id):
            raise AppError("invalid_manifest")
        root = self.root
        if (not root or not root.is_absolute() or any(part in {".", ".."} for part in root.parts)
                or (os.name == "nt" and re.fullmatch(r"[A-Za-z]:", root.drive, re.ASCII) is None)):
            raise AppError("unsafe_path")
        if any(part.endswith((".", " ")) or ":" in part for part in root.parts[1:]):
            raise AppError("unsafe_path")
        directory = root / request_id
        for parent in reversed(directory.parents):
            _pin_directory(parent, stack, create=(
                create and (parent == root or self._create_boundary in parent.parents)
            ), allow_children=True)
        _pin_directory(directory, stack, create=create, allow_children=True)
        return directory

    @staticmethod
    def _read_ticket(directory: Path, request_id: str, stack: ExitStack) -> dict:
        file = directory / "request.json"
        stack.enter_context(_pin(file, directory=False))
        data = decode_json(read_bytes(file, TICKET_LIMIT))
        if (not isinstance(data, dict) or data.keys() != TICKET_KEYS
                or type(data["schemaVersion"]) is not int
                or data != _ticket(request_id, data["requestManifestSHA256"], data["expiresAt"])):
            raise AppError("request_conflict", 409)
        return data

    def prepare(self, request_id: str, manifest_digest: str, expires_at: str, now: datetime) -> None:
        ticket = _ticket(request_id, manifest_digest, expires_at)
        if not _current(ticket, now):
            raise AppError("expired")
        with ExitStack() as stack:
            directory = self._session(request_id, stack, create=True)
            target = directory / "request.json"
            temporary = directory / f".request-{uuid.uuid4().hex}.tmp"
            created = False
            try:
                with temporary.open("xb") as stream:
                    created = True
                    stream.write(encode_json(ticket))
                    stream.flush()
                    os.fsync(stream.fileno())
                try:
                    if os.name == "nt":
                        temporary.rename(target)
                    else:
                        os.link(temporary, target)
                        temporary.unlink()
                except FileExistsError:
                    if self._read_ticket(directory, request_id, stack) != ticket:
                        raise AppError("request_conflict", 409) from None
            finally:
                if created:
                    temporary.unlink(missing_ok=True)

    def ticket(self, request_id: str, now: datetime) -> dict | None:
        try:
            with ExitStack() as stack:
                directory = self._session(request_id, stack)
                ticket = self._read_ticket(directory, request_id, stack)
                return ticket if _current(ticket, now) else None
        except FileNotFoundError:
            return None

    @contextmanager
    def open_result(self, request_id: str, now: datetime):
        with ExitStack() as stack:
            try:
                directory = self._session(request_id, stack)
                ticket = self._read_ticket(directory, request_id, stack)
                result = directory / "result.gaoaction"
                if _current(ticket, now):
                    self._pin_package(result, stack, now)
                    discovered = (ticket, result)
                else:
                    discovered = None
            except FileNotFoundError:
                discovered = None
            yield discovered

    @staticmethod
    def _pin_package(result: Path, stack: ExitStack, now: datetime) -> None:
        _pin_directory(result, stack)
        manifest_file = result / "manifest.json"
        stack.enter_context(_pin(manifest_file, directory=False))
        manifest, _ = validate_manifest(read_bytes(manifest_file, MAX_MANIFEST_BYTES), now)
        if manifest["kind"] != "result" or manifest["action"] != ACTION:
            raise AppError("invalid_manifest")
        if not manifest["items"]:
            return
        pinned = set()
        payload_root = result / "payload"
        _pin_directory(payload_root, stack)
        for item in manifest["items"]:
            *parents, name = payload_parts(item["relativePath"])
            directory = payload_root
            for part in parents:
                directory /= part
                if directory not in pinned:
                    _pin_directory(directory, stack)
                    pinned.add(directory)
            stack.enter_context(_pin(directory / name, directory=False))
