"""Run the built x64 MSI against synthetic, isolated Windows data."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import msilib
import os
import re
import struct
import subprocess
import tempfile
import time
import uuid
import winreg
from pathlib import Path
from urllib.parse import urlencode
from urllib.request import ProxyHandler, Request, build_opener

NO_WINDOW = subprocess.CREATE_NO_WINDOW


def msi_property(database, name: str) -> str:
    view = database.OpenView(f"SELECT `Value` FROM `Property` WHERE `Property` = '{name}'")
    view.Execute(None)
    return view.Fetch().GetString(1)


def msi_run(root: Path, action: str, target: str, properties: list[str]) -> None:
    log = root / f"{action[1:]}.log"
    command = subprocess.list2cmdline(["msiexec.exe", action, target, "/qn", "/norestart", "/l*v", str(log)])
    for item in properties:
        name, value = item.split("=", 1)
        command += f' {name}="{value}"'
    result = subprocess.run(command, creationflags=NO_WINDOW, timeout=120, check=False)
    if result.returncode:
        if log.is_file():
            contents = log.read_bytes()
            encoding = "utf-16" if contents.startswith(b"\xff\xfe") else "mbcs"
            lines = contents.decode(encoding, errors="replace").splitlines()
            problem = [line for line in lines if "Return value 3" in line or "Error " in line]
            print("\n".join((problem or lines)[-12:]))
        raise RuntimeError(f"Windows Installer {action} exited with {result.returncode}")


def read_registry(key: str, value: str = ""):
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key) as handle:
            return winreg.QueryValueEx(handle, value)[0]
    except FileNotFoundError:
        return None


def check_x64(executable: Path) -> None:
    with executable.open("rb") as binary:
        assert binary.read(2) == b"MZ"
        binary.seek(60)
        offset, = struct.unpack("<I", binary.read(4))
        binary.seek(offset)
        assert binary.read(6) == b"PE\0\0\x64\x86"


def legacy_fixture(profile: Path) -> dict:
    library = profile / "library.json"
    fixture = json.loads(library.read_text(encoding="utf-8"))
    fixture.update(projects=[{"id": "legacy-project", "name": "历史项目", "extra": [1]}],
                   fundingRecords=[{"id": "legacy-funding", "name": "历史经费", "amount": 98}],
                   installSmokeUnknown={"source": "legacy"})
    fixture["rewardCity"]["coins"] = 52
    item = {"id": "legacy-work", "title": "已有 Windows 成果", "type": "dataset", "sortOrder": 0,
            "attachments": [{"id": "legacy-attachment", "originalName": "已有附件.txt", "storedName": "old.txt",
                             "kind": "file", "addedAt": "2026-10-01T00:00:00Z"}]}
    attachment = profile / "Attachments" / item["id"] / "old.txt"
    attachment.parent.mkdir(parents=True, exist_ok=True)
    attachment.write_bytes(b"Trusted synthetic legacy attachment")
    fixture["existingWorks"].append(item)
    library.write_text(json.dumps(fixture, ensure_ascii=False), encoding="utf-8")
    return fixture


def exercise(install: Path, profile: Path, fixture: dict, env: dict, version: str) -> None:
    app = install / "GaoYanJiu.exe"
    cli = install / "GaoYanJiu-cli.exe"
    client = build_opener(ProxyHandler({}))
    process = subprocess.Popen([str(app), "--serve", "--no-browser", "--port", "0"],
                               env=env, creationflags=NO_WINDOW)
    origin = ""
    headers = {}

    def call(path: str, body: dict | None = None) -> bytes:
        data = json.dumps(body).encode("utf-8") if body is not None else None
        with client.open(Request(origin + path, data=data, headers=headers), timeout=4) as response:
            return response.read()

    def request(path: str, body: dict | None = None) -> dict:
        return json.loads(call(path, body))

    try:
        deadline = time.monotonic() + 45
        lock = profile / "server.json"
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f"Installed executable exited before serving, code {process.returncode}")
            try:
                origin = json.loads(lock.read_text(encoding="utf-8"))["url"].rstrip("/")
                page = call("/")
                break
            except (OSError, ValueError, KeyError):
                time.sleep(.2)
        else:
            raise RuntimeError("The installed executable did not serve its workbench")
        token = re.search(rb'name="gao-token" content="([^"]+)"', page)
        assert token is not None
        headers.update({"X-Gao-Token": token[1].decode("ascii"), "Content-Type": "application/json"})
        first = request("/api/bootstrap")
        assert first["status"] == "ready" and first["writable"] and first["version"] == version
        for resource in ("AcademicAchievementManagerIcon.png", "FloatingSkyV354.png", "FloatingRockV354.png",
                         "grass-3d-texture.png"):
            assert call(f"/assets/{resource}").startswith(b"\x89PNG\r\n\x1a\n"), resource
        assert call("/assets/extractor.js")
        assert call("/assets/city.js")
        assert json.loads((profile / "library.json").read_text(encoding="utf-8")) == fixture
        second = subprocess.run([str(cli), "gaoyanjiu://works", "--no-browser"], env=env, creationflags=NO_WINDOW,
                                capture_output=True, timeout=35, check=True)
        assert second.stdout == b"" and process.poll() is None
        assert request("/api/bootstrap")["dataDir"] == str(profile)

        paper = request("/api/papers", {"title": "隔离安装论文", "venue": "Nature", "status": "Under Review",
                                         "statusSince": "2026-11-14"})["key"]
        request("/api/papers", {"key": paper, "title": "隔离安装论文", "venue": "Nature", "status": "Accepted",
                                "statusSince": "2026-11-25"})
        papers = request("/api/papers?scope=all")["papers"]
        assert len(papers) == 1 and papers[0]["title"] == "隔离安装论文"
        assert [row["status"] for row in papers[0]["history"]] == ["Under Review", "Accepted"]
        work = request("/api/works", {"title": "MSI achievement", "type": "journalArticle", "authorPosition": "first"})["id"]
        request("/api/certificates", {"name": "MSI certificate", "tags": ["Synthetic"]})
        doc = profile.parent / "测试附件.txt"
        doc.write_bytes(b"Synthetic data and document body")
        work_attachment = request("/api/works/attachment-path", {"ownerID": work, "path": str(doc)})["attachment"]
        folder = request("/api/documents/folder", {"kind": "experimentData", "name": "MSI folder"})["id"]
        request("/api/documents/import-path", {"folderID": folder, "path": str(doc)})
        assert len(request("/api/documents?" + urlencode({"kind": "experimentData", "folder": folder}))["documents"]) == 1
        assert request("/api/reward")["coins"] == fixture["rewardCity"]["coins"]
        widget = json.loads((profile / "widget-snapshot.json").read_text(encoding="utf-8"))
        assert widget["schema"] == 1 and widget["papers"][0]["terminal"] and widget["works"] == 2
        assert widget["papers"][0]["id"] == paper
        assert widget["statisticsRevision"] and widget["authors"][0]["count"] == 1
        counts = json.loads(subprocess.check_output([str(cli), "--widget-snapshot"], env=env,
                                                    creationflags=NO_WINDOW, timeout=35))
        assert counts["works"] == 2 and counts["activeSubmissions"] == 0 and "papers" not in counts
        reports = subprocess.check_output([str(cli), "--widget", "works", "--inspect"],
                                          env=env, creationflags=NO_WINDOW, timeout=45)
        widget_display = json.loads(reports)
        layouts = widget_display["layouts"]
        assert len(layouts) == 12 and len({row["color"] for row in layouts}) == 2
        assert min(row["items"] for row in layouts) >= 6
        print(f"Desktop widgets rendered {len(layouts)} hidden layouts at Tk scaling {widget_display['scaling']:.3f}")
        saved = json.loads((profile / "library.json").read_text(encoding="utf-8"))
        for key in ("projects", "fundingRecords", "installSmokeUnknown"):
            assert saved[key] == fixture[key], key
        assert saved["existingWorks"][0] == fixture["existingWorks"][0]
        stored_file = profile / "Attachments" / work / work_attachment["storedName"]
        assert stored_file.read_bytes() == doc.read_bytes()
    finally:
        if headers:
            try:
                request("/api/shutdown", {})
                process.wait(timeout=20)
            except (OSError, subprocess.TimeoutExpired):
                pass
        if process.poll() is None:
            subprocess.run(["taskkill.exe", "/PID", str(process.pid), "/T", "/F"], creationflags=NO_WINDOW,
                           capture_output=True, timeout=15, check=False)
            process.wait(timeout=15)


def smoke(package: Path, legacy: Path | None, register_shell: bool) -> None:
    with package.open("rb") as handle:
        actual = hashlib.file_digest(handle, "sha256").hexdigest()
    assert package.with_suffix(".msi.sha256").read_text(encoding="ascii").strip() == f"{actual}  {package.name}"
    database = msilib.OpenDatabase(str(package), msilib.MSIDBOPEN_READONLY)
    template = database.GetSummaryInformation(0).GetProperty(7)
    if isinstance(template, bytes):
        template = template.decode("ascii")
    assert template.split(";")[0] == "x64"
    product_code = msi_property(database, "ProductCode")
    upgrade_code = msi_property(database, "UpgradeCode")
    expected_version = "+".join(msi_property(database, "ProductVersion").rsplit(".", 1))
    del database
    unrelated = ctypes.create_unicode_buffer(39)
    if ctypes.windll.msi.MsiEnumRelatedProductsW(upgrade_code, 0, 0, unrelated) != 259:
        raise RuntimeError("An existing MSI installation prevents isolated installation testing")
    protocol = r"Software\Classes\gaoyanjiu"
    menu = Path(os.environ["APPDATA"]) / "Microsoft/Windows/Start Menu/Programs/搞研究"
    if register_shell and (read_registry(protocol, "URL Protocol") is not None or menu.exists()):
        raise RuntimeError("Existing GaoYanJiu shell resources prevent isolated registration testing")

    with tempfile.TemporaryDirectory(prefix="GaoYanJiu-install-") as directory:
        root = Path(directory)
        install = root / "安装 # Windows"
        profile = root / "旧版 # 资料"
        runtime = root / "runtime"
        runtime.mkdir()
        env = dict(os.environ, GAO_RESEARCH_DATA_DIR=str(profile), PYTHONUTF8="1", TEMP=str(runtime), TMP=str(runtime))
        cli = install / "GaoYanJiu-cli.exe"
        app = install / "GaoYanJiu.exe"
        key = rf"Software\GaoSeries\GaoYanJiu.InstallSmoke.{uuid.uuid4().hex}"
        properties = [f"INSTALLFOLDER={install}", f"GAOYANJIU_STATE_KEY={key}"]
        if not register_shell:
            properties.append("GAOYANJIU_TEST_INSTALL=1")
        library = profile / "library.json"
        attachment = profile / "Attachments" / "legacy-work" / "old.txt"
        try:
            if legacy:
                subprocess.run([str(legacy), "--create-empty"], env=env, creationflags=NO_WINDOW, timeout=45, check=True)
                fixture = legacy_fixture(profile)
                original = library.read_bytes()
            msi_run(root, "/i", str(package), properties)
            for file in (app, cli):
                check_x64(file)
            assert Path(read_registry(key, "InstallPath")) == install
            if register_shell:
                assert read_registry(protocol + r"\shell\open\command") == f'"{app}" "%1"'
                assert len(list(menu.glob("*.lnk"))) == 3
            assert (install / "ThirdPartyNotices.txt").is_file()
            version = subprocess.check_output([str(cli), "--version"], env=env, creationflags=NO_WINDOW, timeout=30)
            assert version.decode("ascii").strip() == expected_version
            if legacy:
                assert library.read_bytes() == original
                assert attachment.read_bytes() == b"Trusted synthetic legacy attachment"
            else:
                assert not profile.exists()
                subprocess.run([str(cli), "--create-empty"], env=env, creationflags=NO_WINDOW, timeout=45, check=True)
                fixture = legacy_fixture(profile)
            exercise(install, profile, fixture, env, expected_version.split("+")[0])
            data_hash = hashlib.sha256(library.read_bytes()).hexdigest()
        finally:
            if ctypes.windll.msi.MsiQueryProductStateW(product_code) == 5:
                msi_run(root, "/x", product_code, properties)
            assert read_registry(key, "InstallPath") is None
            try:
                winreg.DeleteKey(winreg.HKEY_CURRENT_USER, key)
            except FileNotFoundError:
                pass
        assert not app.exists() and not cli.exists()
        assert hashlib.sha256(library.read_bytes()).hexdigest() == data_hash
        assert attachment.read_bytes() == b"Trusted synthetic legacy attachment"
        if register_shell:
            assert read_registry(protocol, "URL Protocol") is None and not menu.exists()
    print("MSI smoke passed: SHA-256, x64, install, app and CLI, local assets, records, attachments, city, layouts, uninstall")
    if legacy:
        print("Legacy Windows data passed: install preserves bytes; current app retains project, funding, unknown fields and city")
    if register_shell:
        print("Shell registration passed: deep-link command and three Start menu shortcuts installed and removed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--legacy-cli", type=Path)
    parser.add_argument("--register-shell", action="store_true", help="Use only on a disposable Windows account.")
    args = parser.parse_args()
    smoke(args.package.resolve(strict=True), args.legacy_cli.resolve(strict=True) if args.legacy_cli else None,
          args.register_shell)
