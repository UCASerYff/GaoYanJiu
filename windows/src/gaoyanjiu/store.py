from __future__ import annotations

import json
import random
import shutil
import uuid
from datetime import timedelta
from pathlib import Path

from gaoyanjiu.analytics import (
    DOCUMENT_KINDS,
    author_positions,
    certificate_years,
    chart_height,
    work_categories,
)
from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import atomic_write, is_regular_file, read_regular_bytes, safe_component, sha256_bytes
from gaoyanjiu.gaoaction import load_package
from gaoyanjiu.library import COLLECTIONS, Library
from gaoyanjiu.metrics import lookup_journal, suggest_journals
from gaoyanjiu.publishers import publisher_by_id
from gaoyanjiu.reward import (
    POOLS,
    apply_terrain,
    available_asset_count,
    available_terrain_count,
    clear_terrain,
    collect_coins,
    display_name,
    draw_rewards,
    draw_terrain,
    frontier,
    grant_certificate,
    grant_work,
    pending_coins,
    place_asset,
    purchase_plot,
    remove_placement,
    terrain_by_id,
)
from gaoyanjiu.reward import asset_by_id as reward_asset
from gaoyanjiu.status import is_terminal
from gaoyanjiu.textutil import extract_text
from gaoyanjiu.timeutil import format_iso, parse_date, parse_iso, utcnow

FILE_CAP = 512 * 1024 * 1024
TEXT_LIMIT = 100_000


def _clean(value: str, limit: int = 500) -> str:
    text = str(value or "").strip()
    if len(text) > limit:
        raise AppError("invalid_field")
    return text


def _matches(query: str, *parts) -> bool:
    needle = query.strip().casefold()
    if not needle:
        return True
    haystack = "\n".join(str(part or "") for part in parts).casefold()
    return needle in haystack


def _find(items: list, key: str, value: str) -> dict:
    for item in items:
        if item.get(key) == value:
            return item
    raise AppError("not_found", 404)


def _next_sort(items: list) -> int:
    orders = [item.get("sortOrder") for item in items if isinstance(item.get("sortOrder"), int)]
    return max(orders) + 1 if orders else 0


def inspect_summary(data: dict) -> dict:
    counts = {name: len(data.get(name) or []) for name in COLLECTIONS}
    attachments = 0
    for work in data.get("existingWorks") or []:
        attachments += len(work.get("attachments") or [])
    for record in data.get("certificates") or []:
        attachments += len(record.get("attachments") or [])
    attachments += len(data.get("managedDocuments") or [])
    reward = data.get("rewardCity") if isinstance(data.get("rewardCity"), dict) else {}
    return {
        "schema": data.get("version"),
        "counts": counts,
        "attachments": attachments,
        "rewardCityFields": sorted(reward.keys()),
    }


def widget_snapshot(data: dict, now) -> dict:
    papers = data.get("papers") or []
    active = [
        paper
        for paper in papers
        if not paper.get("hidden") and not is_terminal(str(paper.get("status") or ""))
    ]
    changed = [paper for paper in papers if paper.get("changed") and not paper.get("hidden")]
    return {
        "schema": 1,
        "platform": "windows",
        "generatedAt": format_iso(now),
        "activeSubmissions": len(active),
        "changedSubmissions": len(changed),
        "works": len(data.get("existingWorks") or []),
        "certificates": len(data.get("certificates") or []),
        "documents": len(data.get("managedDocuments") or []),
        "trash": len(data.get("trashItems") or []),
        "followUps": 0,
    }


