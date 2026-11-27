import http.client
import json
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from gaoyanjiu.errors import AppError
from gaoyanjiu.library import Library
from gaoyanjiu.portal import PortalBrowser, _approved_capture, _origin, _profile_directory
from gaoyanjiu.store import ResearchStore
from gaoyanjiu.web import asset_dir, make_server


def test_webview2_preview_requires_exact_site_and_strips_query():
    url = "https://editor.example/manuscripts?synthetic=query#local"
    source = {"url": url, "checkedAt": "2026-11-27T09:00:00Z", "papers": [
        {"id": "DEMO-001", "title": "Synthetic fixture article", "status": "Under review", "unknown": "discard me"},
        {"id": "DEMO-001", "title": "Duplicate", "status": "Under review"},
    ]}
    capture = _approved_capture(source, _origin("https://editor.example"))
    assert len(capture["papers"]) == 1
    assert "unknown" not in capture["papers"][0]
    assert capture["url"] == "https://editor.example/manuscripts"
    for unexpected in ("https://editor.example:444/", "http://editor.example", "https://another.example"):
        with pytest.raises(AppError, match="portal_capture_origin"):
            _approved_capture(source, _origin(unexpected))


def test_webview2_profile_isolated_by_portal_and_origin(tmp_path):
    one = _profile_directory(tmp_path, "../unexpected", _origin("https://editor.example"))
    two = _profile_directory(tmp_path, "different-portal", _origin("https://editor.example"))
    edited = _profile_directory(tmp_path, "../unexpected", _origin("https://new.example"))
    assert len({one, two, edited}) == 3
    assert one.parent == tmp_path / "PortalProfiles"
    assert _profile_directory(tmp_path, "../unexpected", _origin("https://editor.example")) == one


class _Publisher(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.send_response(302)
            self.send_header("Set-Cookie", "gaoFixture=synthetic; Path=/; HttpOnly; SameSite=Strict")
            self.send_header("Location", "/dashboard?auth=synthetic-token")
            self.end_headers()
            return
        if self.path.startswith("/dashboard") and "gaoFixture=synthetic" in self.headers.get("Cookie", ""):
            html = """<!doctype html><meta charset="utf-8"><title>Fixture Journal</title>
            <script>window.PaperSignalExtractor = Object.freeze({extract: async () => ({papers: []})});</script>
            <table><thead><tr><th>Manuscript ID</th><th>Title</th><th>Journal</th><th>Status</th></tr></thead>
            <tbody><tr><td>DEMO-001</td><td>A synthetic article about WebView2</td><td>Fixture Journal</td><td>Under review</td></tr>
            <tr><td>DEMO-002</td><td>A second synthetic article</td><td>Fixture Journal</td><td>Accepted</td></tr></tbody></table>
            """.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(html)))
            self.end_headers()
            self.wfile.write(html)
            return
        self.send_error(404)

    def log_message(self, message, *args):
        pass


def _run(server):
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    return worker


@pytest.mark.skipif(os.name != "nt" or os.environ.get("GAO_WEBVIEW2_SMOKE") != "1",
                    reason="opt-in Windows WebView2 integration with a built native helper")
def test_native_webview2_extract_review_and_store(tmp_path):
    library = Library(tmp_path / "synthetic").open()
    library.create_empty()
    store = ResearchStore(library)
    with ThreadingHTTPServer(("127.0.0.1", 0), _Publisher) as publisher, make_server(store) as server:
        publisher_thread = _run(publisher)
        app_thread = _run(server)
        browser = PortalBrowser(store, asset_dir(), probe_loopback=True)
        server.api.portal_browser = browser
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=10)

        def request(method, path, data=None, token=None):
            headers = {"Content-Type": "application/json"}
            if token:
                headers["X-Gao-Token"] = token
            connection.request(method, path, json.dumps(data) if data is not None else None, headers)
            result = connection.getresponse()
            return result.status, json.loads(result.read())

        endpoint = "/api/portals/browser"
        try:
            assert request("GET", endpoint)[0] == 401
            token = server.token
            assert request("GET", endpoint, token=token) == (200, {"available": True})
            url = f"http://127.0.0.1:{publisher.server_port}/"
            portal_id = store.save_portal({"name": "Synthetic journal", "url": url})
            status, started = request("POST", endpoint + "/open", {"id": portal_id}, token)
            assert status == 200
            session_id = started["sessionId"]
            capture = started
            session_query = f"{endpoint}?sessionId={session_id}"
            for _ in range(80):
                status, waiting = request("GET", session_query, token=token)
                assert status == 200
                if waiting["state"] == "ready" and not waiting.get("notice"):
                    break
                assert waiting["state"] not in {"captured", "closed", "error"}, waiting
                time.sleep(0.25)
            assert waiting["state"] == "ready" and "capture" not in waiting
            browser._probe_extract(session_id)
            for _ in range(80):
                status, capture = request("GET", session_query, token=token)
                assert status == 200
                if capture["state"] in {"captured", "closed", "error"}:
                    break
                time.sleep(0.25)
            assert capture["state"] == "captured", capture
            preview = capture["capture"]
            assert preview["url"] == url + "dashboard"
            assert [row["id"] for row in preview["papers"]] == ["DEMO-001", "DEMO-002"]
            assert store.list_papers() == []
            assert request("POST", endpoint + "/close", {"sessionId": session_id}, token)[0] == 200
            assert request("GET", session_query, token=token)[0] == 404
            status, merged = request(
                "POST", "/api/portals/capture", {"id": portal_id, "capture": {**preview, "papers": preview["papers"][:1]}}, token,
            )
            assert status == 200 and merged["imported"] == 1
            assert [paper["manuscriptID"] for paper in store.list_papers()] == ["DEMO-001"]
            assert len(list((library.root / "PortalProfiles").glob("*/EBWebView"))) == 1
        finally:
            browser.stop()
            connection.close()
            server.shutdown()
            publisher.shutdown()
            app_thread.join(timeout=5)
            publisher_thread.join(timeout=5)
