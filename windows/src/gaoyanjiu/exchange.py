"""Research's Windows GaoAction request, review, and receipt workflows."""

from __future__ import annotations

import math
import os
import re
import shutil
import subprocess
import tempfile
import threading
import uuid
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote, urlsplit

from gaoyanjiu import BUNDLE_ID, __version__
from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import atomic_write, sha256_bytes
from gaoyanjiu.gaoaction import (
    MAX_FILE_BYTES, MAX_MANIFEST_BYTES, decode_json, digest_value, encode_json, envelope, fresh,
    identifier, load_package, payload_parts, read_bytes, regular, safe_parts,
)
from gaoyanjiu.textutil import extract_text
from gaoyanjiu.timeutil import format_iso, parse_iso
from gaoyanjiu.winidentity import version_strings

OCR = "ocr.files"
CHOOSE = "files.choose"
EDIT = "documents.open"
IMPORT = "research.importDocuments"
PROVIDERS = {OCR: "GaoCaoZuo", CHOOSE: "GaoWenJian", EDIT: "GaoWenJian"}
FILE_INSTALLER_APP_ID = "{B06256C0-5B37-44AB-941B-7B8E00C7ED63}"
LEGACY_FILE_IDENTITY = {"CompanyName": "GaoSeries", "ProductName": "搞文件", "FileVersion": "1.11.2.0", "ProductVersion": "1.11"}
FORMAT_UTIS = {
    "pdf": ("com.adobe.pdf", "application/pdf"),
    "txt": ("public.utf8-plain-text", "public.plain-text", "text/plain"),
    "md": ("net.daringfireball.markdown", "public.markdown", "text/markdown"),
    "json": ("public.json", "application/json"),
}
IMAGE_UTIS = {
    "png": "public.png", "jpg": "public.jpeg", "jpeg": "public.jpeg", "tif": "public.tiff",
    "tiff": "public.tiff", "gif": "com.compuserve.gif", "webp": "org.webmproject.webp",
    "heic": "public.heic", "heif": "public.heif",
}
OCR_FORMATS = {"txt": "text", "md": "markdown", "json": "json", "pdf": "searchablePDF"}
PROVIDER_FILE_CAP = 128 * 1024 * 1024
MAX_REVIEW_METADATA = 16 * 1024 * 1024
PAGE_STATES = ("completed", "failed", "lowConfidence", "cancelled", "pending")
REVIEW_LOCK = threading.RLock()
NAMESPACE = uuid.UUID("c8234bb2-1236-43ad-8993-eeaa66c2be91")


def research_capabilities() -> dict:
    return {"schemaVersion": 1, "bundleID": BUNDLE_ID, "appVersion": __version__, "actions": [
        {"action": IMPORT, "supportsItems": True, "supportsReferences": False, "requiresUserConfirmation": True,
         "parametersSchema": {"type": "object", "additionalProperties": False, "properties": {}}},
    ]}


def _error(code: str, detail: str, status: int = 409) -> AppError:
    return AppError(code, status, detail)


def _lookup(rows, record_id):
    for row in rows:
        if row.get("id") == record_id:
            return row
    raise AppError("not_found", 404)


def _extension(filename: str) -> str:
    return Path(filename).suffix.lower().removeprefix(".")


def _name(value: str, fallback: str = "document") -> str:
    name = re.sub(r'[\\/:<>"|?*\x00-\x1f]', "_", str(value)).strip(" .") or fallback
    suffix = Path(name).suffix
    if len(name) > 75 and 0 < len(suffix) <= 17:
        name = name[:75 - len(suffix)].rstrip(" .") + suffix
    else:
        name = name[:75].rstrip(" .")
    try:
        safe_parts(name)
    except AppError:
        name = "file-" + name
    return name


def _uid(key: str) -> str:
    return str(uuid.uuid5(NAMESPACE, key))


def _format_uti(uti: str) -> str:
    return next((ext for ext, types in FORMAT_UTIS.items() if uti in types), "")


def _package_write(path: Path, manifest: dict, files: list[tuple[str, bytes]]) -> str:
    manifest_data = encode_json(manifest)
    if len(manifest_data) > MAX_MANIFEST_BYTES:
        raise AppError("payload_too_large")
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".exchange-", dir=path.parent) as work:
        package = Path(work) / "package"
        target = package / "payload"
        target.mkdir(parents=True)
        for relative, content in files:
            file = target.joinpath(*payload_parts(relative))
            file.parent.mkdir(parents=True, exist_ok=True)
            atomic_write(file, content)
        atomic_write(package / "manifest.json", manifest_data)
        package.rename(path)
    return sha256_bytes(manifest_data)


def _target_dirs(product: str):
    if os.name != "nt":
        return
    import winreg

    installer_ids = [f"GaoSeries.{product}.Windows"]
    if product == "GaoWenJian":
        installer_ids.insert(0, FILE_INSTALLER_APP_ID)
    install_keys = [(rf"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{app_id}_is1", "InstallLocation")
                    for app_id in installer_ids]
    alias = rf"SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\{product}.exe"
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        for key, value in (*install_keys, (alias, "")):
            try:
                with winreg.OpenKey(hive, key, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY) as handle:
                    raw = winreg.QueryValueEx(handle, value)[0]
                    path = Path(os.path.expandvars(raw.strip().strip('"')))
                    if path.is_absolute():
                        yield path if value else path.parent
            except (OSError, TypeError, AttributeError):
                continue
    for name in ("LOCALAPPDATA", "ProgramFiles"):
        base = os.environ.get(name)
        if base:
            root = Path(base) / "Programs" if name == "LOCALAPPDATA" else Path(base)
            yield root / "GaoSeries" / product


def _provider_exe(product: str) -> Path | None:
    for root in _target_dirs(product):
        program = root / (product + ".exe")
        if program.is_file() and program.with_name(product + "-cli.exe").is_file():
            return program
    return None


def _capability_identity(data, product: str) -> bool:
    if not isinstance(data, dict) or type(data.get("schemaVersion")) is not int or data["schemaVersion"] != 1:
        return False
    if data.get("bundleID") != f"com.gaoseries.{product}" or not re.fullmatch(r"\d+(?:\.\d+){1,3}", str(data.get("appVersion"))):
        return False
    return isinstance(data.get("actions"), list)


