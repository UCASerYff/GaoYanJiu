from __future__ import annotations

import base64
import json
import re
import uuid
import zipfile
from datetime import datetime
from pathlib import Path

from gaoyanjiu import BUNDLE_ID
from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import is_regular_file, sha256_bytes
from gaoyanjiu.timeutil import parse_iso

MAX_MANIFEST_BYTES = 1_048_576
MAX_ITEMS = 256
MAX_PAYLOAD_BYTES = 2 * 1024 * 1024 * 1024
TTL_SECONDS = 120.001
ALLOWED_KEYS = {
    "schemaVersion",
    "kind",
    "requestID",
    "sourceBundleID",
    "targetBundleID",
    "action",
    "createdAt",
    "expiresAt",
    "nonce",
    "items",
    "references",
    "parameters",
    "inReplyTo",
    "status",
    "errorCode",
    "provenance",
}
UUID_RE = re.compile(r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$")
BUNDLE_RE = re.compile(r"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$")
SHA_RE = re.compile(r"^[A-Fa-f0-9]{64}$")
PAYLOAD_RE = re.compile(r"^payload/(?:[^/\\\x00]+/)*[^/\\\x00]+$")


def _unique_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise AppError("invalid_manifest")
        obj[key] = value
    return obj


def _loads(data: bytes):
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_unique_object)
    except (UnicodeError, json.JSONDecodeError, AppError) as exc:
        if isinstance(exc, AppError):
            raise
        raise AppError("invalid_manifest") from exc


def _is_uuid(value: str) -> bool:
    if not isinstance(value, str) or UUID_RE.match(value) is None:
        return False
    try:
        uuid.UUID(value)
    except ValueError:
        return False
    return True


def validate_import_manifest(data: bytes, now: datetime) -> tuple[dict, str]:
    if len(data) > MAX_MANIFEST_BYTES:
        raise AppError("payload_too_large")
    manifest = _loads(data)
    if not isinstance(manifest, dict) or not set(manifest).issubset(ALLOWED_KEYS):
        raise AppError("invalid_manifest")
    if manifest.get("schemaVersion") != 1:
        raise AppError("unsupported_version")
    if manifest.get("targetBundleID") != BUNDLE_ID:
        raise AppError("wrong_target")
    if not _is_uuid(str(manifest.get("requestID") or "")):
        raise AppError("invalid_manifest")
    source = manifest.get("sourceBundleID")
    target = manifest.get("targetBundleID")
    if not isinstance(source, str) or not isinstance(target, str):
        raise AppError("invalid_manifest")
    if len(source.encode("utf-8")) > 255 or len(target.encode("utf-8")) > 255:
        raise AppError("invalid_manifest")
    if BUNDLE_RE.match(source) is None or BUNDLE_RE.match(target) is None:
        raise AppError("invalid_manifest")
    if manifest.get("kind") != "request":
        raise AppError("invalid_manifest")
    if manifest.get("action") != "research.importDocuments":
        raise AppError("unknown_action")
    nonce = manifest.get("nonce")
    if not isinstance(nonce, str):
        raise AppError("invalid_nonce")
    try:
        raw_nonce = base64.b64decode(nonce, validate=True)
    except Exception as exc:
        raise AppError("invalid_nonce") from exc
    if len(raw_nonce) != 32 or base64.b64encode(raw_nonce).decode("ascii") != nonce:
        raise AppError("invalid_nonce")
    try:
        created = parse_iso(str(manifest.get("createdAt") or ""))
        expires = parse_iso(str(manifest.get("expiresAt") or ""))
    except ValueError as exc:
        raise AppError("expired") from exc
    if created > now or expires <= now or expires <= created or (expires - created).total_seconds() > TTL_SECONDS:
        raise AppError("expired")
    if manifest.get("inReplyTo") is not None or manifest.get("status") is not None:
        raise AppError("invalid_manifest")
    if manifest.get("errorCode") is not None or manifest.get("provenance") is not None:
        raise AppError("invalid_manifest")
    parameters = manifest.get("parameters")
    if parameters != {}:
        raise AppError("invalid_parameters")
    items = manifest.get("items")
    references = manifest.get("references")
    if not isinstance(items, list) or not items or not isinstance(references, list) or references:
        raise AppError("invalid_parameters")
    if len(items) > MAX_ITEMS:
        raise AppError("too_many_items")
    seen_ids = set()
    seen_paths = set()
    total = 0
    for item in items:
        if not isinstance(item, dict):
            raise AppError("invalid_manifest")
        item_id = item.get("id")
        relative = item.get("relativePath")
        uti = item.get("uti")
        byte_count = item.get("byteCount")
        digest = item.get("sha256")
        if not isinstance(item_id, str) or not item_id or len(item_id.encode("utf-8")) > 256:
            raise AppError("invalid_manifest")
        if item_id in seen_ids:
            raise AppError("invalid_manifest")
        seen_ids.add(item_id)
        if not isinstance(relative, str) or relative in seen_paths or PAYLOAD_RE.match(relative) is None:
            raise AppError("unsafe_path")
        if len(relative.encode("utf-8")) > 4096:
            raise AppError("unsafe_path")
        parts = relative.split("/")
        if any(part in {"", ".", ".."} or len(part.encode("utf-8")) > 255 for part in parts):
            raise AppError("unsafe_path")
        seen_paths.add(relative)
        if not isinstance(uti, str) or not uti or len(uti.encode("utf-8")) > 256:
            raise AppError("invalid_manifest")
        if uti in {
            "public.folder",
            "public.directory",
            "com.apple.package",
            "com.apple.application-bundle",
            "com.apple.application",
        }:
            raise AppError("invalid_parameters")
        if isinstance(byte_count, bool) or not isinstance(byte_count, int) or byte_count < 0:
            raise AppError("invalid_manifest")
        if not isinstance(digest, str) or SHA_RE.match(digest) is None:
            raise AppError("invalid_manifest")
        total += byte_count
        if total > MAX_PAYLOAD_BYTES:
            raise AppError("payload_too_large")
    return manifest, sha256_bytes(data)


