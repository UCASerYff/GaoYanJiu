from __future__ import annotations

from collections import Counter
from datetime import timedelta
from urllib.parse import urlsplit, urlunsplit

from gaoyanjiu.analytics import DOCUMENT_KINDS
from gaoyanjiu.errors import AppError
from gaoyanjiu.status import is_terminal
from gaoyanjiu.timeutil import format_iso, parse_iso


def workspace_overview(store) -> dict:
    data = store.library.data or {}
    papers = data.get("papers", [])
    visible = [paper for paper in papers if not paper.get("hidden")]
    works = data.get("existingWorks", [])
    certificates = data.get("certificates", [])
    folders = data.get("documentFolders", [])
    documents = data.get("managedDocuments", [])
    moments = [paper.get("checkedAt") for paper in visible if paper.get("checkedAt")]
    moments += [portal["lastChecked"] for portal in data.get("portals", []) if portal.get("lastChecked")]
    overview = {
        "submissions": {
            "count": len(visible),
            "changed": sum(bool(paper.get("changed")) for paper in visible),
            "hidden": len(papers) - len(visible),
            "active": sum(not is_terminal(str(paper.get("status") or "")) for paper in visible),
            "accepted": sum(any(word in str(paper.get("status") or "").lower() for word in
                                ("accept", "publish", "已接受", "接收", "录用", "已发表")) for paper in visible),
            "latest": max(moments, default=None),
        },
        "works": {
            "count": len(works),
            "attachments": sum(len(work.get("attachments") or []) for work in works),
            "thisYear": sum(str(work.get("completedAt") or "").startswith(str(store.clock().astimezone().year))
                            for work in works),
            "latest": _latest(works),
        },
        "certificates": {
            "count": len(certificates),
            "tags": len({tag for item in certificates for tag in item.get("tags") or []}),
            "attachments": sum(len(item.get("attachments") or []) for item in certificates),
            "latest": _latest(certificates),
        },
        "city": {"count": len((data.get("rewardCity") or {}).get("placements") or [])},
        "portals": len(data.get("portals", [])),
        "trash": len(data.get("trashItems", [])),
    }
    for kind in DOCUMENT_KINDS:
        group = [folder for folder in folders if folder.get("libraryKind") == kind]
        ids = {folder["id"] for folder in group}
        items = [document for document in documents if document.get("folderID") in ids]
        overview[kind] = {"count": len(items), "folders": len(group), "latest": _latest(group + items),
                          "tags": len({tag for item in items for tag in item.get("tags") or []})}
    return overview


def _latest(items: list[dict]) -> str | None:
    return max((item["updatedAt"] for item in items if item.get("updatedAt")), default=None)


def tag_counts(items: list[dict]) -> list[dict]:
    counts = Counter(tag for item in items for tag in set(item.get("tags") or []))
    return [{"label": tag, "count": count} for tag, count in sorted(counts.items(), key=lambda pair: (-pair[1], pair[0]))]


def documents_workspace(store, kind: str, folder_id: str, query: str, browse: bool) -> dict:
    folders = store.folders(kind)
    ids = {folder["id"] for folder in folders}
    if folder_id and folder_id not in ids:
        if not browse:
            raise AppError("not_found", 404)
        folder_id = ""
    if not (browse or folder_id) and folders:
        folder_id = folders[0]["id"]
    all_documents = (store.library.data or {}).get("managedDocuments", [])
    counts = Counter(row.get("folderID") for row in all_documents)
    matches = {row.get("folderID") for row in all_documents if query.casefold() in "\n".join(
        str(row.get(field) or "") for field in ("displayName", "originalName", "tags", "contentText")
    ).casefold() and row.get("folderID") in ids} if query else set()
    if query and not folder_id:
        folders = [folder for folder in folders if folder["id"] in matches or query.casefold() in folder["name"].casefold()]
    documents = store.documents_in(folder_id, query) if folder_id else []
    tags = tag_counts([row for row in all_documents if folder_id and row.get("folderID") == folder_id])
    return {
        "folderID": folder_id,
        "folders": [{**folder, "fileCount": counts[folder["id"]]} for folder in folders],
        "documents": [{key: value for key, value in document.items() if key != "contentText"} for document in documents],
        "tags": tags,
    }


def original_ocr_pdf(store, derivative_id: str) -> tuple[dict, str]:
    from gaoyanjiu.store import _find

    documents = store._view()["managedDocuments"]
    derivative = _find(documents, "id", derivative_id)
    provenance = derivative.get("windowsProvenance") or {}
    source_id = provenance.get("targetRecordID") or provenance.get("sourceDocumentID")
    digest = str(provenance.get("originalSHA256") or "").lower()
    if not source_id or len(digest) != 64 or not provenance.get("pages"):
        raise AppError("ocr_source_missing", 404)
    original = _find(documents, "id", source_id)
    if original.get("fileExtension", "").lower() != "pdf":
        raise AppError("ocr_source_missing", 404)
    return original, digest


