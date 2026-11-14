from __future__ import annotations

import json
import mimetypes
import secrets
import shutil
import tempfile
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

from gaoyanjiu import __build__, __version__
from gaoyanjiu.errors import AppError
from gaoyanjiu.i18n import translate
from gaoyanjiu.publishers import PUBLISHERS
from gaoyanjiu.store import ResearchStore, inspect_summary

UPLOAD_CAP = 256 * 1024 * 1024


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

    def call(self, method: str, path: str, query: dict, body: dict | None) -> tuple[int, dict]:
        try:
            return self._call(method, path, query, body or {})
        except AppError as error:
            return error.status, {"error": error.code, "message": failure_message(self.store, error)}
        except Exception:
            return 500, {"error": "unreadable", "message": translate(self.store.language(), "unreadable")}

    def _call(self, method: str, path: str, query: dict, body: dict) -> tuple[int, dict]:
        store = self.store
        if path == "/api/bootstrap" and method == "GET":
            return 200, self._bootstrap()
        if path == "/api/library/create" and method == "POST":
            store.library.create_empty()
            store.purge_expired()
            return 200, self._bootstrap()
        if path == "/api/papers" and method == "GET":
            return 200, {"papers": store.list_papers(query.get("scope", "all"), query.get("q", ""))}
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
        if path == "/api/papers/trash" and method == "POST":
            return 200, {"id": store.trash_paper(body["key"])}
        if path == "/api/works" and method == "GET":
            return 200, {"works": store.list_works(query.get("q", "")), "analytics": store.work_analytics()}
        if path == "/api/works" and method == "POST":
            return 200, {"id": store.save_work(body)}
        if path == "/api/works/trash" and method == "POST":
            return 200, {"id": store.trash_work(body["id"])}
        if path == "/api/works/attachment-path" and method == "POST":
            attachment = store.add_attachment("work", body["ownerID"], Path(body["path"]))
            return 200, {"attachment": attachment}
        if path == "/api/documents" and method == "GET":
            kind = query.get("kind", "experimentData")
            folders = store.folders(kind)
            folder_id = query.get("folder") or (folders[0]["id"] if folders else "")
            documents = store.documents_in(folder_id, query.get("q", "")) if folder_id else []
            return 200, {"folders": folders, "documents": documents, "folderID": folder_id}
        if path == "/api/documents/folder" and method == "POST":
            return 200, {"id": store.create_folder(body["kind"], body.get("name") or "")}
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
            return 200, {
                "certificates": store.list_certificates(query.get("q", "")),
                "analytics": store.certificate_analytics(),
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
            return 200, {"placement": store.reward_place(body["catalogID"], body["plotID"])}
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
            settings = store.update_settings(body.get("appearance"), body.get("language"), int(body.get("followUpDays")))
            return 200, {"settings": settings}
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
        if path == "/api/inspect" and method == "GET":
            if store.library.data is None:
                raise AppError(store.library.message_code or "not_ready", 409)
            return 200, inspect_summary(store.library.data)
        if path == "/api/shutdown" and method == "POST":
            return 200, {"ok": True}
        return 404, {"error": "not_found", "message": translate(store.language(), "not_found")}

    def _bootstrap(self) -> dict:
        library = self.store.library
        return {
            "name": "搞研究",
            "version": __version__,
            "build": __build__,
            "status": library.status,
            "message": translate("zh-Hans" if not self.store.settings else self.store.language(), library.message_code)
            if library.message_code
            else "",
            "writable": library.writable,
            "settings": self.store.settings,
            "counts": self.store.counts(),
            "followUps": len(self.store.follow_ups()) if library.data else 0,
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
        self.shutdown_requested = False


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
            self._upload(parsed.path, uploaded)
            return
        status, payload = self.server.api.call(self.command, parsed.path, query, body)
        self._json(status, payload)
        if status == 200 and parsed.path == "/api/shutdown":
            threading.Thread(target=self.server.shutdown, daemon=True).start()

    def _read_request(self) -> tuple[dict | None, dict | None]:
        length = int(self.headers.get("Content-Length") or "0")
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
        temporary = Path(tempfile.mkstemp(prefix="gaoyanjiu-upload-")[1])
        try:
            temporary.write_bytes(blob)
            store = self.server.store
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
        finally:
            if temporary.exists():
                temporary.unlink()

    def _download(self, query: dict) -> None:
        try:
            path = self.server.store.file_for_download(query.get("kind", ""), query.get("owner", ""), query.get("name", ""))
        except AppError as error:
            self._json(error.status, {"error": error.code, "message": failure_message(self.server.store, error)})
            return
        payload = path.read_bytes()
        mime = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Content-Disposition", f'attachment; filename="{path.name}"')
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(payload)

    def _static(self, path: str) -> None:
        root = asset_dir()
        if path == "/":
            target = root / "index.html"
            content = target.read_bytes().replace(b"__GAO_TOKEN__", self.server.token.encode("ascii"))
            mime = "text/html; charset=utf-8"
        else:
            name = path.removeprefix("/assets/")
            if name not in {"app.js", "style.css"}:
                self._json(404, {"error": "not_found", "message": "not found"})
                return
            target = root / name
            content = target.read_bytes()
            mime = "text/javascript; charset=utf-8" if name.endswith(".js") else "text/css; charset=utf-8"
        self.send_response(200)
        self.send_header("Content-Type", mime)
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
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


def serve(store: ResearchStore, port: int = 0, open_browser: bool = True, lock_path: Path | None = None) -> None:
    import os

    server = make_server(store, "127.0.0.1", port)
    url = f"http://127.0.0.1:{server.server_address[1]}/"
    if lock_path is not None:
        from gaoyanjiu.fsutil import atomic_write

        atomic_write(lock_path, (json.dumps({"pid": os.getpid(), "url": url}) + "\n").encode("utf-8"))
    if open_browser:
        threading.Timer(0.2, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    finally:
        if lock_path is not None and lock_path.exists():
            lock_path.unlink()
        server.server_close()
