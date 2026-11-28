from __future__ import annotations

import hashlib
import json
import mimetypes
import os
import secrets
import shutil
import tempfile
import threading
from contextlib import ExitStack, suppress
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, quote, urlparse

from gaoyanjiu import APP_NAME, __build__, __version__
from gaoyanjiu.errors import AppError
from gaoyanjiu.exchange import ResearchExchange
from gaoyanjiu.i18n import translate
from gaoyanjiu.notifications import reminder_paper
from gaoyanjiu.portal import PortalBrowser
from gaoyanjiu.publishers import PUBLISHERS
from gaoyanjiu.store import ResearchStore, inspect_summary
from gaoyanjiu.win_icons import APP_ICON_FILE, application_icon_path
from gaoyanjiu.workspace import documents_workspace, merge_portal_capture, original_ocr_pdf, tag_counts, workspace_overview

UPLOAD_CAP = 256 * 1024 * 1024
REUSED_ASSETS = {
    "AcademicAchievementManagerIcon.png": "AcademicAchievementManagerIcon.png",
    "extractor.js": "extractor.js",
    "FloatingRockV354.png": "RewardCity/FloatingRockV354.png",
    "FloatingSkyV354.png": "RewardCity/FloatingSkyV354.png",
    "grass-3d-texture.png": "RewardCity/grass-3d-texture.png",
}
INLINE_TYPES = {
    ".pdf": "application/pdf", ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
    ".gif": "image/gif", ".webp": "image/webp", ".bmp": "image/bmp", ".avif": "image/avif",
}


def asset_dir() -> Path:
    import sys

    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS")) / "gaoyanjiu_assets"
    return Path(__file__).resolve().parent / "assets"


def failure_message(store: ResearchStore, error: AppError) -> str:
    if error.detail:
        return error.detail
    return translate(store.language() if store.library.data or store.settings else "zh-Hans", error.code)


