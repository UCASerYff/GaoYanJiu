from __future__ import annotations

import base64
import json
import os
import re
import stat
import uuid
import zipfile
from datetime import datetime, timedelta
from pathlib import Path

from gaoyanjiu import BUNDLE_ID
from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import sha256_bytes
from gaoyanjiu.timeutil import format_iso, parse_iso

MAX_MANIFEST_BYTES = 1_048_576
MAX_ITEMS = 256
MAX_PAYLOAD_BYTES = 2 * 1024 * 1024 * 1024
MAX_FILE_BYTES = 512 * 1024 * 1024
TTL_SECONDS = 120.001
WINDOWS_RESEARCH_ID = "com.gaoseries.GaoYanJiu"
BASE_KEYS = {
    "schemaVersion", "kind", "requestID", "sourceBundleID", "targetBundleID",
    "action", "createdAt", "expiresAt", "nonce", "items", "references", "parameters",
}
RESULT_KEYS = {"inReplyTo", "status", "errorCode", "provenance"}
STATUSES = {"pending", "completed", "partial", "cancelled", "failed", "unsupported"}
ACTIONS = {"research.importDocuments", "ocr.files", "files.choose", "documents.open"}
FORBIDDEN_KEYS = {
    "shell", "script", "command", "argv", "callbackurl", "browserarguments", "elevate", "sudo", "password", "cookie",
}
UUID_RE = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", re.I | re.ASCII)
BUNDLE_RE = re.compile(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", re.ASCII)
SHA_RE = re.compile(r"[a-f0-9]{64}", re.I | re.ASCII)
DEVICE_RE = re.compile(r"(?:CON|PRN|AUX|NUL|CONIN\$|CONOUT\$|COM[1-9¹²³]|LPT[1-9¹²³])", re.I)


def _unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise AppError("invalid_manifest")
        result[key] = value
    return result


def _invalid_constant(value):
    raise ValueError(value)


def decode_json(data: bytes):
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_unique_object, parse_constant=_invalid_constant)
    except (UnicodeError, ValueError, RecursionError) as exc:
        raise AppError("invalid_manifest") from exc


def encode_json(data: dict, canonical: bool = False) -> bytes:
    return json.dumps(data, ensure_ascii=False, allow_nan=False, sort_keys=canonical, separators=(",", ":")).encode("utf-8")


def identifier(value) -> str:
    if not isinstance(value, str) or not UUID_RE.fullmatch(value):
        raise AppError("invalid_manifest")
    return str(uuid.UUID(value))


def digest_value(value) -> bool:
    return isinstance(value, str) and SHA_RE.fullmatch(value) is not None


def safe_parts(value: str) -> tuple[str, ...]:
    if not isinstance(value, str) or len(value.encode("utf-8")) > 4096:
        raise AppError("unsafe_path")
    parts = tuple(value.split("/"))
    for part in parts:
        if (
            not part or part in {".", ".."} or part[-1] in " ."
            or len(part.encode("utf-8")) > 255
            or any(ord(character) < 32 or character in '\\:<>"|?*' for character in part)
            or DEVICE_RE.fullmatch(part.split(".", 1)[0])
        ):
            raise AppError("unsafe_path")
    return parts


def payload_parts(value: str) -> tuple[str, ...]:
    parts = safe_parts(value)
    if parts[0] == "payload" and len(parts) > 1:
        return parts[1:]
    return parts


def _strings(value, limit: int) -> bool:
    return (
        isinstance(value, list) and 0 < len(value) <= limit
        and all(isinstance(item, str) and item and len(item.encode("utf-8")) <= 256 and "\0" not in item for item in value)
        and len(set(value)) == len(value)
    )


def _reject_executable_keys(value) -> None:
    if isinstance(value, dict):
        if any(key.casefold() in FORBIDDEN_KEYS for key in value):
            raise AppError("invalid_parameters")
        for child in value.values():
            _reject_executable_keys(child)
    elif isinstance(value, list):
        for child in value:
            _reject_executable_keys(child)


def fresh(manifest: dict, now: datetime) -> None:
    try:
        created, expires = (parse_iso(manifest[key]) for key in ("createdAt", "expiresAt"))
    except (KeyError, TypeError, ValueError, AttributeError) as exc:
        raise AppError("expired") from exc
    if not created <= now < expires or not 0 < (expires - created).total_seconds() <= TTL_SECONDS:
        raise AppError("expired")


def envelope(kind: str, action: str, source: str, target: str, now: datetime, parameters: dict) -> dict:
    return {
        "schemaVersion": 1, "kind": kind, "requestID": str(uuid.uuid4()),
        "sourceBundleID": source, "targetBundleID": target, "action": action,
        "createdAt": format_iso(now), "expiresAt": format_iso(now + timedelta(seconds=120)),
        "nonce": base64.b64encode(os.urandom(32)).decode("ascii"),
        "items": [], "references": [], "parameters": parameters,
    }