def _valid_capabilities(data, product: str, manifest: dict) -> bool:
    if not _capability_identity(data, product):
        return False
    actions = data.get("actions")
    matching = [action for action in actions if isinstance(action, dict) and action.get("action") == manifest["action"]]
    if len(matching) != 1:
        return False
    capability = matching[0]
    if capability.get("requiresUserConfirmation") is not True:
        return False
    if manifest["items"] and capability.get("supportsItems") is not True:
        return False
    if manifest["references"] and capability.get("supportsReferences") is not True:
        return False
    schema = capability.get("parametersSchema")
    if not isinstance(schema, dict) or schema.get("type") != "object":
        return False
    fields = schema.get("properties")
    if not isinstance(fields, dict):
        return False
    required = schema.get("required", [])
    if not isinstance(required, list) or any(not isinstance(key, str) or key not in manifest["parameters"] for key in required):
        return False
    for key, value in manifest["parameters"].items():
        field = fields.get(key)
        if not isinstance(field, dict):
            return False
        if type(value) is bool and field.get("type") != "boolean":
            return False
        if isinstance(value, list):
            items = field.get("items", {})
            if field.get("type") != "array" or not isinstance(items, dict) or items.get("type") != "string":
                return False
            if len(value) < field.get("minItems", 0) or len(value) > field.get("maxItems", 256):
                return False
            if "enum" in items and any(item not in items["enum"] for item in value):
                return False
    return True


def _provider_probe(cli: Path, option: str) -> bytes:
    result = subprocess.run([str(cli), option], check=True, timeout=8, capture_output=True,
                            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0), stdin=subprocess.DEVNULL)
    if len(result.stdout) > MAX_MANIFEST_BYTES:
        raise AppError("invalid_manifest")
    return result.stdout


def _research_receipt_flag(executable: Path, cli: Path, manifest: dict) -> str:
    if manifest["kind"] != "result" or manifest["action"] != IMPORT or manifest["targetBundleID"] != "com.gaoseries.GaoWenJian":
        return ""
    try:
        capabilities = decode_json(_provider_probe(cli, "--capabilities"))
        if _capability_identity(capabilities, "GaoWenJian"):
            return "--gaoaction"
    except (AppError, subprocess.CalledProcessError):
        # Version 1.11+2 recognizes `--open` for receipts but lacks a capability query.
        pass
    if any(version_strings(program) != LEGACY_FILE_IDENTITY for program in (executable, cli)):
        return ""
    return "--open" if _provider_probe(cli, "--version").strip() == b"1.11+2" else ""