class Api:
    def __init__(self, store: ResearchStore):
        self.store = store
        self.exchange = ResearchExchange(store)
        self.portal_browser = PortalBrowser(store, asset_dir())
        self.lock = threading.RLock()
        self.stopping = threading.Event()
        self.desktop = False

    def call(self, method: str, path: str, query: dict, body: dict | None) -> tuple[int, dict]:
        try:
            if path in {"/api/metrics/suggest", "/api/metrics/lookup"}:
                return self._call(method, path, query, body or {})
            with self.lock:
                if self.stopping.is_set() and method == "POST":
                    raise AppError("not_ready", 503)
                return self._call(method, path, query, body or {})
        except AppError as error:
            return error.status, {"error": error.code, "message": failure_message(self.store, error)}
        except (KeyError, TypeError, ValueError):
            return 400, {"error": "invalid_field", "message": translate(self.store.language(), "invalid_field")}
        except Exception:
            return 500, {"error": "unreadable", "message": translate(self.store.language(), "unreadable")}

    def _call(self, method: str, path: str, query: dict, body: dict) -> tuple[int, dict]:
        store = self.store
        if path.startswith("/api/exchange/"):
            return 200, self._exchange_call(method, path.removeprefix("/api/exchange/"), query, body)
        if path == "/api/bootstrap" and method == "GET":
            return 200, self._bootstrap()
        if path == "/api/library/create" and method == "POST":
            store.library.create_empty()
            store.purge_expired()
            _refresh_widget(store)
            if store.reminders:
                store.reminders.submit(store)
            return 200, self._bootstrap()
        if path == "/api/papers" and method == "GET":
            return 200, {
                "papers": store.list_papers(query.get("scope", "all"), query.get("q", "")),
                "followUpKeys": [paper["key"] for paper in store.follow_ups()],
                "nextActions": store.submission_actions(),
            }
        if path == "/api/papers/detail" and method == "GET":
            return 200, {"paper": store.paper_detail(query["key"])}
        if path == "/api/papers/next-action" and method == "POST":
            return 200, {"nextAction": store.change_submission_action(
                body["key"], body["operation"], body.get("revision"), body.get("text"), body.get("dueDate")
            )}
        if path == "/api/papers" and method == "POST":
            key = store.save_paper(
                body.get("key") or None,
                body.get("title") or "",
                body.get("venue") or "",
                body.get("manuscriptID") or "",
                body.get("status") or "",
                body.get("statusSince") or "",
                body.get("url") or "",
                body.get("notes") or "",
                bool(body.get("flagChanged")),
            )
            return 200, {"key": key}
        if path == "/api/papers/hidden" and method == "POST":
            store.set_hidden(body["key"], bool(body.get("hidden")))
            return 200, {"ok": True}
        if path == "/api/papers/read" and method == "POST":
            store.mark_paper_read(body["key"])
            return 200, {"ok": True}
        if path == "/api/reorder" and method == "POST":
            store.reorder(body["kind"], body["sourceID"], body["targetID"])
            return 200, {"ok": True}
        if path == "/api/papers/trash" and method == "POST":
            return 200, {"id": store.trash_paper(body["key"])}
        if path == "/api/works" and method == "GET":
            term = query.get("q", "")
            return 200, {"works": store.list_works(term), "analytics": store.work_analytics(term)}
        if path == "/api/works" and method == "POST":
            return 200, {"id": store.save_work(body)}
        if path == "/api/works/trash" and method == "POST":
            return 200, {"id": store.trash_work(body["id"])}
        if path == "/api/works/attachment-path" and method == "POST":
            attachment = store.add_attachment("work", body["ownerID"], Path(body["path"]))
            return 200, {"attachment": attachment}
        if path == "/api/documents" and method == "GET":
            return 200, documents_workspace(store, query.get("kind", "experimentData"), query.get("folder", ""),
                                            query.get("q", ""), query.get("view") == "folders")
        if path == "/api/documents/folder" and method == "POST":
            return 200, {"id": store.create_folder(body["kind"], body.get("name") or "", body.get("id"))}
        if path == "/api/documents/text" and method == "GET":
            from gaoyanjiu.store import _find

            row = _find(store._view()["managedDocuments"], "id", query["id"])
            return 200, {"text": row.get("contentText") or ""}
        if path == "/api/documents/ocr-source" and method == "GET":
            original, expected = original_ocr_pdf(store, query["id"])
            source = store.file_for_download("document", original["folderID"], original["storedName"])
            with source.open("rb") as stream:
                _verify_ocr_source(stream, expected)
            return 200, {"original": {key: original.get(key) for key in ("folderID", "storedName", "fileExtension", "originalName")}
                                      | {"ocrSource": query["id"]}}
        if path == "/api/documents/import-path" and method == "POST":
            tags = body.get("tags") or []
            return 200, store.import_path(body["folderID"], Path(body["path"]), tags)
        if path == "/api/documents/update" and method == "POST":
            store.update_document(body["id"], body.get("displayName") or "", body.get("tags") or [])
            return 200, {"ok": True}
        if path == "/api/documents/trash" and method == "POST":
            return 200, {"id": store.trash_document(body["id"])}
        if path == "/api/documents/folder/trash" and method == "POST":
            return 200, {"id": store.trash_folder(body["id"])}
        if path == "/api/certificates" and method == "GET":
            term = query.get("q", "")
            rows = store.list_certificates(term)
            return 200, {
                "certificates": rows,
                "analytics": {**store.certificate_analytics(term), "tags": tag_counts(rows)},
            }
        if path == "/api/certificates" and method == "POST":
            return 200, {"id": store.save_certificate(body)}
        if path == "/api/certificates/trash" and method == "POST":
            return 200, {"id": store.trash_certificate(body["id"])}
        if path == "/api/certificates/attachment-path" and method == "POST":
            return 200, {"attachment": store.add_attachment("certificate", body["ownerID"], Path(body["path"]))}
        if path == "/api/attachments/trash" and method == "POST":
            return 200, {"id": store.trash_attachment(body["kind"], body["ownerID"], body["attachmentID"])}
        if path == "/api/trash" and method == "GET":
            items = list((store.library.data or {}).get("trashItems") or [])
            items.sort(key=lambda item: str(item.get("deletedAt") or ""), reverse=True)
            return 200, {"items": items}
        if path == "/api/trash/restore" and method == "POST":
            store.restore(body["id"])
            return 200, {"ok": True}
        if path == "/api/trash/delete" and method == "POST":
            store.delete_forever(body["id"])
            return 200, {"ok": True}
        if path == "/api/trash/purge" and method == "POST":
            return 200, {"removed": store.purge_expired(int(body.get("days") or 30))}
        if path == "/api/reward" and method == "GET":
            return 200, store.reward_view()
        if path == "/api/reward/draw" and method == "POST":
            return 200, {"drawn": store.reward_draw(body["poolID"], int(body.get("count") or 1))}
        if path == "/api/reward/collect" and method == "POST":
            return 200, {"gained": store.reward_collect()}
        if path == "/api/reward/purchase" and method == "POST":
            store.reward_purchase(body["plotID"])
            return 200, {"ok": True}
        if path == "/api/reward/place" and method == "POST":
            return 200, {"placement": store.reward_place(
                body["catalogID"], body.get("plotID"), body.get("anchorRow"), body.get("anchorColumn"),
                body.get("rotationQuarterTurns", 0),
            )}
        if path == "/api/reward/move" and method == "POST":
            return 200, {"placement": store.reward_move(body["placementID"], body["anchorRow"], body["anchorColumn"])}
        if path == "/api/reward/rotate" and method == "POST":
            return 200, {"placement": store.reward_rotate(body["placementID"])}
        if path == "/api/reward/remove" and method == "POST":
            store.reward_remove(body["placementID"])
            return 200, {"ok": True}
        if path == "/api/reward/terrain" and method == "POST":
            return 200, {"terrain": store.reward_draw_terrain()}
        if path == "/api/reward/terrain/apply" and method == "POST":
            store.reward_apply_terrain(body["terrainID"], body["plotID"])
            return 200, {"ok": True}
        if path == "/api/reward/terrain/clear" and method == "POST":
            store.reward_clear_terrain(body["plotID"])
            return 200, {}
        if path == "/api/reward/terrain/move" and method == "POST":
            store.reward_move_terrain(body["sourcePlotID"], body["destinationPlotID"])
            return 200, {"ok": True}
        if path == "/api/publishers" and method == "GET":
            return 200, {"publishers": list(PUBLISHERS)}
        if path == "/api/portals" and method == "GET":
            portals = []
            for portal in (store.library.data or {}).get("portals") or []:
                copied = dict(portal)
                copied["hasPassword"] = store.portal_has_password(portal.get("id", ""))
                portals.append(copied)
            return 200, {"portals": portals}
        if path == "/api/portals" and method == "POST":
            return 200, {"id": store.save_portal(body)}
        if path == "/api/portals/delete" and method == "POST":
            store.delete_portal(body["id"])
            self.portal_browser.stop_portal(body["id"])
            return 200, {"ok": True}
        if path == "/api/portals/browser" and method == "GET":
            return 200, self.portal_browser.status(query.get("sessionId"))
        if path == "/api/portals/browser/open" and method == "POST":
            return 200, self.portal_browser.open(body.get("id"))
        if path == "/api/portals/browser/close" and method == "POST":
            return 200, self.portal_browser.close(body.get("sessionId"))
        if path == "/api/portals/capture" and method == "POST":
            return 200, merge_portal_capture(store, body["id"], body.get("capture"))
        if path == "/api/library/reload" and method == "POST":
            store.library.open()
            _refresh_widget(store)
            if store.reminders:
                store.reminders.submit(store)
            return 200, self._bootstrap()
        if path == "/api/files/reveal" and method == "POST":
            import subprocess

            if os.name != "nt":
                raise AppError("windows_only")
            if body.get("kind") == "root":
                os.startfile(store.library.root)
            else:
                target = store.file_for_download(body["kind"], body["ownerID"], body["name"])
                subprocess.Popen(["explorer.exe", f"/select,{target}"], close_fds=True)
            return 200, {"ok": True}
        if path == "/api/history" and method == "GET":
            return 200, store.history()
        if path == "/api/settings" and method == "GET":
            return 200, {
                "settings": store.settings,
                "hasEasyScholarKey": store.secrets.exists("easyscholar"),
                "dataDir": str(store.library.root),
            }
        if path == "/api/settings" and method == "POST":
            settings = store.update_settings(body.get("appearance"), body.get("language"), int(body.get("followUpDays")),
                                             body.get("notificationsEnabled"))
            return 200, {"settings": settings}
        if path == "/api/notifications/status" and method == "GET":
            worker = store.reminders
            return 200, worker.status() if worker else {"state": "unavailable", "count": 0}
        if path == "/api/notifications/paper" and method == "GET":
            return 200, {"paper": reminder_paper(store, query.get("ref", ""))}
        if path == "/api/widgets/publish" and method == "POST":
            return 200, store.write_snapshot()
        if path == "/api/widgets/open" and method == "POST":
            from gaoyanjiu.widget import launch_widget

            launch_widget(store.library.root, body.get("page"))
            return 200, {"ok": True}
        if path == "/api/secrets/easyscholar" and method == "POST":
            store.set_easyscholar_key(body.get("secret") or "")
            return 200, {"ok": True}
        if path == "/api/metrics/suggest" and method == "POST":
            return 200, {"suggestions": store.suggest(body.get("query") or "")}
        if path == "/api/metrics/lookup" and method == "POST":
            return 200, {"metrics": store.lookup_metrics(body.get("query") or "")}
        if path == "/api/gaoaction/path" and method == "POST":
            return 200, store.import_gaoaction(Path(body["path"]), body["folderID"])
        if path == "/api/search" and method == "GET":
            return 200, store.search(query.get("q", ""))
        if path == "/api/session/external" and method == "POST":
            from webbrowser import open as open_external

            url = body.get("url")
            parsed = urlparse(url) if isinstance(url, str) else None
            if (not parsed or parsed.scheme not in {"http", "https"} or not parsed.hostname
                    or parsed.username is not None or parsed.password is not None or any(ord(char) < 32 for char in url)):
                raise AppError("invalid_field")
            if not open_external(url):
                raise AppError("not_ready", 503)
            return 200, {"ok": True}
        if path == "/api/inspect" and method == "GET":
            if store.library.data is None:
                raise AppError(store.library.message_code or "not_ready", 409)
            return 200, inspect_summary(store.library.data)
        return 404, {"error": "not_found", "message": translate(store.language(), "not_found")}

    def _exchange_call(self, method: str, action: str, query: dict, body: dict) -> dict:
        exchange = self.exchange
        if method == "GET":
            if action == "overview":
                return exchange.overview()
            if action == "review":
                return exchange.review(query["id"])
            if action == "ocr-returns":
                return exchange.ocr_returns_state()
            if action == "ocr-source":
                original, _ = exchange.ocr_source(query["id"], query["sourceItemID"])
                return {"original": {field: original[field] for field in
                                     ("folderID", "storedName", "fileExtension", "originalName")}}
        if method == "POST":
            if action == "prepare":
                return exchange.prepare(body["action"], body.get("documentIDs"), body.get("folderID") or "",
                                        launch=body.get("launch") is not False, auto_return=body.get("autoReturn") is True)
            if action == "ocr-returns":
                return exchange.poll_ocr_returns()
            if action == "receive":
                return exchange.receive(Path(body["path"]))
            if action == "apply":
                return exchange.apply(body["id"], body.get("confirm"), body.get("folderID") or "",
                                      body.get("references"), body.get("acceptPartial"))
            if action == "reject":
                return exchange.reject(body["id"], body.get("confirm"))
            if action == "receipt":
                return exchange.receipt(body["id"], Path(body["directory"]) if body.get("directory") else None,
                                        launch=body.get("launch") is True)
            if action == "reveal":
                return exchange.reveal(body["id"])
            if action == "edited-path":
                return exchange.edited_from_path(body["id"], Path(body["path"]), body["mode"], body.get("confirm"))
        raise AppError("not_found", 404)

    def _bootstrap(self) -> dict:
        library = self.store.library
        return {
            "name": "搞研究",
            "version": __version__,
            "build": __build__,
            "desktop": self.desktop,
            "status": library.status,
            "message": translate("zh-Hans" if not self.store.settings else self.store.language(), library.message_code)
            if library.message_code
            else "",
            "writable": library.writable,
            "settings": self.store.settings,
            "counts": self.store.counts(),
            "overview": workspace_overview(self.store),
            "followUps": len(self.store.follow_ups()) if library.data else 0,
            "ocrReturns": self.exchange.ocr_returns_state() if library.data else {"waiting": False, "pending": []},
            "dataDir": str(library.root),
        }