def _validate_parameters(action: str, parameters: dict) -> None:
    if not isinstance(parameters, dict):
        raise AppError("invalid_parameters")
    if action == "files.choose":
        if (
            set(parameters) - {"multiple", "allowedUTIs"}
            or ("multiple" in parameters and type(parameters["multiple"]) is not bool)
            or ("allowedUTIs" in parameters and not _strings(parameters["allowedUTIs"], 256))
        ):
            raise AppError("invalid_parameters")
    elif action == "ocr.files":
        if set(parameters) - {"languages", "outputs"}:
            raise AppError("invalid_parameters")
        if "languages" in parameters and (
            not _strings(parameters["languages"], 256)
            or any(not re.fullmatch(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*", language) for language in parameters["languages"])
        ):
            raise AppError("invalid_parameters")
        if "outputs" in parameters and (
            not _strings(parameters["outputs"], 4)
            or set(parameters["outputs"]) - {"text", "markdown", "json", "searchablePDF"}
        ):
            raise AppError("invalid_parameters")
    elif parameters:
        raise AppError("invalid_parameters")


def validate_manifest(data: bytes, now: datetime) -> tuple[dict, str]:
    if len(data) > MAX_MANIFEST_BYTES:
        raise AppError("payload_too_large")
    manifest = decode_json(data)
    if not isinstance(manifest, dict) or not BASE_KEYS <= set(manifest) <= BASE_KEYS | RESULT_KEYS:
        raise AppError("invalid_manifest")
    if type(manifest["schemaVersion"]) is not int or manifest["schemaVersion"] != 1:
        raise AppError("unsupported_version")
    identifier(manifest["requestID"])
    for bundle_id in (manifest["sourceBundleID"], manifest["targetBundleID"]):
        if not isinstance(bundle_id, str) or len(bundle_id) > 255 or not BUNDLE_RE.fullmatch(bundle_id):
            raise AppError("invalid_manifest")
    kind, action = manifest["kind"], manifest["action"]
    if kind not in ("request", "result"):
        raise AppError("invalid_manifest")
    if not isinstance(action, str) or action not in ACTIONS:
        raise AppError("unknown_action")
    expected = {BUNDLE_ID}
    if kind == "request" and action == "research.importDocuments":
        expected.add(WINDOWS_RESEARCH_ID)
    if manifest["targetBundleID"] not in expected:
        raise AppError("wrong_target")
    if kind == "request" and action != "research.importDocuments":
        raise AppError("unknown_action")
    nonce = manifest["nonce"]
    if not isinstance(nonce, str):
        raise AppError("invalid_nonce")
    try:
        raw_nonce = base64.b64decode(nonce, validate=True)
    except (ValueError, UnicodeError) as exc:
        raise AppError("invalid_nonce") from exc
    if len(raw_nonce) != 32 or base64.b64encode(raw_nonce).decode("ascii") != nonce:
        raise AppError("invalid_nonce")
    fresh(manifest, now)
    if kind == "result":
        identifier(manifest.get("inReplyTo"))
        if manifest.get("status") not in tuple(STATUSES) or not isinstance(manifest.get("provenance"), dict):
            raise AppError("invalid_manifest")
        code = manifest.get("errorCode")
        if code is not None and (not isinstance(code, str) or not code or len(code) > 256):
            raise AppError("invalid_manifest")
        try:
            _reject_executable_keys(manifest["provenance"])
        except RecursionError as exc:
            raise AppError("invalid_manifest") from exc
    elif any(manifest.get(field) is not None for field in RESULT_KEYS):
        raise AppError("invalid_manifest")
    _validate_parameters(action, manifest["parameters"])
    items, references = manifest["items"], manifest["references"]
    if not isinstance(items, list) or not isinstance(references, list):
        raise AppError("invalid_parameters")
    if len(items) + len(references) > MAX_ITEMS:
        raise AppError("too_many_items")
    if kind == "request" and (not items or references):
        raise AppError("invalid_parameters")
    if references and action != "files.choose":
        raise AppError("invalid_parameters")
    seen_ids, seen_paths = set(), set()
    total = 0
    for item in items:
        if not isinstance(item, dict) or set(item) != {"id", "relativePath", "uti", "byteCount", "sha256"}:
            raise AppError("invalid_manifest")
        item_id, uti, count = item["id"], item["uti"], item["byteCount"]
        if not isinstance(item_id, str) or not item_id or len(item_id.encode("utf-8")) > 256 or item_id in seen_ids:
            raise AppError("invalid_manifest")
        seen_ids.add(item_id)
        path_key = "/".join(payload_parts(item["relativePath"])).casefold()
        if path_key in seen_paths:
            raise AppError("unsafe_path")
        seen_paths.add(path_key)
        if not isinstance(uti, str) or not uti or len(uti.encode("utf-8")) > 256:
            raise AppError("invalid_manifest")
        if uti in {"public.folder", "public.directory", "com.apple.package", "com.apple.application-bundle", "com.apple.application"}:
            raise AppError("invalid_parameters")
        if type(count) is not int or count < 0 or not digest_value(item["sha256"]):
            raise AppError("invalid_manifest")
        total += count
        if count > MAX_FILE_BYTES or total > MAX_PAYLOAD_BYTES:
            raise AppError("payload_too_large")
    return manifest, sha256_bytes(data)


def validate_import_manifest(data: bytes, now: datetime) -> tuple[dict, str]:
    manifest, digest = validate_manifest(data, now)
    if manifest["kind"] != "request" or manifest["action"] != "research.importDocuments":
        raise AppError("unknown_action")
    return manifest, digest


def regular(path: Path, *, directory: bool = False):
    try:
        info = path.lstat()
    except OSError as exc:
        raise AppError("unsafe_file") from exc
    test = stat.S_ISDIR if directory else stat.S_ISREG
    if (
        not test(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400
        or (not directory and info.st_nlink != 1)
    ):
        raise AppError("unsafe_file")
    return info


def read_bytes(path: Path, maximum: int, exact_size: int | None = None) -> bytes:
    before = regular(path)
    if exact_size is not None and before.st_size != exact_size:
        raise AppError("byte_count_mismatch")
    if before.st_size > maximum:
        raise AppError("payload_too_large")

    def identity(info):
        return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_nlink)
    try:
        with path.open("rb") as handle:
            opened = os.fstat(handle.fileno())
            if identity(before) != identity(opened) or not stat.S_ISREG(opened.st_mode):
                raise AppError("checksum_mismatch")
            data = handle.read(before.st_size + 1)
            after = os.fstat(handle.fileno())
    except OSError as exc:
        raise AppError("unsafe_file") from exc
    final = regular(path)
    if (
        len(data) != before.st_size or identity(before) != identity(after) or identity(before) != identity(final)
        or opened.st_ctime_ns != after.st_ctime_ns or before.st_ctime_ns != final.st_ctime_ns
    ):
        raise AppError("checksum_mismatch")
    return data


def _validated_payload(item: dict, data: bytes) -> bytes:
    if len(data) != item["byteCount"]:
        raise AppError("byte_count_mismatch")
    if sha256_bytes(data) != item["sha256"].lower():
        raise AppError("checksum_mismatch")
    return data


def _directory_package(path: Path, now: datetime, validator):
    regular(path, directory=True)
    if path.suffix.lower() != ".gaoaction":
        raise AppError("invalid_manifest")
    manifest, digest = validator(read_bytes(path / "manifest.json", MAX_MANIFEST_BYTES), now)
    if manifest["items"]:
        regular(path / "payload", directory=True)
    staged = []
    for item in manifest["items"]:
        payload = path / "payload"
        *parents, name = payload_parts(item["relativePath"])
        for part in parents:
            payload /= part
            regular(payload, directory=True)
        data = read_bytes(payload / name, MAX_FILE_BYTES, item["byteCount"])
        staged.append((item, _validated_payload(item, data)))
    return manifest, digest, staged


def _zip_package(path: Path, now: datetime, validator):
    regular(path)
    try:
        with zipfile.ZipFile(path) as archive:
            files = {}
            seen = set()
            for info in archive.infolist():
                parts = safe_parts(info.filename.rstrip("/"))
                key = "/".join(parts)
                mode = stat.S_IFMT(info.external_attr >> 16)
                if key.casefold() in seen or mode not in {0, stat.S_IFDIR, stat.S_IFREG}:
                    raise AppError("unsafe_path")
                seen.add(key.casefold())
                if not info.is_dir():
                    files[key] = info
            manifest_name = "manifest.json"
            if manifest_name not in files:
                names = [key for key in files if key.endswith("/manifest.json") and key.count("/") == 1]
                if len(names) != 1:
                    raise AppError("invalid_manifest")
                manifest_name = names[0]
            info = files[manifest_name]
            if info.file_size > MAX_MANIFEST_BYTES:
                raise AppError("payload_too_large")
            with archive.open(info) as handle:
                manifest, digest = validator(handle.read(MAX_MANIFEST_BYTES + 1), now)
            stem = manifest_name.removesuffix("manifest.json") + "payload/"
            staged = []
            for item in manifest["items"]:
                member = files.get(stem + "/".join(payload_parts(item["relativePath"])))
                if member is None:
                    raise AppError("unsafe_file")
                if member.file_size != item["byteCount"]:
                    raise AppError("byte_count_mismatch")
                with archive.open(member) as handle:
                    payload = handle.read(item["byteCount"] + 1)
                staged.append((item, _validated_payload(item, payload)))
    except (OSError, zipfile.BadZipFile, RuntimeError, NotImplementedError) as exc:
        raise AppError("invalid_manifest") from exc
    return manifest, digest, staged


def load_package(package: Path, now: datetime, *, import_only: bool = True):
    validator = validate_import_manifest if import_only else validate_manifest
    package = Path(package)
    if package.is_dir():
        return _directory_package(package, now, validator)
    if package.suffix.lower() in {".gaoaction", ".zip"}:
        return _zip_package(package, now, validator)
    raise AppError("invalid_manifest")
