"""GaoWenJian provider detection and optional isolated Windows installer checks."""

from __future__ import annotations

import hashlib
import json
import os
import queue
import re
import subprocess
import tempfile
import threading
import time
from pathlib import Path
from unittest.mock import patch
from urllib.request import ProxyHandler, Request, build_opener

import pytest

from gaoyanjiu import BUNDLE_ID
from gaoyanjiu.exchange import (
    CHOOSE, EDIT, FILE_INSTALLER_APP_ID, IMPORT, LEGACY_FILE_IDENTITY,
    ResearchExchange, _launch_provider, _provider_exe,
)
from gaoyanjiu.library import Library
from gaoyanjiu.store import ResearchStore


def manifest(action: str, kind: str = "request") -> dict:
    return {"action": action, "kind": kind, "sourceBundleID": BUNDLE_ID,
            "targetBundleID": "com.gaoseries.GaoWenJian",
            "items": [], "references": [], "parameters": {}}


@pytest.mark.skipif(os.name != "nt", reason="uses Windows installer registry paths")
def test_detects_guids_for_custom_install(tmp_path):
    import winreg

    target = tmp_path / "Custom install"
    target.mkdir()
    for name in ("GaoWenJian.exe", "GaoWenJian-cli.exe"):
        (target / name).touch()
    suffix = rf"\Uninstall\{FILE_INSTALLER_APP_ID}_is1"

    class Handle:
        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    def open_key(hive, key, *_):
        if hive != winreg.HKEY_CURRENT_USER or not key.endswith(suffix):
            raise FileNotFoundError(key)
        return Handle()

    # Simulate the exact installer registration without setting any registry values.
    with patch.object(winreg, "OpenKey", side_effect=open_key), patch.object(
        winreg, "QueryValueEx", return_value=(str(target), winreg.REG_SZ)
    ) as registry:
        assert _provider_exe("GaoWenJian") == target / "GaoWenJian.exe"
    assert registry.call_args.args[1] == "InstallLocation"


def test_legacy_open_accepts_only_the_installed_version_for_receipts(tmp_path):
    from gaoyanjiu import exchange

    product = "GaoWenJian"
    program = tmp_path / "GaoWenJian.exe"
    cli = tmp_path / "GaoWenJian-cli.exe"
    package = tmp_path / "package.gaoaction"
    receipt = manifest(IMPORT, "result")

    def old_probe(path, option):
        assert path == cli
        if option == "--capabilities":
            raise subprocess.CalledProcessError(2, [str(path), option])
        assert option == "--version"
        return b"1.11+2\r\n"

    with patch.object(exchange, "_provider_exe", return_value=program), patch.object(
        exchange, "_provider_probe", side_effect=old_probe
    ), patch.object(exchange, "version_strings", return_value=LEGACY_FILE_IDENTITY) as identify, patch.object(
        exchange.subprocess, "Popen"
    ) as popup:
        for action in (CHOOSE, EDIT):
            assert _launch_provider(product, package, manifest(action)).startswith("提供方版本或能力不兼容")
        popup.assert_not_called()
        identify.assert_not_called()
        assert _launch_provider(product, package, receipt).startswith("已将交接包")
        assert popup.call_args.args[0] == [str(program), "--open", str(package)]
        assert [call.args[0] for call in identify.call_args_list] == [program, cli]
        popup.reset_mock()
        identify.return_value = dict(LEGACY_FILE_IDENTITY, FileVersion="1.11.1.0")
        assert _launch_provider(product, package, receipt).startswith("提供方版本或能力不兼容")
        popup.assert_not_called()


def test_modern_file_provider_uses_review_flag(tmp_path):
    from gaoyanjiu import exchange

    program = tmp_path / "GaoWenJian.exe"
    package = tmp_path / "request.gaoaction"
    capability = {"schemaVersion": 1, "bundleID": "com.gaoseries.GaoWenJian", "appVersion": "1.11", "actions": [
        {"action": CHOOSE, "requiresUserConfirmation": True, "supportsItems": False, "supportsReferences": False,
         "parametersSchema": {"type": "object", "properties": {"multiple": {"type": "boolean"}}}}
    ]}
    selection = dict(manifest(CHOOSE), parameters={"multiple": True})
    with patch.object(exchange, "_provider_exe", return_value=program), patch.object(
        exchange, "_provider_probe", return_value=json.dumps(capability).encode("utf-8")
    ), patch.object(exchange.subprocess, "Popen") as popup:
        assert _launch_provider("GaoWenJian", package, selection).startswith("已将交接包")
        assert popup.call_args.args[0] == [str(program), "--gaoaction", str(package)]
        popup.reset_mock()
        capability["actions"][0]["requiresUserConfirmation"] = False
    with patch.object(exchange, "_provider_exe", return_value=program), patch.object(
        exchange, "_provider_probe", return_value=json.dumps(capability).encode("utf-8")
    ), patch.object(exchange.subprocess, "Popen") as popup:
        assert _launch_provider("GaoWenJian", package, selection).startswith("提供方版本或能力不兼容")
        popup.assert_not_called()


def _until(fn, label: str, timeout: float = 20):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = fn()
        if value:
            return value
        time.sleep(0.1)
    raise AssertionError(f"Timed out waiting for {label}")


def _terminate(child) -> None:
    if child.poll() is None:
        child.terminate()
        try:
            child.wait(timeout=8)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait(timeout=8)


