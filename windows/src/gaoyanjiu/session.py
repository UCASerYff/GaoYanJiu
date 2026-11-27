from __future__ import annotations

import http.client
import json
import os
import re
import time
import webbrowser
from contextlib import contextmanager
from pathlib import Path

from gaoyanjiu import APP_NAME
from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import read_regular_bytes

URL_PATTERN = re.compile(r"http://127\.0\.0\.1:([0-9]{1,5})/")
URL_DESTINATIONS = {
    "submissions": ("submissions", ""), "works": ("works", ""),
    "widget": ("", "submissions"), "submission-widget": ("", "submissions"),
    "achievement-widget": ("", "works"),
}


def link_destination(text: str) -> tuple[str, str]:
    reminder = re.fullmatch(r"gaoyanjiu://follow-up/([a-f0-9]{40})/?", text, re.ASCII | re.IGNORECASE)
    if reminder is not None:
        return "follow-up/" + reminder[1].lower(), ""
    matched = re.fullmatch(r"gaoyanjiu://([a-z-]+)/?", text, re.ASCII | re.IGNORECASE)
    if matched is None or matched[1].lower() not in URL_DESTINATIONS:
        raise AppError("invalid_field", 400, "无效的搞研究链接 / Invalid GaoYanJiu link")
    return URL_DESTINATIONS[matched[1].lower()]


def url_for(origin: str, destination: str) -> str:
    return f"{origin}#{destination}" if destination else origin


def valid_destination(destination) -> bool:
    return isinstance(destination, str) and (
        destination in {"", "exchange"}
        or any(destination == target and target for target, _ in URL_DESTINATIONS.values())
        or re.fullmatch(r"follow-up/[a-f0-9]{40}", destination, re.ASCII) is not None
    )


def edge_executable() -> Path | None:
    for variable in ("ProgramFiles(x86)", "ProgramFiles", "LOCALAPPDATA"):
        root = os.environ.get(variable)
        if root:
            edge = Path(root) / "Microsoft" / "Edge" / "Application" / "msedge.exe"
            if edge.is_file():
                return edge
    return None


def open_application(url: str) -> None:
    if os.name == "nt":
        edge = edge_executable()
        if edge is not None:
            try:
                os.startfile(edge, arguments=f'--app="{url}"')
                return
            except OSError:
                pass
    webbrowser.open(url)


def _request(port: int, method: str, path: str, token: str = "", data: dict | None = None) -> bytes:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=1.0 if data is None else 8.0)
    headers = {"X-Gao-Token": token, "Content-Type": "application/json"}
    try:
        connection.request(method, path, json.dumps(data).encode("utf-8") if data is not None else None, headers)
        response = connection.getresponse()
        if response.status != 200:
            raise OSError(f"HTTP {response.status}")
        return response.read(1024 * 1024)
    finally:
        connection.close()


def existing_session(root: Path) -> tuple[str, int, str] | None:
    try:
        state = json.loads(read_regular_bytes(root / "server.json", 4096))
        if not isinstance(state, dict):
            return None
        url = state.get("url", "")
        match = URL_PATTERN.fullmatch(url) if isinstance(url, str) else None
        if not match or not 1 <= int(match[1]) <= 65535:
            return None
        port = int(match[1])
        token = state.get("token")
        if token is None:  # Windows initial builds did not publish the token to the launcher.
            page = _request(port, "GET", "/")
            match = re.search(rb'name="gao-token" content="([A-Za-z0-9_-]{16,80})"', page)
            token = match[1].decode("ascii") if match else ""
        if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{16,80}", token):
            return None
        status = json.loads(_request(port, "GET", "/api/bootstrap", token))
        if status.get("name") == APP_NAME and Path(status["dataDir"]).resolve() == root.resolve():
            return url, port, token
    except (AppError, OSError, ValueError, TypeError, KeyError, AttributeError, http.client.HTTPException):
        pass
    return None


def receive_in_session(port: int, token: str, path: Path) -> None:
    try:
        _request(port, "POST", "/api/exchange/receive", token, {"path": str(path)})
    except (OSError, http.client.HTTPException) as exc:
        raise AppError("invalid_field", 400,
                       "无法将交接包发送到运行中的搞研究 / Could not send the package to the running app") from exc


def open_in_session(port: int, token: str, destination: str, *, desktop: bool) -> bool:
    try:
        return json.loads(_request(port, "POST", "/api/session/open", token,
                                   {"destination": destination, "desktop": desktop})).get("handled") is True
    except (OSError, ValueError, http.client.HTTPException, AttributeError):
        return False


def publish_in_session(port: int, token: str) -> dict:
    try:
        return json.loads(_request(port, "POST", "/api/widgets/publish", token, {}))
    except (OSError, ValueError, http.client.HTTPException):
        return {}


@contextmanager
def app_session(root: Path):
    """Hold an operating-system lock for an application's data directory."""
    root.mkdir(parents=True, exist_ok=True)
    with (root / "server.guard").open("a+b") as guard:
        if os.name == "nt":
            import msvcrt

            def acquire() -> None:
                guard.seek(0)
                msvcrt.locking(guard.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl

            def acquire() -> None:
                fcntl.flock(guard.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)

        existing = existing_session(root)
        deadline = time.monotonic() + 10
        while existing is None:
            try:
                acquire()
            except OSError:
                if time.monotonic() >= deadline:
                    raise AppError("read_required", 409, "正在启动搞研究 / GaoYanJiu is starting") from None
                time.sleep(.10)
                existing = existing_session(root)
            else:
                break
        yield existing