def _read_member(package: Path, relative: str) -> bytes:
    parts = relative.split("/")
    current = package
    for part in parts:
        current = current / part
        if current.is_symlink():
            raise AppError("unsafe_path")
    if not is_regular_file(current):
        raise AppError("unsafe_file")
    return current.read_bytes()


def _open_package(package: Path) -> tuple[Path, dict[str, bytes] | None]:
    if package.is_symlink():
        raise AppError("unsafe_file")
    if package.is_dir():
        if package.suffix.lower() != ".gaoaction":
            raise AppError("invalid_manifest")
        return package, None
    if package.is_file() and package.suffix.lower() in {".gaoaction", ".zip"}:
        try:
            archive = zipfile.ZipFile(package)
        except zipfile.BadZipFile as exc:
            raise AppError("invalid_manifest") from exc
        names = {}
        for info in archive.infolist():
            name = info.filename.replace("\\", "/")
            if name.endswith("/"):
                continue
            if name.startswith("/") or ".." in name.split("/"):
                raise AppError("unsafe_path")
            names[name] = archive.read(info)
        return package, names
    raise AppError("invalid_manifest")


def load_package(package: Path, now: datetime) -> tuple[dict, str, list[tuple[dict, bytes]]]:
    root, zipped = _open_package(package)
    if zipped is None:
        manifest_path = root / "manifest.json"
        if not is_regular_file(manifest_path):
            raise AppError("invalid_manifest")
        data = manifest_path.read_bytes()
        manifest, digest = validate_import_manifest(data, now)
        staged = []
        for item in manifest["items"]:
            payload = _read_member(root, item["relativePath"])
            if len(payload) != item["byteCount"]:
                raise AppError("byte_count_mismatch")
            if sha256_bytes(payload) != item["sha256"].lower():
                raise AppError("checksum_mismatch")
            staged.append((item, payload))
        return manifest, digest, staged
    manifest_name = "manifest.json"
    if manifest_name not in zipped:
        prefixed = [name for name in zipped if name.endswith("/manifest.json")]
        if len(prefixed) != 1:
            raise AppError("invalid_manifest")
        manifest_name = prefixed[0]
    prefix = manifest_name[: -len("manifest.json")]
    data = zipped[manifest_name]
    manifest, digest = validate_import_manifest(data, now)
    staged = []
    for item in manifest["items"]:
        name = prefix + item["relativePath"]
        if name not in zipped:
            raise AppError("unsafe_file")
        payload = zipped[name]
        if len(payload) != item["byteCount"]:
            raise AppError("byte_count_mismatch")
        if sha256_bytes(payload) != item["sha256"].lower():
            raise AppError("checksum_mismatch")
        staged.append((item, payload))
    return manifest, digest, staged
