from __future__ import annotations

import hashlib
import json
import os
import secrets
import stat
import subprocess
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit

from gaoyanjiu.errors import AppError
from gaoyanjiu.store import _find
from gaoyanjiu.workspace import clean_web_url

MAX_PACKET_BYTES = 8 * 1024 * 1024
SESSION_LIFETIME = 1800
RESULT_FIELDS = {
    "id": 160,
    "title": 1200,
    "journal": 500,
    "status": 300,
    "statusSince": 40,
    "statusSinceSource": 500,
    "submissionHistory": 100_000,
}
HELPER_NOTICES = {"missing-runtime", "unsupported-profile", "cannot-initialize", "loading", "no-papers",
                  "different-origin", "extract-failed", "navigation-failed", "blocked-navigation", "closing"}


def _origin(url: str) -> tuple[str, str, int]:
    clean_web_url(url)
    try:
        parts = urlsplit(url)
        return parts.scheme, parts.hostname.rstrip(".").lower(), parts.port or (443 if parts.scheme == "https" else 80)
    except ValueError as exc:
        raise AppError("invalid_field") from exc


def _location_is_link(path: Path) -> bool:
    properties = path.lstat()
    return stat.S_ISLNK(properties.st_mode) or bool(
        getattr(properties, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0)
    )


def _profile_directory(data_root: Path, portal_id: str, origin: tuple) -> Path:
    # The browser can retain its own publisher cookies. Each saved portal and
    # origin receives a separate profile, including after the portal URL is edited.
    key = hashlib.sha256(json.dumps([portal_id, *origin], ensure_ascii=True).encode()).hexdigest()
    resolved_root = data_root.resolve()
    parent = resolved_root / "PortalProfiles"
    for directory in (parent, parent / key):
        try:
            directory.mkdir(exist_ok=True)
            if _location_is_link(directory) or not directory.is_dir() or directory.resolve() != directory:
                raise OSError("Unexpected browser profile directory")
        except OSError as exc:
            raise AppError("portal_browser_profile", 409) from exc
    return parent / key


def _approved_capture(value, expected_origin: tuple) -> dict:
    if not isinstance(value, dict) or not isinstance(value.get("url"), str) or len(value["url"]) > 2000:
        raise AppError("invalid_field")
    if _origin(value["url"]) != expected_origin:
        raise AppError("portal_capture_origin")
    rows = value.get("papers")
    if not isinstance(rows, list) or not 1 <= len(rows) <= 500:
        raise AppError("portal_capture_empty")
    papers = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise AppError("invalid_field")
        if any(value is not None and not isinstance(value, str) for key, value in row.items() if key in RESULT_FIELDS):
            raise AppError("invalid_field")
        fields = {field: (row.get(field) or "").strip()[:limit] for field, limit in RESULT_FIELDS.items()}
        if not all(fields[name] for name in ("id", "title", "status")) or fields["id"] in seen:
            continue
        seen.add(fields["id"])
        papers.append(fields)
    if not papers:
        raise AppError("portal_capture_empty")
    checked_at = value.get("checkedAt")
    return {"url": clean_web_url(value["url"]), "checkedAt": checked_at[:40] if isinstance(checked_at, str) else "",
            "papers": papers}


@dataclass
class _Session:
    id: str
    portal_id: str
    origin: tuple
    process: subprocess.Popen
    opened_at: float
    state: str = "starting"
    notice: str = ""
    capture: dict | None = None