class ResearchStore:
    def __init__(self, library: Library, secrets=None, clock=None, rng: random.Random | None = None):
        from gaoyanjiu.credentials import SecretStore

        self.library = library
        self.secrets = secrets or SecretStore(library.root)
        self.clock = clock or utcnow
        self.rng = rng or random.Random()
        self.settings = self._read_settings()

    def _data(self) -> dict:
        return self.library.require_writable()

    def _view(self) -> dict:
        if self.library.data is None:
            raise AppError(self.library.message_code or "not_ready", 409)
        return self.library.data

    def _commit(self) -> None:
        try:
            self.library.save()
            self.write_snapshot()
        except Exception:
            self.library.open()
            self.settings = self._read_settings()
            raise

    def _read_settings(self) -> dict:
        path = self.library.root / "settings.json"
        defaults = {"appearance": "system", "language": "zh-Hans", "followUpDays": 14}
        self.settings_blocked = False
        if not path.exists():
            return defaults
        try:
            parsed = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            self.settings_blocked = True
            return defaults
        if not isinstance(parsed, dict):
            self.settings_blocked = True
            return defaults
        appearance = parsed.get("appearance") if parsed.get("appearance") in {"light", "dark", "system"} else "system"
        language = parsed.get("language") if parsed.get("language") in {"zh-Hans", "en"} else "zh-Hans"
        days = parsed.get("followUpDays") if isinstance(parsed.get("followUpDays"), int) else 14
        days = min(365, max(1, days))
        return {"appearance": appearance, "language": language, "followUpDays": days}

    def update_settings(self, appearance: str, language: str, follow_up_days: int) -> dict:
        if self.settings_blocked:
            raise AppError("unreadable", 409)
        if appearance not in {"light", "dark", "system"} or language not in {"zh-Hans", "en"}:
            raise AppError("invalid_field")
        if not isinstance(follow_up_days, int) or not 1 <= follow_up_days <= 365:
            raise AppError("invalid_field")
        self.settings = {
            "appearance": appearance,
            "language": language,
            "followUpDays": follow_up_days,
        }
        atomic_write(
            self.library.root / "settings.json",
            (json.dumps(self.settings, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"),
        )
        return self.settings

    def language(self) -> str:
        return self.settings.get("language") or "zh-Hans"

    def write_snapshot(self) -> dict:
        if self.library.data is None:
            raise AppError("not_ready", 409)
        document = widget_snapshot(self.library.data, self.clock())
        document["followUps"] = len(self.follow_ups())
        atomic_write(
            self.library.root / "widget-snapshot.json",
            (json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8"),
        )
        return document

    def counts(self) -> dict:
        data = self.library.data or {}
        return {name: len(data.get(name) or []) for name in COLLECTIONS}

    def follow_ups(self) -> list[dict]:
        if not self.library.data:
            return []
        cutoff = self.clock() - timedelta(days=int(self.settings.get("followUpDays") or 14))
        rows = []
        for paper in self.library.data.get("papers") or []:
            if paper.get("hidden") or is_terminal(str(paper.get("status") or "")):
                continue
            try:
                since = parse_iso(str(paper.get("statusSince") or ""))
            except ValueError:
                continue
            if since <= cutoff:
                rows.append(paper)
        return rows

    def list_papers(self, scope: str = "all", query: str = "", include_hidden: bool = False) -> list[dict]:
        papers = list((self.library.data or {}).get("papers") or [])
        if scope == "hidden":
            papers = [paper for paper in papers if paper.get("hidden")]
        elif scope == "changed":
            papers = [paper for paper in papers if paper.get("changed") and not paper.get("hidden")]
        elif not include_hidden:
            papers = [paper for paper in papers if not paper.get("hidden")]
        papers = [
            paper
            for paper in papers
            if _matches(
                query,
                paper.get("title"),
                paper.get("journal"),
                paper.get("status"),
                paper.get("manuscriptID"),
                paper.get("submissionHistory"),
            )
        ]
        papers.sort(key=lambda paper: (paper.get("sortOrder") is None, paper.get("sortOrder") or 0))
        return papers

    def save_paper(
        self,
        existing_key: str | None,
        title: str,
        venue: str,
        manuscript_id: str,
        status: str,
        status_since: str,
        portal_url: str,
        notes: str,
        flag_changed: bool = False,
    ) -> str:
        data = self._data()
        clean_title = _clean(title)
        if not clean_title:
            raise AppError("empty_title")
        clean_status = _clean(status) or "已投稿"
        try:
            since = format_iso(parse_date(status_since))
        except ValueError as exc:
            raise AppError("invalid_field") from exc
        now = format_iso(self.clock())
        fields = {
            "title": clean_title,
            "journal": _clean(venue) or "未填写期刊或会议",
            "manuscriptID": _clean(manuscript_id) or "未填写",
            "status": clean_status,
            "statusSince": since,
            "statusSinceSource": "手动设置",
            "checkedAt": now,
            "url": _clean(portal_url, 2000),
            "submissionHistory": _clean(notes, TEXT_LIMIT) or None,
            "changed": bool(flag_changed),
        }
        if existing_key:
            paper = _find(data["papers"], "key", existing_key)
            if paper.get("status") != clean_status:
                paper["previousStatus"] = paper.get("status")
                history = paper.get("history")
                if not isinstance(history, list):
                    history = []
                    paper["history"] = history
                history.append({"status": clean_status, "checkedAt": since})
            paper.update(fields)
            self._commit()
            return existing_key
        key = f"manual:{uuid.uuid4()}"
        data["papers"].append(
            {
                "key": key,
                "sourceID": "manual",
                "site": "手动录入",
                "url": fields["url"],
                "manuscriptID": fields["manuscriptID"],
                "title": fields["title"],
                "journal": fields["journal"],
                "status": fields["status"],
                "checkedAt": now,
                "statusSince": since,
                "statusSinceSource": "手动设置",
                "previousStatus": None,
                "changed": bool(flag_changed),
                "hidden": False,
                "history": [{"status": clean_status, "checkedAt": since}],
                "submissionHistory": fields["submissionHistory"],
                "sortOrder": _next_sort(data["papers"]),
            }
        )
        self._commit()
        return key

    def set_hidden(self, key: str, hidden: bool) -> None:
        paper = _find(self._data()["papers"], "key", key)
        paper["hidden"] = bool(hidden)
        self._commit()

    def list_works(self, query: str = "") -> list[dict]:
        works = [
            work
            for work in (self.library.data or {}).get("existingWorks") or []
            if _matches(query, work.get("title"), work.get("venue"), work.get("authors"), work.get("identifier"), work.get("notes"))
        ]
        works.sort(key=lambda work: (work.get("sortOrder") is None, work.get("sortOrder") or 0))
        return works

    def work_analytics(self) -> dict:
        works = (self.library.data or {}).get("existingWorks") or []
        language = self.language()
        categories = work_categories(works, language)
        return {
            "categories": categories,
            "chartHeight": chart_height(len(categories)),
            "authorPositions": author_positions(works, language),
        }

    def save_work(self, payload: dict) -> str:
        data = self._data()
        title = _clean(payload.get("title") or "")
        if not title:
            raise AppError("empty_title")
        work_type = payload.get("type")
        from gaoyanjiu.analytics import AUTHOR_POSITIONS, PATENT_TYPES, WORK_TYPES

        if work_type not in WORK_TYPES:
            raise AppError("invalid_field")
        patent = payload.get("patentType") or None
        if work_type == "patent":
            if patent is not None and patent not in PATENT_TYPES:
                raise AppError("invalid_field")
        else:
            patent = None
        position = payload.get("authorPosition") or None
        if position is not None and position not in AUTHOR_POSITIONS:
            raise AppError("invalid_field")
        issn = _clean(payload.get("journalISSN") or "", 32) if work_type == "journalArticle" else ""
        metrics = payload.get("journalMetrics") if work_type == "journalArticle" else None
        if metrics is not None and not isinstance(metrics, dict):
            raise AppError("invalid_field")
        try:
            completed = format_iso(parse_date(str(payload.get("completedAt") or format_iso(self.clock()))))
        except ValueError as exc:
            raise AppError("invalid_field") from exc
        now = format_iso(self.clock())
        fields = {
            "title": title,
            "type": work_type,
            "venue": _clean(payload.get("venue") or "", 500),
            "authors": _clean(payload.get("authors") or "", 1000),
            "completedAt": completed,
            "identifier": _clean(payload.get("identifier") or "", 200),
            "url": _clean(payload.get("url") or "", 2000),
            "notes": _clean(payload.get("notes") or "", TEXT_LIMIT),
            "patentType": patent,
            "journalISSN": issn or None,
            "journalMetrics": metrics,
            "authorPosition": position,
            "updatedAt": now,
        }
        existing = payload.get("id")
        if existing:
            work = _find(data["existingWorks"], "id", existing)
            work.update(fields)
            self._commit()
            return existing
        work_id = str(uuid.uuid4())
        data["existingWorks"].append(
            {
                "id": work_id,
                "attachments": [],
                "createdAt": now,
                "sortOrder": _next_sort(data["existingWorks"]),
                **fields,
            }
        )
        grant_work(data, work_id, work_type)
        self._commit()
        return work_id

    def list_certificates(self, query: str = "") -> list[dict]:
        records = [
            record
            for record in (self.library.data or {}).get("certificates") or []
            if _matches(query, record.get("name"), " ".join(record.get("tags") or []))
        ]
        records.sort(key=lambda record: str(record.get("eventDate") or ""), reverse=True)
        return records

    def certificate_analytics(self) -> dict:
        records = (self.library.data or {}).get("certificates") or []
        return {"years": certificate_years(records)}

    def save_certificate(self, payload: dict) -> str:
        data = self._data()
        name = _clean(payload.get("name") or "")
        if not name:
            raise AppError("empty_title")
        tags = payload.get("tags") or []
        if isinstance(tags, str):
            tags = [part.strip() for part in tags.replace("，", ",").split(",")]
        if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
            raise AppError("invalid_field")
        tags = [tag.strip() for tag in tags if tag.strip()]
        if len(tags) > 32 or any(len(tag) > 64 for tag in tags):
            raise AppError("invalid_field")
        try:
            event = format_iso(parse_date(str(payload.get("eventDate") or format_iso(self.clock()))))
        except ValueError as exc:
            raise AppError("invalid_field") from exc
        now = format_iso(self.clock())
        existing = payload.get("id")
        if existing:
            record = _find(data["certificates"], "id", existing)
            record.update({"name": name, "eventDate": event, "tags": tags, "updatedAt": now})
            self._commit()
            return existing
        certificate_id = str(uuid.uuid4())
        data["certificates"].append(
            {
                "id": certificate_id,
                "name": name,
                "eventDate": event,
                "tags": tags,
                "attachments": [],
                "createdAt": now,
                "updatedAt": now,
            }
        )
        grant_certificate(data, certificate_id)
        self._commit()
        return certificate_id

    def _attachment_dir(self, kind: str, owner_id: str) -> Path:
        safe_component(owner_id)
        if kind == "work":
            return self.library.root / "Attachments" / owner_id
        if kind == "certificate":
            return self.library.root / "CertificateAttachments" / owner_id
        raise AppError("invalid_field")

    def add_attachment(self, kind: str, owner_id: str, source: Path, original_name: str | None = None) -> dict:
        data = self._data()
        if kind == "work":
            owner = _find(data["existingWorks"], "id", owner_id)
        elif kind == "certificate":
            owner = _find(data["certificates"], "id", owner_id)
        else:
            raise AppError("invalid_field")
        payload = read_regular_bytes(source, FILE_CAP)
        filename = Path(original_name or source.name).name
        extension = Path(filename).suffix.lower().lstrip(".")
        stored = str(uuid.uuid4()) + (f".{extension}" if extension.isascii() and extension.isalnum() and len(extension) <= 16 else "")
        kind_name = "pdf" if extension == "pdf" else "image" if extension in {"png", "jpg", "jpeg", "gif", "tif", "tiff", "webp", "bmp", "heic"} else "file"
        destination_dir = self._attachment_dir(kind, owner_id)
        destination_dir.mkdir(parents=True, exist_ok=True)
        destination = destination_dir / stored
        try:
            destination.write_bytes(payload)
            attachment = {
                "id": str(uuid.uuid4()),
                "originalName": filename,
                "storedName": stored,
                "kind": kind_name,
                "addedAt": format_iso(self.clock()),
            }
            owner.setdefault("attachments", []).append(attachment)
            self._commit()
        except Exception:
            if destination.exists():
                destination.unlink()
            raise
        return attachment

    def folders(self, kind: str) -> list[dict]:
        if kind not in DOCUMENT_KINDS:
            raise AppError("invalid_field")
        rows = [
            folder
            for folder in (self.library.data or {}).get("documentFolders") or []
            if folder.get("libraryKind") == kind
        ]
        rows.sort(key=lambda folder: (folder.get("sortOrder") is None, folder.get("sortOrder") or 0))
        return rows

    def documents_in(self, folder_id: str, query: str = "") -> list[dict]:
        rows = [
            document
            for document in (self.library.data or {}).get("managedDocuments") or []
            if document.get("folderID") == folder_id
            and _matches(query, document.get("displayName"), document.get("originalName"), " ".join(document.get("tags") or []), document.get("contentText"))
        ]
        rows.sort(key=lambda document: (document.get("sortOrder") is None, document.get("sortOrder") or 0))
        return rows

    def create_folder(self, kind: str, name: str) -> str:
        if kind not in DOCUMENT_KINDS:
            raise AppError("invalid_field")
        clean = _clean(name)
        if not clean:
            raise AppError("empty_title")
        data = self._data()
        now = format_iso(self.clock())
        folder_id = str(uuid.uuid4())
        data["documentFolders"].append(
            {
                "id": folder_id,
                "libraryKind": kind,
                "name": clean,
                "createdAt": now,
                "updatedAt": now,
                "sortOrder": _next_sort(self.folders(kind)),
            }
        )
        self._commit()
        return folder_id

    def _document_path(self, document: dict) -> Path:
        return self.library.root / "ManagedDocuments" / safe_component(document["folderID"]) / safe_component(document["storedName"])

    def import_bytes(self, folder_id: str, payload: bytes, original_name: str, tags: list[str] | None = None) -> dict:
        if len(payload) > FILE_CAP:
            raise AppError("payload_too_large")
        data = self._data()
        _find(data["documentFolders"], "id", folder_id)
        digest = sha256_bytes(payload)
        for document in data["managedDocuments"]:
            if document.get("folderID") == folder_id and document.get("sha256") == digest:
                return {"document": document, "imported": 0, "existing": 1}
        filename = Path(original_name).name or "file"
        extension = Path(filename).suffix.lower().lstrip(".")
        stored = str(uuid.uuid4()) + (f".{extension}" if extension.isascii() and extension.isalnum() and len(extension) <= 16 else "")
        destination_dir = self.library.root / "ManagedDocuments" / safe_component(folder_id)
        destination_dir.mkdir(parents=True, exist_ok=True)
        destination = destination_dir / stored
        destination.write_bytes(payload)
        content = None
        try:
            content = extract_text(destination)
        except AppError:
            content = None
        now = format_iso(self.clock())
        document = {
            "id": str(uuid.uuid4()),
            "folderID": folder_id,
            "originalName": filename,
            "displayName": Path(filename).stem or filename,
            "storedName": stored,
            "fileExtension": extension,
            "tags": tags or [],
            "byteCount": len(payload),
            "uploadedAt": now,
            "updatedAt": now,
            "contentText": content,
            "contentIndexedAt": now if content else None,
            "sortOrder": _next_sort([item for item in data["managedDocuments"] if item.get("folderID") == folder_id]),
            "sha256": digest,
        }
        try:
            data["managedDocuments"].append(document)
            self._commit()
        except Exception:
            if destination.exists():
                destination.unlink()
            if document in data["managedDocuments"]:
                data["managedDocuments"].remove(document)
            raise
        return {"document": document, "imported": 1, "existing": 0}

    def import_path(self, folder_id: str, source: Path, tags: list[str] | None = None) -> dict:
        payload = read_regular_bytes(Path(source), FILE_CAP)
        return self.import_bytes(folder_id, payload, Path(source).name, tags)

    def update_document(self, document_id: str, display_name: str, tags: list[str]) -> None:
        document = _find(self._data()["managedDocuments"], "id", document_id)
        clean = _clean(display_name)
        if not clean:
            raise AppError("empty_title")
        if not isinstance(tags, list) or any(not isinstance(tag, str) for tag in tags):
            raise AppError("invalid_field")
        document["displayName"] = clean
        document["tags"] = [tag.strip() for tag in tags if tag.strip()]
        document["updatedAt"] = format_iso(self.clock())
        self._commit()

    def import_gaoaction(self, package: Path, folder_id: str) -> dict:
        data = self._data()
        _find(data["documentFolders"], "id", folder_id)
        manifest, digest, staged = load_package(Path(package), self.clock())
        receipts = data.setdefault("windowsImportReceipts", [])
        if not isinstance(receipts, list):
            raise AppError("unreadable")
        for receipt in receipts:
            if receipt.get("requestID") == manifest["requestID"]:
                if receipt.get("manifestSHA256") == digest and receipt.get("folderID") == folder_id:
                    return {"imported": 0, "existing": len(receipt.get("documentIDs") or []), "duplicate": True}
                raise AppError("request_conflict", 409)
        imported = 0
        existing = 0
        document_ids = []
        created_paths = []
        try:
            for item, payload in staged:
                filename = Path(item["relativePath"]).name
                before = len(data["managedDocuments"])
                result = self._import_bytes_uncommitted(folder_id, payload, filename)
                if result["imported"]:
                    imported += 1
                    created_paths.append(result["path"])
                else:
                    existing += 1
                document_ids.append(result["document"]["id"])
                if len(data["managedDocuments"]) < before:
                    raise AppError("unreadable")
            receipts.append(
                {
                    "requestID": manifest["requestID"],
                    "manifestSHA256": digest,
                    "folderID": folder_id,
                    "documentIDs": document_ids,
                    "savedAt": format_iso(self.clock()),
                }
            )
            self._commit()
        except Exception:
            for path in created_paths:
                if path is not None and path.exists():
                    path.unlink()
            self.library.open()
            raise
        return {"imported": imported, "existing": existing, "duplicate": False}

    def _import_bytes_uncommitted(self, folder_id: str, payload: bytes, original_name: str) -> dict:
        data = self._data()
        digest = sha256_bytes(payload)
        for document in data["managedDocuments"]:
            if document.get("folderID") == folder_id and document.get("sha256") == digest:
                return {"document": document, "imported": 0, "path": None}
        filename = Path(original_name).name or "file"
        extension = Path(filename).suffix.lower().lstrip(".")
        stored = str(uuid.uuid4()) + (f".{extension}" if extension.isascii() and extension.isalnum() and len(extension) <= 16 else "")
        destination_dir = self.library.root / "ManagedDocuments" / safe_component(folder_id)
        destination_dir.mkdir(parents=True, exist_ok=True)
        destination = destination_dir / stored
        destination.write_bytes(payload)
        now = format_iso(self.clock())
        try:
            content = extract_text(destination)
        except AppError:
            content = None
        document = {
            "id": str(uuid.uuid4()),
            "folderID": folder_id,
            "originalName": filename,
            "displayName": Path(filename).stem or filename,
            "storedName": stored,
            "fileExtension": extension,
            "tags": [],
            "byteCount": len(payload),
            "uploadedAt": now,
            "updatedAt": now,
            "contentText": content,
            "contentIndexedAt": now if content else None,
            "sortOrder": _next_sort([item for item in data["managedDocuments"] if item.get("folderID") == folder_id]),
            "sha256": digest,
        }
        data["managedDocuments"].append(document)
        return {"document": document, "imported": 1, "path": destination}

    def save_portal(self, payload: dict) -> str:
        data = self._data()
        publisher_id = payload.get("publisherID") or "custom"
        built_in = publisher_by_id(publisher_id) if publisher_id != "custom" else None
        name = _clean(payload.get("name") or (built_in["name"] if built_in else ""))
        if not name:
            raise AppError("empty_title")
        url = _clean(payload.get("url") or (built_in["url"] if built_in else ""), 2000)
        if not url.startswith("https://") and not url.startswith("http://"):
            raise AppError("invalid_field")
        identity = _clean(payload.get("identity") or "", 320)
        now = format_iso(self.clock())
        existing = payload.get("id")
        if existing:
            portal = _find(data["portals"], "id", existing)
            portal.update(
                {
                    "name": name,
                    "url": url,
                    "identity": identity,
                    "publisherID": publisher_id,
                    "publisherName": built_in["name"] if built_in else name,
                    "kind": built_in["kind"] if built_in else "custom",
                }
            )
            portal_id = existing
        else:
            portal_id = str(uuid.uuid4())
            data["portals"].append(
                {
                    "id": portal_id,
                    "publisherID": publisher_id,
                    "publisherName": built_in["name"] if built_in else name,
                    "kind": built_in["kind"] if built_in else "custom",
                    "name": name,
                    "url": url,
                    "identity": identity,
                    "createdAt": now,
                    "lastChecked": None,
                    "lastError": None,
                }
            )
        password = payload.get("password")
        if isinstance(password, str) and password:
            self.secrets.set(f"portals/{portal_id}", password)
        self._commit()
        return portal_id

    def portal_has_password(self, portal_id: str) -> bool:
        return self.secrets.exists(f"portals/{portal_id}")

    def delete_portal(self, portal_id: str) -> None:
        data = self._data()
        before = len(data["portals"])
        data["portals"] = [portal for portal in data["portals"] if portal.get("id") != portal_id]
        if len(data["portals"]) == before:
            raise AppError("not_found", 404)
        self.secrets.delete(f"portals/{portal_id}")
        self._commit()

    def set_easyscholar_key(self, secret: str) -> None:
        self._data()
        if secret.strip():
            self.secrets.set("easyscholar", secret.strip())
        else:
            self.secrets.delete("easyscholar")

    def suggest(self, query: str, transport=None) -> list[dict]:
        return suggest_journals(query, transport=transport)

    def lookup_metrics(self, query: str, transport=None) -> dict:
        secret = self.secrets.get("easyscholar")
        return lookup_journal(query, secret, transport=transport, now=self.clock())

    def reward_view(self) -> dict:
        data = self._view()
        city = data.get("rewardCity") if isinstance(data.get("rewardCity"), dict) else {}
        unlocked = list(city.get("unlockedPlotIDs") or [])
        language = self.language()
        inventory = []
        for item in city.get("inventory") or []:
            asset = reward_asset(str(item.get("catalogID") or ""))
            if asset is None:
                continue
            inventory.append(
                {
                    "catalogID": asset["id"],
                    "name": display_name(asset, language),
                    "available": available_asset_count(city, asset["id"]),
                    "count": int(item.get("count") or 0),
                    "kind": asset["kind"],
                    "rarity": asset["rarity"],
                }
            )
        terrains = []
        for item in city.get("terrainInventory") or []:
            terrain = terrain_by_id(str(item.get("terrainID") or ""))
            if terrain is None:
                continue
            terrains.append(
                {
                    "terrainID": terrain["id"],
                    "available": available_terrain_count(city, terrain["id"]),
                    "kind": terrain["kind"],
                }
            )
        occupied = {
            f"{item.get('anchorRow')}:{item.get('anchorColumn')}": item
            for item in city.get("placements") or []
            if item.get("anchorRow") is not None
        }
        edge = frontier(unlocked)
        plots = []
        for plot_id in sorted(set(unlocked).union(edge)):
            placement = occupied.get(plot_id)
            asset = reward_asset(placement.get("catalogID")) if placement else None
            plots.append(
                {
                    "id": plot_id,
                    "unlocked": plot_id in unlocked,
                    "frontier": plot_id in edge,
                    "terrain": (city.get("plotTerrains") or {}).get(plot_id),
                    "placement": None
                    if placement is None
                    else {
                        "id": placement.get("id"),
                        "catalogID": placement.get("catalogID"),
                        "name": display_name(asset, language) if asset else placement.get("catalogID"),
                    },
                }
            )
        now = self.clock()
        return {
            "coins": city.get("coins") or 0,
            "pendingCoins": round(pending_coins(city, now), 4) if city else 0,
            "buildingTickets": city.get("buildingTickets") or 0,
            "decorationTickets": city.get("decorationTickets") or 0,
            "buildingPity": city.get("buildingPity") or 0,
            "decorationPity": city.get("decorationPity") or 0,
            "plots": plots,
            "inventory": inventory,
            "terrains": terrains,
            "pools": [{"id": pool["id"], "kind": pool["kind"], "title": pool["titleEn"] if language == "en" else pool["title"]} for pool in POOLS],
        }

    def reward_draw(self, pool_id: str, count: int = 1) -> list[dict]:
        data = self._data()
        drawn = draw_rewards(data, pool_id, count, self.rng)
        self._commit()
        return drawn

    def reward_collect(self) -> float:
        data = self._data()
        gained = collect_coins(data, self.clock())
        self._commit()
        return gained

    def reward_purchase(self, plot_id: str) -> None:
        purchase_plot(self._data(), plot_id)
        self._commit()

    def reward_place(self, catalog_id: str, plot_id: str) -> dict:
        placement = place_asset(self._data(), catalog_id, plot_id, self.clock(), str(uuid.uuid4()))
        self._commit()
        return placement

    def reward_remove(self, placement_id: str) -> None:
        remove_placement(self._data(), placement_id)
        self._commit()

    def reward_draw_terrain(self) -> dict:
        terrain = draw_terrain(self._data(), self.rng)
        self._commit()
        return terrain

    def reward_apply_terrain(self, terrain_id: str, plot_id: str) -> None:
        apply_terrain(self._data(), terrain_id, plot_id)
        self._commit()

    def reward_clear_terrain(self, plot_id: str) -> None:
        clear_terrain(self._data(), plot_id)
        self._commit()

    def history(self) -> dict:
        data = self.library.data or {}
        return {
            "projects": list(data.get("projects") or []),
            "fundingRecords": list(data.get("fundingRecords") or []),
        }

    def search(self, query: str) -> dict:
        return {
            "papers": self.list_papers("all", query) + self.list_papers("hidden", query),
            "works": self.list_works(query),
            "certificates": self.list_certificates(query),
            "documents": [
                document
                for document in (self.library.data or {}).get("managedDocuments") or []
                if _matches(
                    query,
                    document.get("displayName"),
                    document.get("originalName"),
                    document.get("contentText"),
                    " ".join(document.get("tags") or []),
                )
            ],
        }

    def _trash_item(self, kind: str, title: str, **payload) -> dict:
        item = {
            "id": str(uuid.uuid4()),
            "kind": kind,
            "title": title,
            "deletedAt": format_iso(self.clock()),
            "paper": None,
            "work": None,
            "project": None,
            "documentFolder": None,
            "documents": [],
            "certificate": None,
            "funding": None,
            "attachment": None,
            "parentID": None,
        }
        item.update(payload)
        return item

    def _copy_named(self, source_dir: Path, names: list[str], trash_id: str, exact: bool) -> None:
        if any(not isinstance(name, str) for name in names):
            raise AppError("unsafe_path")
        if source_dir.exists():
            present = [entry.name for entry in source_dir.iterdir()]
            if exact and set(present) != set(names):
                raise AppError("unsafe_file")
        elif names:
            raise AppError("attachment_missing")
        if not names:
            return
        destination = self.library.root / "TrashStorage" / trash_id
        destination.mkdir(parents=True, exist_ok=True)
        for name in names:
            source = source_dir / safe_component(name)
            if not is_regular_file(source):
                raise AppError("attachment_missing")
            blob = read_regular_bytes(source, FILE_CAP)
            (destination / safe_component(name)).write_bytes(blob)

    def _finish_trash(self, item: dict, source_dir: Path | None, names: list[str], mutate, exact: bool = True) -> None:
        if source_dir is not None:
            self._copy_named(source_dir, names, item["id"], exact)
        data = self._data()
        mutate(data)
        data["trashItems"].append(item)
        try:
            self._commit()
        except Exception:
            shutil.rmtree(self.library.root / "TrashStorage" / item["id"], ignore_errors=True)
            raise
        if source_dir is not None and names:
            for name in names:
                file_path = source_dir / name
                if file_path.exists():
                    file_path.unlink()
            if source_dir.exists() and not any(source_dir.iterdir()):
                source_dir.rmdir()

    def trash_paper(self, key: str) -> str:
        paper = _find(self._data()["papers"], "key", key)
        item = self._trash_item("submission", str(paper.get("title") or "在投论文"), paper=paper)

        def mutate(data: dict) -> None:
            data["papers"] = [existing for existing in data["papers"] if existing.get("key") != key]

        self._finish_trash(item, None, [], mutate)
        return item["id"]

    def trash_work(self, work_id: str) -> str:
        work = _find(self._data()["existingWorks"], "id", work_id)
        names = [attachment.get("storedName") for attachment in work.get("attachments") or []]
        item = self._trash_item("work", str(work.get("title") or "成果"), work=work)

        def mutate(data: dict) -> None:
            data["existingWorks"] = [existing for existing in data["existingWorks"] if existing.get("id") != work_id]

        self._finish_trash(item, self.library.root / "Attachments" / work_id, names, mutate)
        return item["id"]

    def trash_certificate(self, certificate_id: str) -> str:
        record = _find(self._data()["certificates"], "id", certificate_id)
        names = [attachment.get("storedName") for attachment in record.get("attachments") or []]
        item = self._trash_item("certificate", str(record.get("name") or "证书"), certificate=record)

        def mutate(data: dict) -> None:
            data["certificates"] = [existing for existing in data["certificates"] if existing.get("id") != certificate_id]

        self._finish_trash(item, self.library.root / "CertificateAttachments" / certificate_id, names, mutate)
        return item["id"]

    def trash_attachment(self, kind: str, owner_id: str, attachment_id: str) -> str:
        data = self._data()
        if kind == "work":
            owner = _find(data["existingWorks"], "id", owner_id)
            trash_kind = "workAttachment"
        elif kind == "certificate":
            owner = _find(data["certificates"], "id", owner_id)
            trash_kind = "certificateAttachment"
        else:
            raise AppError("invalid_field")
        attachment = _find(owner.get("attachments") or [], "id", attachment_id)
        item = self._trash_item(
            trash_kind,
            str(attachment.get("originalName") or "附件"),
            attachment=attachment,
            parentID=owner_id,
        )
        source = self._attachment_dir(kind, owner_id)

        def mutate(current: dict) -> None:
            if kind == "work":
                parent = _find(current["existingWorks"], "id", owner_id)
            else:
                parent = _find(current["certificates"], "id", owner_id)
            parent["attachments"] = [existing for existing in parent.get("attachments") or [] if existing.get("id") != attachment_id]

        self._finish_trash(item, source, [attachment["storedName"]], mutate, exact=False)
        return item["id"]

    def trash_document(self, document_id: str) -> str:
        document = _find(self._data()["managedDocuments"], "id", document_id)
        item = self._trash_item("document", str(document.get("displayName") or "资料"), documents=[document])
        source = self.library.root / "ManagedDocuments" / document["folderID"]

        def mutate(data: dict) -> None:
            data["managedDocuments"] = [existing for existing in data["managedDocuments"] if existing.get("id") != document_id]

        self._finish_trash(item, source, [document["storedName"]], mutate, exact=False)
        return item["id"]

    def trash_folder(self, folder_id: str) -> str:
        data = self._data()
        folder = _find(data["documentFolders"], "id", folder_id)
        documents = [item for item in data["managedDocuments"] if item.get("folderID") == folder_id]
        item = self._trash_item(
            "documentFolder",
            str(folder.get("name") or "文件夹"),
            documentFolder=folder,
            documents=documents,
        )

        def mutate(current: dict) -> None:
            current["documentFolders"] = [existing for existing in current["documentFolders"] if existing.get("id") != folder_id]
            current["managedDocuments"] = [existing for existing in current["managedDocuments"] if existing.get("folderID") != folder_id]

        self._finish_trash(
            item,
            self.library.root / "ManagedDocuments" / folder_id,
            [document["storedName"] for document in documents],
            mutate,
        )
        return item["id"]

    def restore(self, trash_id: str) -> None:
        data = self._data()
        item = _find(data["trashItems"], "id", trash_id)
        self._restore_written: list[Path] = []
        kind = item.get("kind")
        if kind == "submission":
            paper = item.get("paper") or {}
            if any(existing.get("key") == paper.get("key") for existing in data["papers"]):
                raise AppError("conflict", 409)
            data["papers"].append(paper)
        elif kind == "work":
            work = item.get("work") or {}
            if any(existing.get("id") == work.get("id") for existing in data["existingWorks"]):
                raise AppError("conflict", 409)
            self._restore_files(item["id"], self.library.root / "Attachments" / work["id"], [a["storedName"] for a in work.get("attachments") or []])
            data["existingWorks"].append(work)
        elif kind == "certificate":
            record = item.get("certificate") or {}
            if any(existing.get("id") == record.get("id") for existing in data["certificates"]):
                raise AppError("conflict", 409)
            self._restore_files(
                item["id"],
                self.library.root / "CertificateAttachments" / record["id"],
                [a["storedName"] for a in record.get("attachments") or []],
            )
            data["certificates"].append(record)
        elif kind == "document":
            documents = item.get("documents") or []
            if len(documents) != 1:
                raise AppError("missing_parent")
            document = documents[0]
            if not any(folder.get("id") == document.get("folderID") for folder in data["documentFolders"]):
                raise AppError("missing_parent")
            if any(existing.get("id") == document.get("id") for existing in data["managedDocuments"]):
                raise AppError("conflict", 409)
            self._restore_files(
                item["id"],
                self.library.root / "ManagedDocuments" / document["folderID"],
                [document["storedName"]],
            )
            data["managedDocuments"].append(document)
        elif kind == "documentFolder":
            folder = item.get("documentFolder") or {}
            if any(existing.get("id") == folder.get("id") for existing in data["documentFolders"]):
                raise AppError("conflict", 409)
            documents = item.get("documents") or []
            self._restore_files(
                item["id"],
                self.library.root / "ManagedDocuments" / folder["id"],
                [document["storedName"] for document in documents],
            )
            data["documentFolders"].append(folder)
            data["managedDocuments"].extend(documents)
        elif kind in {"workAttachment", "certificateAttachment"}:
            attachment = item.get("attachment") or {}
            parent_id = item.get("parentID")
            if kind == "workAttachment":
                parent = _find(data["existingWorks"], "id", parent_id)
                destination = self.library.root / "Attachments" / parent_id
            else:
                parent = _find(data["certificates"], "id", parent_id)
                destination = self.library.root / "CertificateAttachments" / parent_id
            if any(existing.get("id") == attachment.get("id") or existing.get("storedName") == attachment.get("storedName") for existing in parent.get("attachments") or []):
                raise AppError("conflict", 409)
            self._restore_files(item["id"], destination, [attachment["storedName"]])
            parent.setdefault("attachments", []).append(attachment)
        elif kind == "project":
            project = item.get("project") or {}
            if any(existing.get("id") == project.get("id") for existing in data["projects"]):
                raise AppError("conflict", 409)
            data["projects"].append(project)
        elif kind == "funding":
            record = item.get("funding") or {}
            if any(existing.get("id") == record.get("id") for existing in data["fundingRecords"]):
                raise AppError("conflict", 409)
            data["fundingRecords"].append(record)
        else:
            raise AppError("invalid_field")
        data["trashItems"] = [existing for existing in data["trashItems"] if existing.get("id") != trash_id]
        try:
            self._commit()
        except Exception:
            for path in self._restore_written:
                if path.exists():
                    path.unlink()
            raise
        shutil.rmtree(self.library.root / "TrashStorage" / trash_id, ignore_errors=True)

    def _restore_files(self, trash_id: str, destination: Path, names: list[str]) -> None:
        if not names:
            return
        source = self.library.root / "TrashStorage" / trash_id
        destination.mkdir(parents=True, exist_ok=True)
        try:
            for name in names:
                safe_component(name)
                origin = source / name
                target = destination / name
                if target.exists():
                    raise AppError("conflict", 409)
                if not is_regular_file(origin):
                    raise AppError("attachment_missing")
                target.write_bytes(read_regular_bytes(origin, FILE_CAP))
                self._restore_written.append(target)
        except Exception:
            for path in list(getattr(self, "_restore_written", [])):
                if path.exists():
                    path.unlink()
            self._restore_written = []
            raise

    def delete_forever(self, trash_id: str) -> None:
        data = self._data()
        if not any(item.get("id") == trash_id for item in data["trashItems"]):
            raise AppError("not_found", 404)
        data["trashItems"] = [item for item in data["trashItems"] if item.get("id") != trash_id]
        self._commit()
        shutil.rmtree(self.library.root / "TrashStorage" / trash_id, ignore_errors=True)

    def purge_expired(self, days: int = 30) -> int:
        data = self._data()
        cutoff = self.clock() - timedelta(days=days)
        removed = []
        kept = []
        for item in data["trashItems"]:
            try:
                deleted = parse_iso(str(item.get("deletedAt") or ""))
            except ValueError:
                kept.append(item)
                continue
            if deleted < cutoff:
                removed.append(item)
            else:
                kept.append(item)
        if not removed:
            return 0
        data["trashItems"] = kept
        self._commit()
        for item in removed:
            shutil.rmtree(self.library.root / "TrashStorage" / item["id"], ignore_errors=True)
        return len(removed)

    def file_for_download(self, kind: str, owner_id: str, stored_name: str) -> Path:
        safe_component(owner_id)
        safe_component(stored_name)
        if kind == "work":
            path = self.library.root / "Attachments" / owner_id / stored_name
        elif kind == "certificate":
            path = self.library.root / "CertificateAttachments" / owner_id / stored_name
        elif kind == "document":
            path = self.library.root / "ManagedDocuments" / owner_id / stored_name
        else:
            raise AppError("invalid_field")
        if not is_regular_file(path):
            raise AppError("not_found", 404)
        resolved = path.resolve()
        root = self.library.root.resolve()
        if root not in resolved.parents:
            raise AppError("unsafe_path")
        return resolved