def _fixture_export(cli: Path, profile: Path, root: Path, env: dict[str, str]) -> dict:
    opened = subprocess.Popen([str(cli), "--no-browser", "--data-dir", str(profile)],
                              env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                              creationflags=subprocess.CREATE_NO_WINDOW)
    def address():
        urls.put(opened.stdout.readline().strip())

    try:
        urls = queue.Queue()
        threading.Thread(target=address, daemon=True).start()
        url = urls.get(timeout=15)
        assert re.fullmatch(r"http://127\.0\.0\.1:\d+/?", url)
        opener = build_opener(ProxyHandler({}))
        with opener.open(url, timeout=5) as connection:
            page = connection.read().decode("utf-8")
        token = re.search(r'name="gao-token" content="([^"]+)"', page)[1]

        def api(route: str, body: dict) -> dict:
            request = Request(url.rstrip("/") + route, json.dumps(body).encode("utf-8"),
                              {"X-Gao-Token": token, "Content-Type": "application/json"})
            with opener.open(request, timeout=12) as connection:
                return json.load(connection)

        tab = api("/api/tabs/new", {"kind": "markdown", "text": "# Synthetic GaoAction round trip"})["result"]
        exported = api("/api/handoff/research", {"id": tab["id"], "directory": str(root)})["result"]
        api("/api/tabs/save", {"id": tab["id"], "path": str(root / "fixture.md")})
        api("/api/shutdown", {})
        assert opened.wait(timeout=15) == 0
        return exported
    finally:
        _terminate(opened)
        opened.stdout.close()
        opened.stderr.close()


@pytest.mark.skipif(os.name != "nt" or not os.environ.get("GAOWENJIAN_TEST_SETUP"),
                    reason="requires a checked GaoWenJian Windows Setup executable with SHA-256 sidecar")
def test_installed_files_accepts_automatically_opened_receipt():
    from gaoyanjiu import exchange

    setup = Path(os.environ["GAOWENJIAN_TEST_SETUP"]).resolve(strict=True)
    expected = Path(str(setup) + ".sha256").read_text(encoding="utf-8").split()[0]
    with setup.open("rb") as content:
        assert hashlib.file_digest(content, "sha256").hexdigest() == expected
    base_options = ["/VERYSILENT", "/SUPPRESSMSGBOXES", "/NORESTART", "/NOCLOSEAPPLICATIONS", "/NORESTARTAPPLICATIONS"]
    with tempfile.TemporaryDirectory(prefix="gao-wenjian-research-installed-") as scratch:
        root = Path(scratch)
        apps = root / "程序"
        profile = root / "文件资料"
        env = {**os.environ, "APPDATA": str(root / "roaming"), "WEBVIEW2_USER_DATA_FOLDER": str(root / "webview-provider")}
        subprocess.run([str(setup), *base_options, "/SP-", "/GAOISOLATED=1", f"/DIR={apps}", f"/LOG={root / 'installer.log'}"],
                       check=True, timeout=150, env=env, creationflags=subprocess.CREATE_NO_WINDOW)
        gui = apps / "GaoWenJian.exe"
        cli = apps / "GaoWenJian-cli.exe"
        started = []
        try:
            outgoing = _fixture_export(cli, profile, root, env)
            library = Library(root / "Research").open()
            library.create_empty()
            store = ResearchStore(library)
            folder = store.create_folder("importantLiterature", "Synthetic fixture")
            handoff = ResearchExchange(store)
            pending = handoff.receive(Path(outgoing["path"]))
            assert pending["status"] == "pending"
            assert handoff.apply(pending["id"], True, folder)["imported"] == 1

            start = subprocess.Popen

            def unattended(command, *args, **kwargs):
                if Path(command[0]) != gui:
                    return start(command, *args, **kwargs)
                assert command[1] in ("--gaoaction", "--open")
                child = start([*command, "--hidden", "--data-dir", str(profile)], *args, env=env, **kwargs)
                started.append((child, command))
                return child

            # Feed the directory verified by the real isolated installer into discovery,
            # without setting real App Paths or Inno registration.
            with patch.object(exchange, "_target_dirs", return_value=iter([apps])), patch.object(
                exchange.subprocess, "Popen", side_effect=unattended
            ):
                receipt = handoff.receipt(pending["id"], root, launch=True)
            assert receipt["message"].startswith("已将交接包"), receipt
            assert len(started) == 1
            receipt_path = Path(receipt["path"])
            payload = receipt_path.joinpath("manifest.json").read_bytes()
            receipt_id = json.loads(payload)["requestID"]
            assert started[0][1][2] == str(receipt_path)

            def journal():
                try:
                    data = json.loads((profile / "Handoff" / "journal.json").read_text(encoding="utf-8"))
                except (OSError, ValueError):
                    return None
                return next((entry for entry in data["entries"] if entry["requestID"] == receipt_id), None)

            accepted = _until(journal, "installed companion accepted receipt from its launcher")
            assert accepted["manifestSHA256"] == hashlib.sha256(payload).hexdigest()
            assert accepted["action"] == IMPORT
            assert (profile / "Handoff" / "outgoing.json").is_file()
        finally:
            for child, _ in started:
                _terminate(child)
            subprocess.run([str(apps / "unins000.exe"), *base_options], check=True, timeout=120,
                           env=env, creationflags=subprocess.CREATE_NO_WINDOW)
        assert not gui.exists() and profile.is_dir()