def clean_web_url(value: str) -> str:
    try:
        url = urlsplit(value)
        if url.scheme not in {"https", "http"} or not url.hostname or url.username is not None or url.password is not None:
            raise ValueError
    except (TypeError, ValueError) as exc:
        raise AppError("invalid_field") from exc
    return urlunsplit((url.scheme, url.netloc, url.path, "", ""))


def _host(url: str) -> str:
    return (urlsplit(url).hostname or "").lower().removeprefix("www.")


def _checked(value, now):
    try:
        date = parse_iso(str(value or ""))
        return date if date <= now + timedelta(minutes=5) else now
    except ValueError:
        return now


def merge_portal_capture(store, portal_id: str, payload: dict) -> dict:
    from gaoyanjiu.store import TEXT_LIMIT, _clean, _find, _next_sort

    data = store._data()
    portal = _find(data["portals"], "id", portal_id)
    if not isinstance(payload, dict):
        raise AppError("invalid_field")
    url = clean_web_url(_clean(payload.get("url"), 2000))
    expected = clean_web_url(portal["url"])
    if _host(url) != _host(expected) or (expected.startswith("https:") and not url.startswith("https:")):
        raise AppError("portal_capture_origin")
    rows = payload.get("papers")
    if not isinstance(rows, list) or not 1 <= len(rows) <= 500:
        raise AppError("portal_capture_empty")
    now = store.clock()
    captured_at = _checked(payload.get("checkedAt"), now)
    checked_at = format_iso(captured_at)
    # Validate the entire reviewed capture before changing any state.
    incoming = {}
    for row in rows:
        if not isinstance(row, dict):
            raise AppError("invalid_field")
        values = {key: _clean(row.get(key), limit) for key, limit in (
            ("id", 160), ("title", 1200), ("journal", 500), ("status", 300),
            ("statusSinceSource", 500), ("submissionHistory", TEXT_LIMIT),
        )}
        if not values["id"] or not values["title"] or not values["status"] or values["id"] in incoming:
            raise AppError("invalid_field")
        values["statusSince"] = format_iso(_checked(row.get("statusSince"), captured_at))
        incoming[values["id"]] = values

    papers = data["papers"]
    matched = {paper.get("manuscriptID"): paper for paper in papers if paper.get("sourceID") == portal_id}
    new_count = changes = stale = 0
    site = portal.get("publisherName") or portal["name"]
    for manuscript_id, row in incoming.items():
        paper = matched.get(manuscript_id)
        if paper is None:
            same_title = [item for item in matched.values()
                          if str(item.get("title")).casefold() == row["title"].casefold() and
                          (manuscript_id.startswith("pending:") or str(item.get("manuscriptID")).startswith("pending:"))]
            paper = same_title[0] if len(same_title) == 1 else None
        if paper is None:
            paper = {"key": f"{portal_id}:{manuscript_id}", "sourceID": portal_id, "site": site, "url": url,
                     "manuscriptID": manuscript_id, "title": row["title"], "journal": row["journal"] or "未识别期刊",
                     "status": row["status"], "checkedAt": checked_at, "statusSince": row["statusSince"],
                     "statusSinceSource": row["statusSinceSource"] or "首次由系统发现", "previousStatus": None,
                     "changed": False, "hidden": False, "sortOrder": _next_sort(papers),
                     "history": [{"status": row["status"], "checkedAt": row["statusSince"]}],
                     "submissionHistory": row["submissionHistory"] or None}
            papers.append(paper)
            matched[manuscript_id] = paper
            new_count += 1
            continue
        if paper.get("checkedAt") and checked_at <= paper["checkedAt"]:
            stale += 1
            continue
        if not manuscript_id.startswith("pending:"):
            paper["manuscriptID"] = manuscript_id
        if paper.get("hidden"):
            continue
        if paper.get("status") != row["status"]:
            paper.update(previousStatus=paper.get("status"), status=row["status"], changed=True,
                         statusSince=checked_at, statusSinceSource="检测到状态变更")
            paper.setdefault("history", []).append({"status": row["status"], "checkedAt": checked_at})
            changes += 1
        paper.update(title=row["title"], journal=row["journal"] or paper.get("journal"), site=site, url=url,
                     checkedAt=checked_at)
        if row["submissionHistory"]:
            paper["submissionHistory"] = row["submissionHistory"]
    if not portal.get("lastChecked") or checked_at >= portal["lastChecked"]:
        portal.update(lastChecked=checked_at, lastError=None)
    store._commit()
    return {"reviewed": len(incoming), "imported": new_count, "changed": changes, "stale": stale}