def _launch_provider(product: str, path: Path, manifest: dict) -> str:
    executable = _provider_exe(product)
    if executable is None:
        return "提供方未安装。交接包已保留，可在提供方手动选择。"
    try:
        cli = executable.with_name(product + "-cli.exe")
        if product == "GaoWenJian" and manifest["kind"] == "result":
            flag = _research_receipt_flag(executable, cli, manifest)
        else:
            try:
                capabilities = decode_json(_provider_probe(cli, "--capabilities"))
            except (subprocess.CalledProcessError, AppError):
                capabilities = None
            flag = "--gaoaction" if _valid_capabilities(capabilities, product, manifest) else ""
        if not flag:
            return "提供方版本或能力不兼容。交接包已保留。"
        subprocess.Popen([str(executable), flag, str(path)], stdin=subprocess.DEVNULL,
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except (OSError, ValueError, TypeError, AppError, subprocess.SubprocessError):
        return "未能启动兼容的提供方。交接包已保留。"
    return "已将交接包交给提供方，请在该应用中审核。"


def _pages(values) -> list[dict]:
    if values is None:
        return []
    if not isinstance(values, list) or len(values) > 10000:
        raise _error("invalid_manifest", "OCR 结果的页信息无效。")
    pages = {}
    for row in values:
        if not isinstance(row, dict):
            raise _error("invalid_manifest", "OCR 结果的页信息无效。")
        number, status = row.get("pageNumber", row.get("page")), row.get("status")
        confidence, text = row.get("confidence"), row.get("text")
        coordinate = row.get("coordinateSpace")
        regions = row.get("regions", row.get("coordinates", []))
        if (
            type(number) is not int or not 1 <= number <= 1_000_000 or number in pages or status not in PAGE_STATES
            or (confidence is not None and (type(confidence) not in {float, int} or not 0 <= confidence <= 1))
            or (text is not None and not isinstance(text, str))
            or coordinate not in (None, "normalized", "points", "pixels") or not isinstance(regions, list)
        ):
            raise _error("invalid_manifest", "OCR 结果的页码、状态、文字或坐标无效。")
        page = {"pageNumber": number, "status": status}
        if confidence is not None:
            page["confidence"] = confidence
        if text is not None:
            page["text"] = text
        if coordinate:
            page["coordinateSpace"] = coordinate
        if regions:
            page["regions"] = []
            for box in regions:
                fields = ("x", "y", "width", "height")
                items = [box.get(key) for key in fields] if isinstance(box, dict) else []
                if (
                    len(items) != 4 or not all(type(item) in {float, int} and math.isfinite(item) and item >= 0 for item in items)
                    or not all(items[2:]) or (coordinate == "normalized" and
                    (items[0] + items[2] > 1.000001 or items[1] + items[3] > 1.000001))
                ):
                    raise _error("invalid_manifest", "OCR 结果的页坐标无效。")
                page["regions"].append(dict(zip(fields, items)))
        reason = row.get("failureReason", row.get("error"))
        if isinstance(reason, str) and reason:
            page["failureReason"] = reason
        pages[number] = page
    return [pages[number] for number in sorted(pages)]


def _json_pages(payload: bytes, digest: str) -> list[dict]:
    if len(payload) > MAX_REVIEW_METADATA:
        raise AppError("payload_too_large")
    artifact = decode_json(payload)
    sources = artifact.get("sources") if isinstance(artifact, dict) and artifact.get("schemaVersion") == 1 else None
    if not isinstance(sources, list):
        raise _error("invalid_manifest", "OCR JSON 缺少可核对的原件。")
    matches = [item for item in sources if isinstance(item, dict) and str(item.get("sha256", "")).lower() == digest]
    if len(matches) != 1:
        raise _error("invalid_manifest", "OCR JSON 与请求的原件摘要不匹配。")
    source = matches[0]
    if isinstance(source.get("pages"), list):
        used = source["pages"]
    elif isinstance(artifact.get("pages"), list) and isinstance(source.get("id"), str):
        used = [page for page in artifact["pages"] if isinstance(page, dict) and page.get("sourceID") == source["id"]]
        if any(str(page.get("originalSHA256", "")).lower() != digest for page in used):
            raise _error("invalid_manifest", "OCR JSON 的页与请求原件不匹配。")
    else:
        raise _error("invalid_manifest", "OCR JSON 缺少逐页识别结果。")
    combined = []
    for row in used:
        if not isinstance(row, dict):
            raise AppError("invalid_manifest")
        lines = row.get("lines")
        if not isinstance(lines, list) or any(not isinstance(line, dict) or not isinstance(line.get("text"), str) for line in lines):
            raise AppError("invalid_manifest")
        if all(type(line.get("readingOrder")) is int for line in lines):
            lines = sorted(lines, key=lambda line: line["readingOrder"])
        combined.append({**row, "text": "\n".join(line["text"] for line in lines)})
    return _pages(combined)


def _merge_pages(declared: list[dict], verified: list[dict]) -> list[dict]:
    merged = {page["pageNumber"]: page for page in declared}
    for page in verified:
        before = merged.get(page["pageNumber"])
        if before and before["status"] != page["status"]:
            raise _error("invalid_manifest", "OCR JSON 的页状态与结果清单不一致。")
        merged[page["pageNumber"]] = {**(before or {}), **page}
    return sorted(merged.values(), key=lambda page: page["pageNumber"])


def _ocr_result(manifest: dict, staged: list, bindings: list) -> tuple[list, list]:
    provenance = manifest["provenance"]
    by_input = {binding["itemID"]: binding for binding in bindings}
    by_output = {entry[0]["id"]: entry for entry in staged}
    if not staged and manifest["status"] in {"failed", "cancelled", "unsupported", "pending"}:
        return [], []
    sources = provenance.get("sources")
    outputs = provenance.get("outputs")
    if sources is None and len(bindings) == 1 and provenance.get("sourceItemID"):
        sources = [{**provenance, "outputItemIDs": list(by_output)}]
    if outputs is None and len(bindings) == 1 and provenance.get("sourceItemID"):
        outputs = [{**provenance, "resultItemID": item_id} for item_id in by_output]
    if not isinstance(sources, list) or not isinstance(outputs, list):
        raise _error("invalid_manifest", "OCR 结果缺少原件或输出映射。")

    def source_binding(row):
        if not isinstance(row, dict) or not isinstance(row.get("sourceItemID"), str):
            raise AppError("invalid_manifest")
        source = by_input.get(row["sourceItemID"])
        if not source or str(row.get("sourceSHA256", "")).lower() != source["sha256"]:
            raise _error("checksum_mismatch", "OCR 结果的原件编号或摘要与原请求不一致。")
        return source

    by_source = {}
    for row in sources:
        source = source_binding(row)
        item_id = source["itemID"]
        declared = row.get("outputItemIDs")
        if item_id in by_source or (declared is not None and
                (not isinstance(declared, list) or not all(isinstance(item, str) and item in by_output for item in declared)
                 or len(set(declared)) != len(declared))):
            raise AppError("invalid_manifest")
        by_source[item_id] = (row, _pages(row.get("pages")))
    mappings, page_artifacts = {}, {}
    output_formats = set()
    requested_formats = set(manifest["parameters"].get("outputs", []))
    for output in outputs:
        binding = source_binding(output)
        source_id = binding["itemID"]
        item_id = output.get("resultItemID", output.get("itemID"))
        if not isinstance(item_id, str) or item_id not in by_output or item_id in mappings or source_id not in by_source:
            raise AppError("invalid_manifest")
        row, pages = by_source[source_id]
        if "outputItemIDs" in row and item_id not in row["outputItemIDs"]:
            raise AppError("invalid_manifest")
        if (row.get("sourceID") is not None and output.get("sourceID") is not None
                and row["sourceID"] != output["sourceID"]):
            raise AppError("invalid_manifest")
        item, content = by_output[item_id]
        ext = _format_uti(item["uti"])
        if not ext or output.get("format", OCR_FORMATS[ext]) != OCR_FORMATS[ext] or ext != _extension(item["relativePath"]):
            raise AppError("invalid_parameters")
        format_key = (source_id, OCR_FORMATS[ext])
        if format_key in output_formats or (requested_formats and format_key[1] not in requested_formats):
            raise AppError("invalid_parameters")
        output_formats.add(format_key)
        if ext == "json":
            if source_id in page_artifacts:
                raise AppError("invalid_manifest")
            page_artifacts[source_id] = _json_pages(content, binding["sha256"])
        metadata = {**provenance, **row, **output}
        revision = metadata.get("engineRevision")
        if revision is not None and (type(revision) is not int or not 0 <= revision <= 2 ** 31 - 1):
            raise AppError("invalid_manifest")
        languages = metadata.get("languages", [])
        if not isinstance(languages, list) or len(languages) > 256 or any(
            not isinstance(lang, str) or not re.fullmatch(r"[A-Za-z]{2,8}(?:-[A-Za-z0-9]{1,8})*", lang) for lang in languages
        ):
            raise AppError("invalid_manifest")
        mappings[item_id] = {
            "itemID": item_id,
            "sourceItemID": source_id,
            "sourceDocumentID": binding["documentID"],
            "sourceSHA256": binding["sha256"],
            "sourceName": binding["name"],
            "format": OCR_FORMATS[ext],
            "extension": ext,
            "engine": metadata.get("engine", metadata.get("ocrEngine")),
            "engineVersion": metadata.get("engineVersion", metadata.get("ocrEngineVersion", None if revision is None else f"revision {revision}")),
            "languages": languages,
            "pages": _merge_pages(pages, _pages(output.get("pages", provenance.get("pages")))),
        }
        if any(value is not None and not isinstance(value, str) for value in (mappings[item_id]["engine"], mappings[item_id]["engineVersion"])):
            raise AppError("invalid_manifest")
    if set(mappings) != set(by_output):
        raise AppError("invalid_manifest")
    for source_id, (record, _source_pages) in by_source.items():
        if "outputItemIDs" in record and set(record["outputItemIDs"]) != {
            item_id for item_id, output in mappings.items() if output["sourceItemID"] == source_id
        }:
            raise AppError("invalid_manifest")
    warnings = []
    if manifest["status"] == "completed":
        covered = {output["sourceItemID"] for output in mappings.values()}
        if covered != set(by_input) or provenance.get("exportFailures") or any(
            requested_formats - {output["format"] for output in mappings.values() if output["sourceItemID"] == source}
            for source in covered
        ):
            raise _error("invalid_manifest", "OCR 完成状态没有覆盖所有请求的输入和输出。")
    for output in mappings.values():
        output["pages"] = _merge_pages(output["pages"], page_artifacts.get(output["sourceItemID"], []))
        if not output["engine"] or not output["engineVersion"]:
            warnings.append("未提供 OCR 引擎或版本。")
        if not output["languages"]:
            warnings.append("未提供实际使用的 OCR 语言。")
        if not output["pages"]:
            warnings.append("未提供 OCR 逐页状态。")
        if any(page.get("regions") and not page.get("coordinateSpace") for page in output["pages"]):
            warnings.append("部分 OCR 坐标未声明单位。")
    all_pages = [page for _row, entries in by_source.values() for page in entries]
    all_pages += [page for output in mappings.values() for page in output["pages"]]
    if manifest["status"] == "completed" and any(
        page["status"] != "completed" or page.get("confidence", 1) < 0.5 for page in all_pages
    ):
        raise _error("invalid_manifest", "OCR 含失败、取消或低置信度页，不能标为完成。")
    for failure in provenance.get("exportFailures", []):
        if isinstance(failure, str):
            warnings.append(failure[:400])
    return list(mappings.values()), list(dict.fromkeys(warnings))


def _references(manifest: dict) -> list[dict]:
    ids = set()
    for reference in manifest["references"]:
        if not isinstance(reference, dict) or set(reference) - {"id", "kind", "displayName", "fileURL", "declaredIdentity", "sha256"}:
            raise AppError("invalid_parameters")
        identifier_value = reference.get("id")
        name = reference.get("displayName")
        location = reference.get("fileURL")
        identity = reference.get("declaredIdentity")
        if (
            not isinstance(identifier_value, str) or not identifier_value or len(identifier_value) > 256 or identifier_value in ids
            or reference.get("kind") != "file" or not isinstance(name, str) or not name or len(name) > 4096
            or not isinstance(location, str) or len(location) > 16384 or not isinstance(identity, dict)
        ):
            raise AppError("invalid_parameters")
        ids.add(identifier_value)
        try:
            url = urlsplit(location)
            decoded = unquote(url.path, errors="strict")
        except (ValueError, UnicodeError) as exc:
            raise AppError("invalid_parameters") from exc
        if url.scheme != "file" or url.netloc.lower() not in {"", "localhost"} or not decoded.startswith("/") or url.query or url.fragment or "\x00" in decoded or "\\" in decoded or ".." in decoded.split("/"):
            raise AppError("invalid_parameters")
        if reference.get("sha256") is not None and not digest_value(reference["sha256"]):
            raise AppError("invalid_parameters")
        if set(identity) - {"device", "inode", "volumeUUID", "byteCount", "modifiedAt"}:
            raise AppError("invalid_parameters")
        for key in ("device", "inode", "byteCount"):
            if identity.get(key) is not None and (type(identity[key]) is not int or identity[key] < 0):
                raise AppError("invalid_parameters")
        if identity.get("modifiedAt") is not None:
            if not isinstance(identity["modifiedAt"], str):
                raise AppError("invalid_parameters")
            try:
                parse_iso(identity["modifiedAt"])
            except ValueError as exc:
                raise AppError("invalid_parameters") from exc
    return manifest["references"]


def _chosen_reference(reference: dict, path: Path) -> bytes:
    identity = reference["declaredIdentity"]
    first = regular(path)
    payload = read_bytes(path, MAX_FILE_BYTES)
    after = regular(path)
    digest = reference.get("sha256")
    if digest and sha256_bytes(payload) != digest.lower():
        raise AppError("checksum_mismatch")
    if not digest:
        declared = unquote(urlsplit(reference["fileURL"]).path, errors="strict")
        if os.name == "nt" and re.match(r"^/[A-Za-z]:/", declared):
            declared = declared[1:]
        if os.path.normcase(os.path.abspath(declared)) != os.path.normcase(os.path.abspath(path)) or identity.get("volumeUUID"):
            raise _error("unsafe_file", "该引用没有内容摘要。请选择提供方实际引用的本机原件。")
    for key, actual in (("device", first.st_dev), ("inode", first.st_ino), ("byteCount", len(payload))):
        if identity.get(key) is not None and identity[key] != actual:
            raise AppError("checksum_mismatch")
    if (first.st_dev, first.st_ino, first.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_mtime_ns):
        raise AppError("checksum_mismatch")
    if identity.get("modifiedAt") and abs((parse_iso(identity["modifiedAt"]) -
            datetime.fromtimestamp(first.st_mtime, timezone.utc)).total_seconds()) >= 0.001:
        raise AppError("checksum_mismatch")
    return payload


class ResearchExchange:
    def __init__(self, store):
        self.store = store
        self.root = store.library.root / "WindowsExchange"

    def _root_path(self, branch: str, value: str) -> Path:
        return self.root / branch / identifier(value)

    def _record(self, branch: str, value: str) -> dict:
        folder = self._root_path(branch, value)
        if not folder.exists():
            raise AppError("not_found", 404)
        record = decode_json(read_bytes(folder / "record.json", MAX_REVIEW_METADATA))
        if not isinstance(record, dict) or not isinstance(record.get("manifest"), dict):
            raise AppError("unreadable")
        if identifier(record["manifest"].get("requestID")) != folder.name:
            raise AppError("unreadable")
        return record

    def _records(self, branch: str) -> list[dict]:
        root = self.root / branch
        if not root.is_dir():
            return []
        records = []
        for folder in root.iterdir():
            try:
                if folder.is_dir() and identifier(folder.name) == folder.name:
                    records.append(self._record(branch, folder.name))
            except AppError:
                continue
        records.sort(key=lambda row: row["manifest"]["createdAt"], reverse=True)
        return records

    def _stage(self, branch: str, record: dict, payloads: list[tuple[str, bytes]], *, request=False) -> Path:
        manifest = record["manifest"]
        result = self._root_path(branch, manifest["requestID"])
        result.parent.mkdir(parents=True, exist_ok=True)
        record_data = encode_json(record)
        if len(record_data) > MAX_REVIEW_METADATA:
            raise AppError("payload_too_large")
        with tempfile.TemporaryDirectory(prefix=".review-", dir=result.parent) as work:
            staged = Path(work) / "record"
            staged.mkdir()
            if request:
                _package_write(staged / "request.gaoaction", manifest, payloads)
            else:
                for index, (_unused, data) in enumerate(payloads):
                    atomic_write(staged / "payload" / str(index), data)
            atomic_write(staged / "record.json", record_data)
            staged.rename(result)
        return result

    def _business(self, write: bool = False) -> dict:
        if not write and self.store.library.status == "needs_create":
            return {}
        data = self.store._data() if write else self.store._view()
        records = data.setdefault("windowsExchangeReceipts", {}) if write else data.get("windowsExchangeReceipts", {})
        if not isinstance(records, dict):
            raise AppError("unreadable")
        return records

    def _commit(self) -> None:
        self.store.library.save()
        try:
            self.store.write_snapshot()
        except (AppError, OSError):
            pass

    def prepare(self, action: str, document_ids=None, folder_id: str = "", launch: bool = True) -> dict:
        if action not in PROVIDERS:
            raise AppError("unknown_action")
        data = self.store._data()
        document_ids = [] if document_ids is None else document_ids
        if not isinstance(document_ids, list) or any(not isinstance(value, str) for value in document_ids):
            raise AppError("invalid_field")
        parameters = {}
        if action == CHOOSE:
            if document_ids:
                raise AppError("invalid_parameters")
            _lookup(data["documentFolders"], folder_id)
            parameters = {"multiple": True}
        else:
            if not document_ids or len(set(document_ids)) != len(document_ids) or len(document_ids) > (85 if action == OCR else 1):
                raise AppError("invalid_parameters")
            if action == OCR:
                parameters = {"outputs": ["text", "json", "searchablePDF"]}
        product = PROVIDERS[action]
        manifest = envelope("request", action, BUNDLE_ID, f"com.gaoseries.{product}", self.store.clock(), parameters)
        bindings, copies = [], []
        total = 0
        for index, document_id in enumerate(document_ids, 1):
            document = _lookup(data["managedDocuments"], document_id)
            extension = document["fileExtension"].lower()
            source_types = FORMAT_UTIS.get(extension)
            uti = (IMAGE_UTIS.get(extension) or (source_types or (None,))[0]) if action == OCR else (source_types or (None,))[0]
            if not uti or (action == OCR and extension not in {"pdf", *IMAGE_UTIS}):
                raise _error("invalid_parameters", "此文件格式不在该 Windows 提供方的交接范围内。", 400)
            payload = read_bytes(self.store._document_path(document), PROVIDER_FILE_CAP if action == OCR else MAX_FILE_BYTES)
            total += len(payload)
            if total > 2 * 1024 * 1024 * 1024:
                raise AppError("payload_too_large")
            digest = sha256_bytes(payload)
            if document.get("sha256") and document["sha256"] != digest:
                raise AppError("checksum_mismatch")
            item_id = str(uuid.uuid4())
            original = _name(Path(document["originalName"]).stem)
            name = f"{index:02d}-{original}.{extension}"
            manifest["items"].append({"id": item_id, "relativePath": name, "uti": uti, "byteCount": len(payload), "sha256": digest})
            bindings.append({"itemID": item_id, "documentID": document_id, "name": document["displayName"],
                             "sha256": digest, "storedName": document["storedName"], "updatedAt": document["updatedAt"],
                             "folderID": document["folderID"]})
            copies.append((name, payload))
        record = {"manifest": manifest, "bindings": bindings, "folderID": folder_id}
        with REVIEW_LOCK:
            location = self._stage("Outgoing", record, copies, request=True) / "request.gaoaction"
        message = _launch_provider(product, location, manifest) if launch else "交接包已生成；请在提供方复核。"
        return {"requestID": manifest["requestID"], "path": str(location), "expiresAt": manifest["expiresAt"], "message": message}

    def receive(self, path: Path) -> dict:
        if self.store.library.status != "needs_create":
            self.store._view()
        if not path.is_absolute():
            raise AppError("unsafe_path")
        manifest, digest, items = load_package(path, self.store.clock(), import_only=False)
        result_id = identifier(manifest["requestID"])
        with REVIEW_LOCK:
            stage = self._root_path("Incoming", result_id)
            if stage.exists():
                saved = self._record("Incoming", result_id)
                if saved["manifestSHA256"] != digest:
                    raise AppError("request_conflict", 409)
                return self._summary(saved)
            record = {"manifest": manifest, "manifestSHA256": digest, "outputs": [], "warnings": []}
            if manifest["kind"] == "result":
                session = self._record("Outgoing", manifest["inReplyTo"])
                original = session["manifest"]
                if (
                    identifier(manifest["inReplyTo"]) != identifier(original["requestID"])
                    or manifest["sourceBundleID"] != original["targetBundleID"]
                    or manifest["action"] != original["action"]
                    or manifest["parameters"] not in ({}, original["parameters"])
                ):
                    raise _error("request_conflict", "结果与原请求的提供方、动作或参数不一致。")
                request_digest = manifest["provenance"].get("requestManifestSHA256")
                if request_digest is not None:
                    source_path = self._root_path("Outgoing", manifest["inReplyTo"]) / "request.gaoaction/manifest.json"
                    if request_digest != sha256_bytes(read_bytes(source_path, MAX_MANIFEST_BYTES)):
                        raise AppError("checksum_mismatch")
                record["folderID"] = session["folderID"]
                action = manifest["action"]
                if action == OCR:
                    orphan = {**manifest, "parameters": original["parameters"]}
                    record["outputs"], record["warnings"] = _ocr_result(orphan, items, session["bindings"])
                    record["sources"] = _ocr_review_sources(manifest["provenance"], session["bindings"], record["outputs"])
                elif action == EDIT:
                    if items or manifest["references"]:
                        raise _error("invalid_parameters", "打开文档的回执不能附带编辑副本。")
                    workflow = manifest["provenance"].get("workflowState")
                    if manifest["status"] == "completed" and workflow not in (None, "opened", "completed"):
                        raise AppError("invalid_manifest")
                elif action == CHOOSE:
                    references = _references(manifest)
                    if {ref["id"] for ref in references} & {item["id"] for item, _data in items}:
                        raise AppError("invalid_parameters")
                    selected = len(items) + len(manifest["references"])
                    if manifest["status"] == "completed" and not selected:
                        raise AppError("invalid_parameters")
                    if selected > 1 and not original["parameters"].get("multiple", False):
                        raise AppError("invalid_parameters")
            self._stage("Incoming", record, [(item["relativePath"], payload) for item, payload in items])
            return self._summary(record)

    def _summary(self, record: dict, include_pages: bool = False) -> dict:
        manifest = record["manifest"]
        result_id = identifier(manifest["requestID"])
        receipt = self._business().get("envelope:" + result_id, {})
        applied = receipt.get("status")
        ready = manifest["kind"] == "request" or (
            manifest["action"] in (OCR, CHOOSE) and manifest.get("status") in ("completed", "partial")
            and bool(manifest["items"] or manifest["references"])
        )
        expired = self.store.clock() >= parse_iso(manifest["expiresAt"])
        approved = self._approval(record) if not applied else None
        resume = approved is not None and not applied
        folder_id = approved["intent"].get("folderID", "") if resume else record.get("folderID", "")
        summary = {
            "id": result_id, "inReplyTo": manifest.get("inReplyTo"), "kind": manifest["kind"],
            "action": manifest["action"], "createdAt": manifest["createdAt"], "expiresAt": manifest["expiresAt"],
            "sourceBundleID": manifest["sourceBundleID"], "providerStatus": manifest.get("status"),
            "status": applied or ("interrupted" if resume else "expired" if expired else "pending" if ready else "received"),
            "canApply": bool(ready and (resume or not expired) and not applied),
            "canReject": manifest["kind"] == "request" and not applied and not resume,
            "canExportReceipt": manifest["kind"] == "request",
            "folderID": folder_id, "warnings": record["warnings"], "resuming": resume,
            "items": [{"id": item["id"], "name": payload_parts(item["relativePath"])[-1], "byteCount": item["byteCount"],
                       "sha256": item["sha256"]} for item in manifest["items"]],
            "references": [{"id": reference["id"], "name": reference["displayName"], "fileURL": reference["fileURL"],
                            "sha256": reference.get("sha256")} for reference in manifest["references"]],
            "counts": receipt.get("counts"),
        }
        if include_pages:
            summary["outputs"] = record["outputs"]
            summary["sources"] = record.get("sources", [])
            summary["errorCode"] = manifest.get("errorCode")
            summary["workflowState"] = (manifest.get("provenance") or {}).get("workflowState")
        return summary

    def overview(self) -> dict:
        return {"incoming": [self._summary(row) for row in self._records("Incoming")[:100]],
                "outgoing": [{"id": identifier(row["manifest"]["requestID"]), "action": row["manifest"]["action"],
                              "createdAt": row["manifest"]["createdAt"], "expiresAt": row["manifest"]["expiresAt"],
                              "targetBundleID": row["manifest"]["targetBundleID"],
                              "path": str(self._root_path("Outgoing", row["manifest"]["requestID"]) / "request.gaoaction")}
                             for row in self._records("Outgoing")[:100]],
                "folders": [{"id": folder["id"], "name": folder["name"], "libraryKind": folder.get("libraryKind")}
                            for folder in self.store._view()["documentFolders"]]}

    def review(self, value: str) -> dict:
        return self._summary(self._record("Incoming", value), True)

    def reveal(self, value: str) -> dict:
        folder = self._root_path("Outgoing", value) / "request.gaoaction"
        if not folder.is_dir():
            raise AppError("not_found", 404)
        if os.name == "nt":
            os.startfile(str(folder.parent))
        return {"path": str(folder)}

    def _stage_payload(self, record: dict) -> list[tuple[dict, bytes]]:
        incoming = self._root_path("Incoming", record["manifest"]["requestID"]) / "payload"
        output = []
        for index, item in enumerate(record["manifest"]["items"]):
            payload = read_bytes(incoming / str(index), MAX_FILE_BYTES, item["byteCount"])
            if sha256_bytes(payload) != item["sha256"].lower():
                raise AppError("checksum_mismatch")
            output.append((item, payload))
        return output

    def _validate_binding(self, data: dict, binding: dict, *, check_version: bool) -> dict:
        original = _lookup(data["managedDocuments"], binding["documentID"])
        if (
            original["storedName"] != binding["storedName"] or original["folderID"] != binding["folderID"]
            or (check_version and original["updatedAt"] != binding["updatedAt"])
        ):
            raise _error("request_conflict", "原件或版本在发起之后发生变化，请从当前原件重新发起。")
        source = read_bytes(self.store._document_path(original), MAX_FILE_BYTES)
        if sha256_bytes(source) != binding["sha256"]:
            raise AppError("checksum_mismatch")
        return original

    def _save_document(self, data, folder_id, item_id, name, payload, provenance=None, revision=None, original=None, dedup=False) -> tuple[dict, bool]:
        sha = sha256_bytes(payload)
        documents = data["managedDocuments"]
        if dedup:
            same_file = next((row for row in documents if row.get("folderID") == folder_id and row.get("sha256") == sha), None)
            if same_file:
                existing_path = self.store._document_path(same_file)
                if sha256_bytes(read_bytes(existing_path, MAX_FILE_BYTES)) != sha:
                    raise AppError("checksum_mismatch")
                return same_file, False
        filename = _name(name)
        extension = _extension(filename)
        stored_name = item_id + (f".{extension}" if re.fullmatch(r"[a-z0-9]{1,16}", extension) else "")
        destination = self.store._document_path({"folderID": folder_id, "storedName": stored_name})
        if destination.exists():
            if sha256_bytes(read_bytes(destination, MAX_FILE_BYTES)) != sha:
                raise AppError("request_conflict", 409)
        else:
            atomic_write(destination, payload)
        now = format_iso(self.store.clock())
        if provenance and "pages" in provenance:
            text = "\n\n".join(page["text"] for page in provenance["pages"] if page.get("status") == "completed" and page.get("text"))
        else:
            try:
                text = extract_text(destination)
            except AppError:
                text = None
        values = {
            "originalName": filename, "storedName": stored_name, "fileExtension": extension,
            "byteCount": len(payload), "updatedAt": now, "sha256": sha,
            "contentText": text or None, "contentIndexedAt": now if text else None,
        }
        if provenance is not None:
            values["windowsProvenance"] = provenance
        if revision is not None:
            values["windowsRevision"] = revision
        if original is not None:
            earlier = {key: original.get(key) for key in ("originalName", "storedName", "byteCount", "updatedAt", "sha256", "contentText",
                                                          "contentIndexedAt", "fileExtension", "windowsProvenance", "windowsRevision")}
            original.setdefault("windowsVersions", []).append(earlier)
            original.pop("windowsProvenance", None)
            original.update(values)
            return original, True
        if any(row.get("id") == item_id for row in documents):
            raise AppError("request_conflict", 409)
        orders = [row["sortOrder"] for row in documents if row.get("folderID") == folder_id and type(row.get("sortOrder")) is int]
        document = {"id": item_id, "folderID": folder_id, "displayName": Path(filename).stem,
                    "uploadedAt": now, "tags": ["OCR衍生件"] if (revision or {}).get("kind") == "ocrDerived" else [],
                    "sortOrder": max(orders, default=-1) + 1, **values}
        documents.append(document)
        return document, True

    def apply(self, value: str, approved, folder_id: str = "", selected=None, accept_partial=False) -> dict:
        if approved is not True:
            raise AppError("needs_confirmation")
        with REVIEW_LOCK:
            record = self._record("Incoming", value)
            data = self.store._data()
            receipts = self._business(write=True)
            manifest = record["manifest"]
            action, result_id = manifest["action"], identifier(manifest["requestID"])
            key = "envelope:" + result_id
            if key in receipts:
                if receipts[key].get("status") == "completed" and (not folder_id or folder_id == receipts[key].get("folderID")):
                    return {"duplicate": True, **receipts[key]["counts"]}
                raise AppError("request_conflict", 409)
            reserved = self._approval(record)
            if reserved is None:
                fresh(manifest, self.store.clock())
            provider_status = manifest.get("status")
            if manifest["kind"] == "result" and (action == EDIT or provider_status not in ("completed", "partial")):
                raise AppError("invalid_parameters")
            if reserved is None and (provider_status == "partial" or record["warnings"]) and accept_partial is not True:
                raise _error("needs_confirmation", "请明确确认部分结果和缺失来源信息。")
            payloads = self._stage_payload(record)
            if not payloads and not manifest["references"]:
                raise AppError("invalid_parameters")
            if action == OCR:
                plan, intent = self._ocr_plan(data, record, payloads)
                folder_id = ""
                selected_copies = []
            else:
                expected = reserved["intent"].get("folderID", "") if reserved else record.get("folderID", "")
                if expected and any(folder.get("id") == expected for folder in data["documentFolders"]):
                    if folder_id and expected != folder_id:
                        raise _error("request_conflict", "请选择发起文件选择时记录的资料文件夹。")
                    folder_id = expected
                _lookup(data["documentFolders"], folder_id)
                plan, intent, selected_copies = self._file_plan(data, record, payloads, folder_id, selected, reserved)
            if reserved and reserved["intent"] != intent:
                raise AppError("request_conflict", 409)
            job_key = "job:" + sha256_bytes(encode_json(intent, canonical=True))
            job = receipts.get(job_key)
            if job:
                self._validate_saved(data, job)
                counts = {"imported": 0, "existing": len(job["files"])}
                receipt_id = job["id"]
            else:
                if reserved is None:
                    self._save_intent(record, intent, selected_copies)
                try:
                    saved, imported = [], 0
                    for index, entry in enumerate(plan):
                        document, created = self._save_document(data, entry["folderID"], _uid(f"{job_key}:{index}"),
                                                                entry["name"], entry["payload"], entry.get("provenance"),
                                                                entry.get("revision"), dedup=action != OCR)
                        imported += int(created)
                        if action == OCR:
                            document["displayName"] = entry["displayName"]
                        saved.append({"id": document["id"], "sha256": document["sha256"]})
                    counts = {"imported": imported, "existing": len(saved) - imported}
                    receipt_id = _uid(job_key)
                    receipts[job_key] = {"id": receipt_id, "files": saved}
                except Exception:
                    self.store.library.open()
                    raise
            receipts[key] = {"id": receipt_id, "status": "completed", "manifestSHA256": record["manifestSHA256"],
                             "counts": counts, "folderID": folder_id, "savedAt": format_iso(self.store.clock())}
            try:
                self._commit()
            except Exception:
                self.store.library.open()
                raise
            self._discard_approval(record, len(selected_copies))
            return {"duplicate": job is not None, **counts}

    def _approval(self, record) -> dict | None:
        folder = self._root_path("Incoming", record["manifest"]["requestID"]) / "Approved"
        if not folder.exists():
            return None
        reservation = decode_json(read_bytes(folder / "record.json", MAX_REVIEW_METADATA))
        if reservation.get("manifestSHA256") != record["manifestSHA256"]:
            raise AppError("request_conflict", 409)
        return reservation

    def _discard_approval(self, record, reference_count) -> None:
        folder = self._root_path("Incoming", record["manifest"]["requestID"]) / "Approved"
        try:
            for index in range(reference_count):
                (folder / str(index)).unlink(missing_ok=True)
            (folder / "record.json").unlink(missing_ok=True)
            folder.rmdir()
        except OSError:
            pass

    def _save_intent(self, record, intent, references) -> None:
        folder = self._root_path("Incoming", record["manifest"]["requestID"])
        snapshots = [{"id": row["id"], "name": row["name"], "sha256": row["sha256"], "byteCount": row["byteCount"]} for row in references]
        encoded = encode_json({"manifestSHA256": record["manifestSHA256"], "intent": intent, "references": snapshots}, canonical=True)
        if len(encoded) > MAX_REVIEW_METADATA:
            raise AppError("payload_too_large")
        with tempfile.TemporaryDirectory(prefix=".approval-", dir=folder) as work:
            stage = Path(work) / "stage"
            for index, row in enumerate(references):
                atomic_write(stage / str(index), row["payload"])
            atomic_write(stage / "record.json", encoded)
            stage.rename(folder / "Approved")

    def _validate_saved(self, data, job) -> None:
        for row in job["files"]:
            document = _lookup(data["managedDocuments"], row["id"])
            if document.get("sha256") != row["sha256"] or sha256_bytes(read_bytes(self.store._document_path(document), MAX_FILE_BYTES)) != row["sha256"]:
                raise AppError("request_conflict", 409)

    def _ocr_plan(self, data, record, payloads) -> tuple[list, dict]:
        manifest = record["manifest"]
        session = self._record("Outgoing", manifest["inReplyTo"])
        bindings = {binding["itemID"]: binding for binding in session["bindings"]}
        content = {item["id"]: (item, payload) for item, payload in payloads}
        plan = []
        output_intents = []
        for output in sorted(record["outputs"], key=lambda row: row["itemID"]):
            binding = bindings[output["sourceItemID"]]
            original = self._validate_binding(data, binding, check_version=False)
            item, payload = content[output["itemID"]]
            extension = output["extension"]
            plan.append({"folderID": original["folderID"], "name": f"OCR-{_name(original['originalName'])}.{extension}",
                         "displayName": f"{original['displayName']}（OCR {extension}）", "payload": payload,
                         "provenance": {**output, "sourceBundleID": manifest["sourceBundleID"],
                                        "originalSHA256": binding["sha256"], "targetRecordID": original["id"],
                                        "status": manifest["status"]},
                         "revision": {"kind": "ocrDerived", "originalDocumentID": original["id"],
                                      "originalSHA256": binding["sha256"], "derivedSHA256": item["sha256"].lower()}})
            output_intents.append({**output, "sha256": item["sha256"].lower(), "byteCount": item["byteCount"], "folderID": original["folderID"]})
        if not plan:
            raise AppError("invalid_parameters")
        return plan, {"action": OCR, "requestID": session["manifest"]["requestID"], "provider": manifest["sourceBundleID"],
                      "status": manifest["status"], "outputs": output_intents, "sources": record.get("sources", []),
                      "warnings": record["warnings"]}

    def _file_plan(self, data, record, payloads, folder_id, selected, reserved):
        manifest = record["manifest"]
        request_id = identifier(manifest["requestID"])
        after = self._business().get("envelope:" + request_id)
        if after:
            raise AppError("request_conflict", 409)
        for earlier in data.get("windowsImportReceipts", []):
            if identifier(earlier["requestID"]) == request_id:
                if earlier["manifestSHA256"] != record["manifestSHA256"] or earlier["folderID"] != folder_id:
                    raise AppError("request_conflict", 409)
                if set(earlier.get("documentIDs", [])) - {
                    item["id"] for item in data["managedDocuments"] if item["folderID"] == folder_id
                }:
                    raise _error("request_conflict", "该旧交接已经完成，原导入条目后来被移除。")
        if selected is None:
            selected = {}
        if not isinstance(selected, dict) or not all(isinstance(path, str) and Path(path).is_absolute() for path in selected.values()):
            raise AppError("invalid_parameters")
        if reserved is None and set(selected) != {ref["id"] for ref in manifest["references"]}:
            raise _error("invalid_parameters", "请逐一复核引用并选择本机原件。")
        sources = [{"id": item["id"], "sha256": item["sha256"].lower(), "name": payload_parts(item["relativePath"])[-1],
                    "byteCount": item["byteCount"], "payload": payload} for item, payload in payloads]
        snapshots = []
        if reserved:
            directory = self._root_path("Incoming", request_id) / "Approved"
            for index, info in enumerate(reserved["references"]):
                payload = read_bytes(directory / str(index), MAX_FILE_BYTES, info["byteCount"])
                if sha256_bytes(payload) != info["sha256"]:
                    raise AppError("checksum_mismatch")
                snapshots.append({**info, "payload": payload})
        else:
            for ref in manifest["references"]:
                path = Path(selected[ref["id"]])
                payload = _chosen_reference(ref, path)
                snapshots.append({"id": ref["id"], "sha256": sha256_bytes(payload), "name": path.name,
                                  "byteCount": len(payload), "payload": payload})
        sources.extend(snapshots)
        ordered = sorted(sources, key=lambda row: row["id"])
        plan = [{"folderID": folder_id, "name": row["name"], "payload": row["payload"],
                 "provenance": {"sourceBundleID": manifest["sourceBundleID"], "originalSHA256": row["sha256"]}} for row in ordered]
        intent = {"action": manifest["action"], "folderID": folder_id,
                      "requestID": identifier(manifest.get("inReplyTo") or manifest["requestID"]),
                      "sources": [{"id": row["id"], "sha256": row["sha256"], "byteCount": row["byteCount"],
                                   "extension": _extension(row["name"])} for row in ordered]}
        return plan, intent, snapshots

    def reject(self, value: str, approved) -> dict:
        if approved is not True:
            raise AppError("needs_confirmation")
        with REVIEW_LOCK:
            record = self._record("Incoming", value)
            manifest = record["manifest"]
            if manifest["kind"] != "request":
                raise AppError("invalid_parameters")
            key = "envelope:" + identifier(manifest["requestID"])
            receipts = self._business(write=True)
            if key in receipts or self._approval(record) is not None:
                raise AppError("request_conflict", 409)
            receipts[key] = {"id": str(uuid.uuid4()), "status": "cancelled", "manifestSHA256": record["manifestSHA256"],
                             "counts": {"imported": 0, "existing": 0}, "savedAt": format_iso(self.store.clock())}
            try:
                self._commit()
            except Exception:
                self.store.library.open()
                raise
            return self._summary(record)

    def receipt(self, value: str, directory: Path | None = None, launch: bool = False) -> dict:
        with REVIEW_LOCK:
            record = self._record("Incoming", value)
            original = record["manifest"]
            if original["kind"] != "request":
                raise AppError("invalid_parameters")
            saved = self._business().get("envelope:" + identifier(original["requestID"]))
            if not saved:
                saved = {"id": _uid(value + ":pending"), "status": "pending", "counts": {"imported": 0, "existing": 0}}
            status, counts = saved["status"], saved["counts"]
            now = self.store.clock()
            manifest = envelope("result", original["action"], original["targetBundleID"], original["sourceBundleID"], now, {})
            workflow = "imported" if status == "completed" else status
            manifest.update({"inReplyTo": original["requestID"], "status": status, "provenance": {
                "requestManifestSHA256": record["manifestSHA256"], "workflowState": workflow,
                "receiptID": saved["id"], "saved": status == "completed", "importedCount": counts["imported"],
                "existingCount": counts["existing"],
                "sources": [{"sourceItemID": item["id"], "sourceSHA256": item["sha256"].lower(), "status": workflow}
                            for item in original["items"]],
            }})
            if directory is None:
                directory = self.root / "Receipts"
            elif not directory.is_absolute() or not directory.is_dir():
                raise AppError("unsafe_path")
            target = directory / f"Research-Receipt-{manifest['requestID']}.gaoaction"
            _package_write(target, manifest, [])
        message = "已导出交接回执。"
        if launch and original["sourceBundleID"] == "com.gaoseries.GaoWenJian":
            message = _launch_provider("GaoWenJian", target, manifest)
        return {"path": str(target), "status": status, "message": message}

    def edited_from_path(self, document_id: str, path: Path, mode: str, confirm) -> dict:
        if confirm is not True:
            raise AppError("needs_confirmation")
        if not path.is_absolute():
            raise AppError("unsafe_path")
        return self.edited_from_bytes(document_id, path.name, read_bytes(path, MAX_FILE_BYTES), mode, confirm)

    def edited_from_bytes(self, document_id: str, name: str, payload: bytes, mode: str, confirm) -> dict:
        if confirm is not True:
            raise AppError("needs_confirmation")
        if mode not in ("version", "attachment") or len(payload) > MAX_FILE_BYTES:
            raise AppError("invalid_parameters")
        with REVIEW_LOCK:
            data = self.store._data()
            original = _lookup(data["managedDocuments"], document_id)
            sessions = [row for row in self._records("Outgoing") if row["manifest"]["action"] == EDIT
                        and any(binding["documentID"] == document_id for binding in row["bindings"])]
            if not sessions:
                raise _error("not_found", "找不到该原件的外部编辑交接。请先发送原件的副本。", 404)
            session = sessions[0]
            binding = session["bindings"][0]
            digest = sha256_bytes(payload)
            version = session["manifest"]["requestID"]
            receipts = self._business(write=True)
            key = f"edit:{version}:{mode}:{digest}:{_extension(name)}"
            if key in receipts:
                self._validate_saved(data, receipts[key])
                return {"duplicate": True, "documentID": receipts[key]["files"][0]["id"]}
            original = self._validate_binding(data, binding, check_version=True)
            if digest == binding["sha256"]:
                raise _error("request_conflict", "所选文件和原件内容相同。")
            if _extension(name) != original["fileExtension"]:
                raise _error("invalid_parameters", "请选择与原件格式一致的编辑副本。")
            relation = {"kind": "editedVersion" if mode == "version" else "editedAttachment",
                        "originalDocumentID": original["id"], "originalSHA256": binding["sha256"], "derivedSHA256": digest,
                        "requestID": version}
            try:
                document, _saved = self._save_document(data, original["folderID"], _uid(key), name, payload,
                                                       {"originalSHA256": binding["sha256"], "targetRecordID": original["id"],
                                                        "sourceBundleID": session["manifest"]["targetBundleID"]},
                                                       relation, original=original if mode == "version" else None)
                receipts[key] = {"id": _uid(key), "files": [{"id": document["id"], "sha256": digest}]}
                self._commit()
            except Exception:
                self.store.library.open()
                raise
            return {"duplicate": False, "documentID": document["id"]}


def _ocr_review_sources(provenance: dict, bindings: list, outputs: list) -> list[dict]:
    reviews = []
    raw_sources = provenance.get("sources")
    for binding in bindings:
        source = next((row for row in raw_sources if isinstance(row, dict) and row.get("sourceItemID") == binding["itemID"]), None) if isinstance(raw_sources, list) else None
        pages = _pages(source.get("pages")) if source is not None else []
        for output in outputs:
            if output["sourceItemID"] == binding["itemID"]:
                pages = _merge_pages(pages, output["pages"])
        reviews.append({"sourceItemID": binding["itemID"], "sourceName": binding["name"], "sha256": binding["sha256"], "pages": pages})
    return reviews