def parse_multipart(body: bytes, boundary: str) -> dict:
    fence = boundary.encode("latin-1")
    payload = body
    if payload.startswith(b"--" + fence):
        payload = b"\r\n" + payload
    fields: dict[str, str] = {}
    files: dict[str, dict] = {}
    for chunk in payload.split(b"\r\n--" + fence):
        if not chunk or chunk.startswith(b"--"):
            continue
        chunk = chunk.lstrip(b"\r\n")
        header_blob, separator, content = chunk.partition(b"\r\n\r\n")
        if not separator:
            continue
        headers = header_blob.decode("utf-8", "replace")
        disposition = ""
        for line in headers.split("\r\n"):
            if line.lower().startswith("content-disposition:"):
                disposition = line
        name = _disposition_value(disposition, "name")
        filename = _disposition_value(disposition, "filename")
        if not name:
            continue
        if filename:
            files[name] = {"filename": Path(filename).name, "content": content}
        else:
            fields[name] = content.decode("utf-8")
    return {"fields": fields, "files": files}


def _disposition_value(header: str, key: str) -> str | None:
    token = f'{key}="'
    start = header.find(token)
    if start < 0:
        return None
    start += len(token)
    end = header.find('"', start)
    if end < 0:
        return None
    return header[start:end]


class ResearchHTTPServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, address, store: ResearchStore, token: str):
        super().__init__(address, ResearchHandler)
        self.store = store
        self.api = Api(store)
        self.token = token
        self.origin = f"http://127.0.0.1:{self.server_address[1]}/"
        self._desktop_lock = threading.RLock()
        self._route = ""
        self.browser = None
        self.tray = None

    def enable_desktop(self) -> None:
        if os.name != "nt" or self.api.stopping.is_set():
            return
        with self._desktop_lock:
            if self.browser is not None or self.api.stopping.is_set():
                return
            from gaoyanjiu.tray import TrayIcon
            from gaoyanjiu.workbench import WorkbenchBrowser

            self.browser = WorkbenchBrowser()
            self.tray = TrayIcon(APP_NAME, self.open_workbench, self.request_shutdown, language=self.store.language())
            self.tray.start()
            self.api.desktop = True

    def open_workbench(self, destination: str = "") -> bool:
        from gaoyanjiu.session import url_for

        with self._desktop_lock:
            if self.api.stopping.is_set():
                return True
            if self.browser is None:
                return False
            url = url_for(self.origin, destination)
            if self.browser.open(url) and destination:
                self._route = destination
            return True

    def take_route(self) -> str:
        with self._desktop_lock:
            route, self._route = self._route, ""
            return route

    def request_shutdown(self) -> None:
        # The same lock serializes library mutations and normal shutdown admission.
        with self.api.lock:
            if self.api.stopping.is_set():
                return
            self.api.stopping.set()
        threading.Thread(target=self.shutdown, name="GaoYanJiuShutdown", daemon=True).start()