class PortalBrowser:
    """Own the embedded browser process and an in-memory preview before approval."""

    def __init__(self, store, asset_root: Path, *, helper_path=None, probe_loopback=False):
        self.store = store
        native_dir = asset_root / "portal" if getattr(sys, "frozen", False) else asset_root.parents[2] / "build" / "portal"
        self.helper = Path(helper_path or native_dir / "GaoYanJiu-Portal.exe")
        self.extractor = asset_root / "extractor.js"
        if not self.extractor.is_file() and not getattr(sys, "frozen", False):
            self.extractor = asset_root.parents[3] / "Resources" / "extractor.js"
        self._lock = threading.RLock()
        self._session = None
        self._probe_loopback = probe_loopback

    def _available(self) -> bool:
        return os.name == "nt" and self.helper.is_file() and self.extractor.is_file()

    def open(self, portal_id) -> dict:
        if not self._available():
            raise AppError("portal_browser_unavailable", 503)
        if not isinstance(portal_id, str) or not portal_id:
            raise AppError("invalid_field")
        portal = _find(self.store._data()["portals"], "id", portal_id)
        origin = _origin(portal["url"])
        with self._lock:
            existing = self._session
            if existing and existing.state in {"starting", "ready"}:
                if existing.portal_id == portal_id and existing.origin == origin:
                    return self._present(existing)
                raise AppError("portal_browser_busy", 409)
            profile = _profile_directory(self.store.library.root, portal_id, origin)
            config = {"url": portal["url"], "name": portal.get("publisherName") or portal["name"],
                      "kind": portal.get("kind", "custom"), "profile": str(profile),
                      "extractorPath": str(self.extractor.resolve()), "language": self.store.language(),
                      "appearance": self.store.settings.get("appearance", "system")}
            command = [str(self.helper)]
            if self._probe_loopback:
                command.append("--smoke-loopback")
            # WebView2 environment variables can override the data folder and
            # enable remote debugging. The helper uses its own storage and SDK.
            environment = {key: value for key, value in os.environ.items() if not key.upper().startswith("WEBVIEW2_")}
            try:
                process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                           stderr=subprocess.DEVNULL, cwd=self.helper.parent, env=environment)
            except OSError as exc:
                raise AppError("portal_browser_unavailable", 503) from exc
            session = _Session(secrets.token_urlsafe(24), portal_id, origin, process, time.monotonic())
            try:
                process.stdin.write((json.dumps(config, ensure_ascii=True) + "\n").encode("ascii"))
                process.stdin.flush()
            except OSError as exc:
                self._finish_process(process)
                raise AppError("portal_browser_unavailable", 503) from exc
            self._session = session
            threading.Thread(target=self._receive, args=(session,), daemon=True).start()
            return self._present(session)

    def status(self, session_id=None) -> dict:
        if session_id is None:
            return {"available": self._available()}
        with self._lock:
            session = self._identified(session_id)
            expired = time.monotonic() - session.opened_at > SESSION_LIFETIME
            if not expired:
                return self._present(session)
        self.close(session_id)
        return {"sessionId": session_id, "state": "closed"}

    def _probe_extract(self, session_id) -> None:
        if not self._probe_loopback:
            raise RuntimeError("The WebView2 probe is for isolated tests")
        with self._lock:
            session = self._identified(session_id)
            session.process.stdin.write(b"extract\n")
            session.process.stdin.flush()

    @staticmethod
    def _present(session) -> dict:
        result = {"sessionId": session.id, "state": session.state}
        if session.notice:
            result["notice"] = session.notice
        if session.capture is not None:
            result["capture"] = session.capture
        return result

    def _identified(self, session_id) -> _Session:
        session = self._session
        if not isinstance(session_id, str) or session is None or not secrets.compare_digest(session_id, session.id):
            raise AppError("not_found", 404)
        return session

    def close(self, session_id) -> dict:
        with self._lock:
            session = self._identified(session_id)
            session.capture = None
            session.state = "closed"
            self._session = None
        self._finish_process(session.process)
        return {"sessionId": session_id, "state": "closed"}

    def stop_portal(self, portal_id) -> None:
        with self._lock:
            session = self._session
            if session is None or session.portal_id != portal_id:
                return
            self._session = None
        self._finish_process(session.process)

    def stop(self) -> None:
        with self._lock:
            session, self._session = self._session, None
        if session is not None:
            self._finish_process(session.process)

    @staticmethod
    def _finish_process(process) -> None:
        try:
            process.stdin.close()
        except OSError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                process.terminate()
                process.wait(timeout=2)
            except (OSError, subprocess.TimeoutExpired):
                return

    def _receive(self, session) -> None:
        process = session.process
        try:
            for packet in iter(lambda: process.stdout.readline(MAX_PACKET_BYTES + 1), b""):
                if len(packet) > MAX_PACKET_BYTES:
                    raise ValueError("Oversized browser response")
                message = json.loads(packet)
                if not isinstance(message, dict):
                    raise ValueError("Invalid browser response")
                with self._lock:
                    if self._session is not session:
                        break
                    message_type = message.get("state")
                    notice = message.get("notice")
                    if message_type == "captured":
                        session.capture = _approved_capture(message.get("capture"), session.origin)
                        session.state = "captured"
                        session.notice = ""
                    elif message_type in {"ready", "error", "closed"} and session.state != "captured":
                        session.state = message_type
                        session.notice = notice if notice in HELPER_NOTICES else ""
        except (AppError, OSError, ValueError, TypeError):
            with self._lock:
                if self._session is session and session.state not in {"captured", "closed"}:
                    session.state, session.notice = "error", "extract-failed"
        finally:
            process.stdout.close()
            self._finish_process(process)
            with self._lock:
                if self._session is session and session.state in {"starting", "ready"}:
                    session.state = "closed" if process.returncode == 0 else "error"
                    session.notice = "" if process.returncode == 0 else "cannot-initialize"