class ResearchHandler(BaseHTTPRequestHandler):
    server: ResearchHTTPServer

    def log_message(self, fmt: str, *args) -> None:
        return

    def do_GET(self) -> None:
        self._dispatch()

    def do_POST(self) -> None:
        self._dispatch()

    def _dispatch(self) -> None:
        host = (self.headers.get("Host") or "").split(":")[0]
        if host not in {"127.0.0.1", "localhost"}:
            self._json(403, {"error": "unsafe_path", "message": "只接受本机访问。"})
            return
        parsed = urlparse(self.path)
        query = {key: values[-1] for key, values in parse_qs(parsed.query).items()}
        if parsed.path == "/" or parsed.path.startswith("/assets/"):
            self._static(parsed.path)
            return
        if not parsed.path.startswith("/api/"):
            self._json(404, {"error": "not_found", "message": "not found"})
            return
        supplied = self.headers.get("X-Gao-Token") or query.get("token")
        if supplied != self.server.token:
            self._json(401, {"error": "needs_confirmation", "message": "缺少本机会话令牌。"})
            return
        try:
            if parsed.path == "/api/download" and self.command == "GET":
                self._download(query)
                return
            body, uploaded = self._read_request()
        except AppError as error:
            self._json(error.status, {"error": error.code, "message": failure_message(self.server.store, error)})
            return
        if uploaded is not None:
            with self.server.api.lock:
                if self.server.api.stopping.is_set():
                    self._json(503, {"error": "not_ready", "message": translate(self.server.store.language(), "not_ready")})
                else:
                    self._upload(parsed.path, uploaded)
            return
        if self.command == "POST" and parsed.path == "/api/shutdown":
            try:
                self._json(200, {"ok": True})
            finally:
                self.server.request_shutdown()
            return
        if self.command == "POST" and parsed.path == "/api/session/open":
            from gaoyanjiu.session import valid_destination

            destination = body.get("destination", "")
            if not valid_destination(destination):
                self._json(400, {"error": "invalid_field", "message": translate(self.server.store.language(), "invalid_field")})
                return
            if body.get("desktop") is True:
                self.server.enable_desktop()
            self._json(200, {"handled": self.server.open_workbench(destination)})
            return
        if self.command == "GET" and parsed.path == "/api/session/route":
            self._json(200, {"destination": self.server.take_route(), "stopping": self.server.api.stopping.is_set()})
            return
        status, payload = self.server.api.call(self.command, parsed.path, query, body)
        self._json(status, payload)
        if status == 200 and self.command == "POST" and parsed.path == "/api/settings" and self.server.tray:
            self.server.tray.set_language(self.server.store.language())

    def _read_request(self) -> tuple[dict | None, dict | None]:
        try:
            length = int(self.headers.get("Content-Length") or "0")
        except ValueError as exc:
            raise AppError("invalid_field") from exc
        if length < 0 or length > UPLOAD_CAP:
            raise AppError("payload_too_large")
        raw = self.rfile.read(length) if length else b""
        content_type = self.headers.get("Content-Type") or ""
        if content_type.startswith("multipart/form-data"):
            boundary = ""
            for piece in content_type.split(";"):
                piece = piece.strip()
                if piece.startswith("boundary="):
                    boundary = piece.split("=", 1)[1].strip('"')
            if not boundary:
                raise AppError("invalid_field")
            return None, parse_multipart(raw, boundary)
        if not raw:
            return {}, None
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise AppError("invalid_field") from exc
        if not isinstance(parsed, dict):
            raise AppError("invalid_field")
        return parsed, None

    def _upload(self, path: str, uploaded: dict) -> None:
        files = uploaded["files"]
        fields = uploaded["fields"]
        if "file" not in files:
            self._json(400, {"error": "invalid_field", "message": failure_message(self.server.store, AppError("invalid_field"))})
            return
        blob = files["file"]["content"]
        if len(blob) > UPLOAD_CAP:
            self._json(400, {"error": "payload_too_large", "message": failure_message(self.server.store, AppError("payload_too_large"))})
            return
        handle, name = tempfile.mkstemp(prefix="gaoyanjiu-upload-")
        os.close(handle)
        temporary = Path(name)
        try:
            temporary.write_bytes(blob)
            store = self.server.store
            if path == "/api/exchange/edited":
                with self.server.api.lock:
                    result = self.server.api.exchange.edited_from_bytes(
                        fields["id"], files["file"]["filename"], blob, fields["mode"], fields.get("confirm") == "true"
                    )
                self._json(200, result)
                return
            if path == "/api/exchange/receive":
                package = temporary.with_suffix(".gaoaction.zip")
                shutil.move(temporary, package)
                temporary = package
                with self.server.api.lock:
                    result = self.server.api.exchange.receive(package)
                self._json(200, result)
                return
            if path == "/api/documents/import":
                tags = [part.strip() for part in fields.get("tags", "").replace("，", ",").split(",") if part.strip()]
                result = store.import_bytes(fields["folderID"], blob, files["file"]["filename"], tags)
                self._json(200, result)
                return
            if path == "/api/works/attachment":
                self._json(200, {"attachment": store.add_attachment("work", fields["ownerID"], temporary, files["file"]["filename"])})
                return
            if path == "/api/certificates/attachment":
                self._json(200, {"attachment": store.add_attachment("certificate", fields["ownerID"], temporary, files["file"]["filename"])})
                return
            if path == "/api/gaoaction/import":
                package = temporary.with_suffix(".gaoaction.zip")
                shutil.move(temporary, package)
                temporary = package
                self._json(200, store.import_gaoaction(package, fields["folderID"]))
                return
            self._json(404, {"error": "not_found", "message": "not found"})
        except AppError as error:
            self._json(error.status, {"error": error.code, "message": failure_message(self.server.store, error)})
        except (KeyError, TypeError, ValueError):
            self._json(400, {"error": "invalid_field", "message": failure_message(self.server.store, AppError("invalid_field"))})
        finally:
            if temporary.exists():
                temporary.unlink()

    def _download(self, query: dict) -> None:
        from gaoyanjiu.store import _find

        try:
            store = self.server.store
            kind, owner, name = (query.get(field, "") for field in ("kind", "owner", "name"))
            with self.server.api.lock:
                path = store.file_for_download(kind, owner, name)
                data = store._view()
                if kind == "document":
                    documents = [item for item in data["managedDocuments"] if item.get("folderID") == owner]
                    saved_versions = [version for item in documents for version in item.get("windowsVersions") or []]
                    row = _find(documents + saved_versions, "storedName", name)
                else:
                    record = _find(data["existingWorks" if kind == "work" else "certificates"], "id", owner)
                    row = _find(record.get("attachments") or [], "storedName", name)
                inline_type = INLINE_TYPES.get(path.suffix.lower()) if query.get("preview") == "1" else None
                if query.get("preview") == "1" and not inline_type:
                    raise AppError("invalid_field", 415)
                stream = path.open("rb")
                if any(field in query for field in ("ocrSource", "ocrReview", "ocrItem")):
                    try:
                        if query.get("ocrSource") and not {"ocrReview", "ocrItem"} & query.keys():
                            original, expected = original_ocr_pdf(store, query["ocrSource"])
                            valid_preview = inline_type == "application/pdf"
                        elif query.get("ocrReview") and query.get("ocrItem") and "ocrSource" not in query:
                            original, expected = self.server.api.exchange.ocr_source(query["ocrReview"], query["ocrItem"])
                            valid_preview = bool(inline_type)
                        else:
                            raise AppError("ocr_source_missing", 404)
                        if not valid_preview or (kind, owner, name) != ("document", original["folderID"], original["storedName"]):
                            raise AppError("ocr_source_missing", 404)
                        _verify_ocr_source(stream, expected)
                        stream.seek(0)
                    except Exception:
                        stream.close()
                        raise
        except AppError as error:
            self._json(error.status, {"error": error.code, "message": failure_message(self.server.store, error)})
            return
        except OSError:
            self._json(404, {"error": "not_found", "message": failure_message(self.server.store, AppError("not_found"))})
            return
        with stream:
            filename = quote(str(row.get("originalName") or path.name), safe="")
            self.send_response(200)
            self.send_header("Content-Type", inline_type or "application/octet-stream")
            self.send_header("Content-Length", str(os.fstat(stream.fileno()).st_size))
            self.send_header("Content-Disposition", f"{'inline' if inline_type else 'attachment'}; filename*=UTF-8''{filename}")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            shutil.copyfileobj(stream, self.wfile)

    def _static(self, path: str) -> None:
        root = asset_dir()
        if path == "/":
            target = root / "index.html"
            content = target.read_bytes().replace(b"__GAO_TOKEN__", self.server.token.encode("ascii"))
            mime = "text/html; charset=utf-8"
        else:
            name = path.removeprefix("/assets/")
            if name not in {APP_ICON_FILE, "app.js", "submissions.js", "records.js", "library-ui.js", "style.css", "submissions.css", "collections.css",
                            "exchange.js", "city.js", "city-scene.js", "city.css"} and name not in REUSED_ASSETS:
                self._json(404, {"error": "not_found", "message": "not found"})
                return
            target = application_icon_path() if name == APP_ICON_FILE else root / name
            if not target.is_file() and name in REUSED_ASSETS:
                target = root.parents[3] / "Resources" / REUSED_ASSETS[name]
            if not target.is_file():
                self._json(404, {"error": "not_found", "message": "not found"})
                return
            content = target.read_bytes()
            mime = mimetypes.guess_type(name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.end_headers()
        self.wfile.write(content)

    def _json(self, status: int, payload: dict) -> None:
        raw = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(raw)


def make_server(store: ResearchStore, host: str = "127.0.0.1", port: int = 0) -> ResearchHTTPServer:
    token = secrets.token_urlsafe(24)
    return ResearchHTTPServer((host, port), store, token)


def _refresh_widget(store: ResearchStore) -> None:
    if store.library.writable:
        try:
            store.write_snapshot()
        except OSError:
            pass


def _verify_ocr_source(stream, expected: str) -> None:
    if os.fstat(stream.fileno()).st_size > 128 * 1024 * 1024 or hashlib.file_digest(stream, "sha256").hexdigest() != expected:
        raise AppError("ocr_source_changed", 409)


def serve(store: ResearchStore, port: int = 0, open_browser: bool = True, lock_path: Path | None = None,
          destination: str = "", *, desktop_entry: bool = False) -> None:
    server = make_server(store, "127.0.0.1", port)

    def close_desktop():
        with server._desktop_lock:
            tray, browser = server.tray, server.browser
        try:
            if tray:
                tray.close()
        finally:
            if browser:
                browser.close()

    def close_workers():
        try:
            server.api.portal_browser.stop()
        finally:
            if store.reminders:
                store.reminders.close()

    with ExitStack() as cleanup:
        if lock_path is not None:
            cleanup.callback(lock_path.unlink, missing_ok=True)
        cleanup.callback(close_workers)
        cleanup.callback(close_desktop)
        cleanup.callback(server.server_close)
        if lock_path is not None:
            from gaoyanjiu.fsutil import atomic_write

            state = {"pid": os.getpid(), "url": server.origin, "token": server.token}
            atomic_write(lock_path, (json.dumps(state) + "\n").encode("utf-8"))
        if open_browser:
            if desktop_entry:
                server.enable_desktop()
            if not server.open_workbench(destination):
                from gaoyanjiu.session import open_application, url_for

                timer = threading.Timer(.2, lambda: open_application(url_for(server.origin, destination)))
                cleanup.callback(timer.cancel)
                timer.start()
        try:
            server.serve_forever()
        finally:
            normal_quit = server.api.stopping.is_set()
            server.api.stopping.set()
            if normal_quit:
                from gaoyanjiu.widget import signal_widget_shutdown

                with suppress(OSError):
                    signal_widget_shutdown(store.library.root, server.token)
