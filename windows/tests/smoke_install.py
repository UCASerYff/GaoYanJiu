"""Run the built x64 MSI against synthetic, isolated Windows data."""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import msilib
import os
import re
import shutil
import stat
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
NOTIFICATION_KEY = r"Software\Classes\AppUserModelId\GaoSeries.GaoYanJiu"
NOTIFICATION_ACTIVATOR = "{F35C7BDD-954B-41DD-A863-F60CC0C192D7}"
INSTALL_STATE_KEY = r"Software\GaoSeries\GaoYanJiu"
PROTOCOL_KEY = r"Software\Classes\gaoyanjiu"
PAYLOAD_COMPONENT = "GaoYanJiuFiles"
SHELL_COMPONENTS = {"GaoYanJiuProtocol", "GaoYanJiuNotificationIdentity", "GaoYanJiuShortcuts"}


def msi_property(database, name: str) -> str:
    view = database.OpenView(f"SELECT `Value` FROM `Property` WHERE `Property` = '{name}'")
    view.Execute(None)
    return view.Fetch().GetString(1)


def msi_run(root: Path, action: str, target: str, properties: list[str], stage: str = "") -> None:
    log = root / f"{action[1:]}{stage}.log"
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


def registry_key_exists(key: str) -> bool:
    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key):
            return True
    except FileNotFoundError:
        return False


def check_x64(executable: Path) -> None:
    with executable.open("rb") as binary:
        assert binary.read(2) == b"MZ"
        binary.seek(60)
        offset, = struct.unpack("<I", binary.read(4))
        binary.seek(offset)
        assert binary.read(6) == b"PE\0\0\x64\x86"


def require_data_dir(profile: Path, reported: object) -> None:
    if not isinstance(reported, str) or "\x00" in reported or not Path(reported).is_absolute():
        raise AssertionError(f"Bootstrap dataDir must be an absolute path, got {reported!r}")
    paths = f"expected {str(profile)!r}, reported {reported!r}"
    try:
        expected = profile.stat()
        actual = Path(reported).stat()
    except OSError as exc:
        raise AssertionError(f"Could not verify the bootstrap data directory ({paths})") from exc
    if not (stat.S_ISDIR(expected.st_mode) and stat.S_ISDIR(actual.st_mode)):
        raise AssertionError(f"Bootstrap data paths must both be directories ({paths})")
    if not os.path.samestat(expected, actual):
        raise AssertionError(f"Bootstrap returned a different data directory ({paths})")


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


def exercise(install: Path, profile: Path, fixture: dict, env: dict, release: str) -> None:
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
        assert first["status"] == "ready" and first["writable"]
        assert f'{first["version"]}+{first["build"]}' == release
        assert request("/api/portals/browser")["available"] is True
        assert request("/api/notifications/status")["state"] == "unavailable"
        for resource in ("AcademicAchievementManagerIcon.png", "FloatingSkyV354.png", "FloatingRockV354.png",
                         "grass-3d-texture.png"):
            assert call(f"/assets/{resource}").startswith(b"\x89PNG\r\n\x1a\n"), resource
        icon = call("/assets/GaoYanJiu.ico")
        reserved, kind, count = struct.unpack_from("<HHH", icon)
        assert (reserved, kind) == (0, 1) and len(icon) >= 6 + 16 * count
        frame_sizes = {struct.unpack_from("<BB", icon, 6 + 16 * index) for index in range(count)}
        assert {(size, size) for size in (16, 20, 24, 28, 32, 40, 48, 56, 64)} <= frame_sizes
        assert call("/assets/extractor.js")
        assert call("/assets/city.js")
        assert json.loads((profile / "library.json").read_text(encoding="utf-8")) == fixture
        second = subprocess.run([str(cli), "gaoyanjiu://works", "--no-browser"], env=env, creationflags=NO_WINDOW,
                                capture_output=True, timeout=35, check=True)
        assert second.stdout == b"" and process.poll() is None
        require_data_dir(profile, request("/api/bootstrap").get("dataDir"))

        paper = request("/api/papers", {"title": "隔离安装论文", "venue": "Nature", "status": "Under Review",
                                         "statusSince": "2026-11-14"})["key"]
        has_submission_actions = int(release.partition("+")[2]) >= 5
        if has_submission_actions:
            action = request("/api/papers/next-action", {"key": paper, "operation": "save", "revision": None,
                                                        "text": "核对审稿意见", "dueDate": "2025-12-31"})["nextAction"]
            assert request("/api/papers?scope=all")["nextActions"]["overdue"][0]["key"] == paper
        request("/api/papers", {"key": paper, "title": "隔离安装论文", "venue": "Nature", "status": "Accepted",
                                "statusSince": "2026-11-25"})
        papers = request("/api/papers?scope=all")["papers"]
        assert len(papers) == 1 and papers[0]["title"] == "隔离安装论文"
        assert [row["status"] for row in papers[0]["history"]] == ["Under Review", "Accepted"]
        if has_submission_actions:
            assert papers[0]["nextAction"] == action and action["completedAt"] is None
            assert all(not rows for rows in request("/api/papers?scope=all")["nextActions"].values())
        reference = hashlib.sha256(json.dumps([paper], separators=(",", ":")).encode("ascii")).hexdigest()[:40]
        activation = subprocess.run([str(cli), f"gaoyanjiu://follow-up/{reference}", "--no-browser"],
                                    env=env, creationflags=NO_WINDOW, capture_output=True, timeout=35, check=True)
        assert activation.stdout == b"" and process.poll() is None
        assert request("/api/notifications/paper?ref=" + reference)["paper"]["key"] == paper
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


def installer_identity(package: Path) -> tuple[str, str, str]:
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
    version = msi_property(database, "ProductVersion")
    return product_code, upgrade_code, version


def _msi_rows(database, sql: str, fields: int, integers=()) -> list[tuple]:
    view = database.OpenView(sql)
    try:
        view.Execute(None)
        rows = []
        while record := view.Fetch():
            rows.append(tuple(record.GetInteger(index) if index in integers else record.GetString(index)
                              for index in range(1, fields + 1)))
        return rows
    finally:
        view.Close()


def _msi_execute(database, sql: str, *values) -> None:
    view = database.OpenView(sql)
    try:
        record = None
        if values:
            record = msilib.CreateRecord(len(values))
            for index, value in enumerate(values, 1):
                if isinstance(value, int):
                    record.SetInteger(index, value)
                elif value is not None:
                    record.SetString(index, value)
        view.Execute(record)
    finally:
        view.Close()


def _msi_code(value: uuid.UUID) -> str:
    return "{" + str(value).upper() + "}"


def _related_products(upgrade_code: str) -> tuple[str, ...]:
    codes = []
    while True:
        product = ctypes.create_unicode_buffer(39)
        result = ctypes.windll.msi.MsiEnumRelatedProductsW(upgrade_code, 0, len(codes), product)
        if result == 259:
            return tuple(sorted(codes))
        if result != 0:
            raise OSError(result, "MsiEnumRelatedProductsW failed")
        codes.append(product.value)


def _program_fingerprint(path: Path) -> tuple[int, str] | None:
    if not path.is_file():
        return None
    with path.open("rb") as handle:
        return path.stat().st_size, hashlib.file_digest(handle, "sha256").hexdigest()


def _canonical_msi_state(upgrade_code: str, menu: Path) -> tuple:
    install_path = read_registry(INSTALL_STATE_KEY, "InstallPath")
    locations = {Path(os.environ["LOCALAPPDATA"]) / "GaoYanJiu"}
    if isinstance(install_path, str) and Path(install_path).is_absolute():
        locations.add(Path(install_path))
    files = tuple((str(directory), name, _program_fingerprint(directory / name))
                  for directory in sorted(locations)
                  for name in ("GaoYanJiu.exe", "GaoYanJiu-cli.exe", "ThirdPartyNotices.txt"))
    shortcuts = tuple((item.name, _program_fingerprint(item)) for item in sorted(menu.glob("*.lnk")))
    products = tuple((code, ctypes.windll.msi.MsiQueryProductStateW(code)) for code in _related_products(upgrade_code))
    return (products, install_path, files, shortcuts, registry_key_exists(INSTALL_STATE_KEY),
            read_registry(INSTALL_STATE_KEY, "Shortcuts"), registry_key_exists(PROTOCOL_KEY),
            read_registry(PROTOCOL_KEY), read_registry(PROTOCOL_KEY, "URL Protocol"),
            read_registry(PROTOCOL_KEY + r"\DefaultIcon"), read_registry(PROTOCOL_KEY + r"\shell\open\command"),
            registry_key_exists(NOTIFICATION_KEY),
            read_registry(NOTIFICATION_KEY, "CustomActivator"), read_registry(NOTIFICATION_KEY, "DisplayName"))


def _isolate_installer(package: Path, destination: Path, namespace: uuid.UUID, state_key: str) -> tuple[str, str]:
    source_product, source_upgrade, source_version = installer_identity(package)
    expected_digest = package.with_suffix(".msi.sha256").read_text(encoding="ascii").split()[0]
    shutil.copyfile(package, destination)
    assert _program_fingerprint(destination)[1] == expected_digest
    product = _msi_code(uuid.uuid5(namespace, "product:" + source_product))
    upgrade = _msi_code(uuid.uuid5(namespace, "upgrade:" + source_upgrade))
    package_code = _msi_code(uuid.uuid4())
    database = msilib.OpenDatabase(str(destination), msilib.MSIDBOPEN_TRANSACT)

    # Fail closed if future packages acquire system-wide installation tables
    # or a different custom-action/component topology.
    tables = {item[0] for item in _msi_rows(database, "SELECT `Name` FROM `_Tables`", 1)}
    excluded = {"Class", "ProgId", "TypeLib", "Extension", "Verb", "MIME", "Environment",
                "ServiceControl", "ServiceInstall", "DuplicateFile", "MoveFile", "RemoveRegistry",
                "SelfReg", "IniFile", "RemoveIniFile", "ODBCDataSource", "CreateFolder", "MsiLockPermissionsEx"}
    assert not tables & excluded, tables & excluded
    properties = dict(_msi_rows(database, "SELECT `Property`, `Value` FROM `Property`", 2))
    assert properties.get("ALLUSERS") in (None, ""), "Only per-user MSIs can be cloned"
    assert properties.get("GAOYANJIU_STATE_KEY") == INSTALL_STATE_KEY
    components = _msi_rows(database, "SELECT `Component`, `ComponentId`, `Condition`, `Directory_` FROM `Component`", 4)
    assert PAYLOAD_COMPONENT in {name for name, _, _, _ in components}
    for name, original, condition, directory in components:
        assert name in SHELL_COMPONENTS or name == PAYLOAD_COMPONENT, name
        assert directory == ("GaoYanJiuMenuFolder" if name == "GaoYanJiuShortcuts" else "INSTALLFOLDER"), name
        assert condition == ("NOT GAOYANJIU_TEST_INSTALL" if name in SHELL_COMPONENTS else ""), name
        uuid.UUID(original)
        replacement = _msi_code(uuid.uuid5(namespace, "component:" + original.upper()))
        _msi_execute(database, "UPDATE `Component` SET `ComponentId`= ? WHERE `Component`= ?", replacement, name)
        if name in SHELL_COMPONENTS:
            _msi_execute(database, "UPDATE `Component` SET `Condition`= ? WHERE `Component`= ?", "0", name)
    keys = _msi_rows(database, "SELECT `Root`, `Key`, `Component_` FROM `Registry`", 3, integers=(1,))
    for root, key, component in keys:
        assert root == 1
        assert (component == PAYLOAD_COMPONENT and key == "[GAOYANJIU_STATE_KEY]") or component in SHELL_COMPONENTS
    for (component,) in _msi_rows(database, "SELECT `Component_` FROM `Shortcut`", 1):
        assert component in SHELL_COMPONENTS
    assert set(_msi_rows(database, "SELECT `File`, `Component_` FROM `File`", 2)) == {
        (file, PAYLOAD_COMPONENT) for file in ("GaoYanJiuApp", "GaoYanJiuCli", "GaoYanJiuNotices")
    }
    for component, directory in _msi_rows(database, "SELECT `Component_`, `DirProperty` FROM `RemoveFile`", 2):
        assert directory in {"INSTALLFOLDER", "GaoYanJiuMenuFolder"} and component in {PAYLOAD_COMPONENT, "GaoYanJiuShortcuts"}
    if "CustomAction" in tables:
        actions = _msi_rows(database, "SELECT `Action`, `Source`, `Target` FROM `CustomAction`", 3)
        for action, source, target in actions:
            assert (action, source, target) == ("ClearGaoYanJiuReminders", "GaoYanJiuCli", "--clear-reminders")
            _msi_execute(database, "UPDATE `InstallExecuteSequence` SET `Condition`= ? WHERE `Action`= ?", "0", action)

    for name, value in {"ProductCode": product, "UpgradeCode": upgrade, "GAOYANJIU_STATE_KEY": state_key,
                        "GAOYANJIU_TEST_INSTALL": "1"}.items():
        if name in properties:
            _msi_execute(database, "UPDATE `Property` SET `Value`= ? WHERE `Property`= ?", value, name)
        else:
            _msi_execute(database, "INSERT INTO `Property` (`Property`, `Value`) VALUES (?, ?)", name, value)
    for directory, suffix in {"INSTALLFOLDER": "payload", "GaoYanJiuMenuFolder": "menu"}.items():
        name = f"GaoYanJiu.InstallSmoke.{namespace.hex}.{suffix}"
        _msi_execute(database, "UPDATE `Directory` SET `DefaultDir`= ? WHERE `Directory`= ?", name, directory)
    final_directories = dict(_msi_rows(database, "SELECT `Directory`, `Directory_Parent` FROM `Directory`", 2))
    assert final_directories["INSTALLFOLDER"] == "LocalAppDataFolder"
    assert final_directories["GaoYanJiuMenuFolder"] == "ProgramMenuFolder"

    columns = "`UpgradeCode`, `VersionMin`, `VersionMax`, `Language`, `Attributes`, `Remove`, `ActionProperty`"
    related = _msi_rows(database, f"SELECT {columns} FROM `Upgrade`", 7, integers=(5,))
    assert related and {row[0] for row in related} == {source_upgrade}
    assert {row[-1] for row in related} == {"WIX_UPGRADE_DETECTED", "WIX_DOWNGRADE_DETECTED"}
    _msi_execute(database, "DELETE FROM `Upgrade`")
    for row in related:
        _msi_execute(database, f"INSERT INTO `Upgrade` ({columns}) VALUES (?, ?, ?, ?, ?, ?, ?)",
                     upgrade, *(value if value != "" else None for value in row[1:]))
    summary = database.GetSummaryInformation(1)
    summary.SetProperty(9, package_code)
    summary.Persist()
    database.Commit()
    del summary, database

    final = msilib.OpenDatabase(str(destination), msilib.MSIDBOPEN_READONLY)
    assert msi_property(final, "ProductCode") == product and msi_property(final, "UpgradeCode") == upgrade
    assert msi_property(final, "ProductVersion") == source_version
    assert msi_property(final, "GAOYANJIU_STATE_KEY") == state_key and msi_property(final, "GAOYANJIU_TEST_INSTALL") == "1"
    assert _msi_rows(final, "SELECT `UpgradeCode` FROM `Upgrade`", 1) == [(upgrade,), (upgrade,)]
    observed = final.GetSummaryInformation(0).GetProperty(9)
    assert (observed.decode("ascii") if isinstance(observed, bytes) else observed) == package_code
    assert ctypes.windll.msi.MsiQueryProductStateW(product) == -1
    return product, upgrade


def smoke(package: Path, legacy: Path | None, register_shell: bool, previous: Path | None = None,
          isolate_identity: bool = False) -> None:
    if isolate_identity and not __debug__:
        raise RuntimeError("Run the isolated MSI test with Python assertions enabled.")
    product_code, upgrade_code, version = installer_identity(package)
    expected_version = "+".join(version.rsplit(".", 1))
    previous_code = None
    if previous:
        previous_code, previous_upgrade, previous_version = installer_identity(previous)
        assert previous_upgrade == upgrade_code and previous_code != product_code
        assert tuple(map(int, previous_version.split("."))) < tuple(map(int, version.split(".")))
    if isolate_identity and register_shell:
        raise ValueError("The isolated MSI identity must skip shell registration.")
    if not isolate_identity and _related_products(upgrade_code):
        raise RuntimeError("An existing MSI installation prevents isolated installation testing")
    protocol = PROTOCOL_KEY
    menu = Path(os.environ["APPDATA"]) / "Microsoft/Windows/Start Menu/Programs/搞研究"
    if not isolate_identity and (register_shell or previous) and (registry_key_exists(protocol) or registry_key_exists(NOTIFICATION_KEY) or menu.exists()):
        raise RuntimeError("Existing GaoYanJiu shell resources prevent isolated registration testing")
    if previous and not isolate_identity:
        installed_dir = Path(os.environ["LOCALAPPDATA"]) / "GaoYanJiu"
        if installed_dir.exists() or registry_key_exists(r"Software\GaoSeries\GaoYanJiu"):
            raise RuntimeError("Existing default install resources prevent isolated MSI upgrade testing")

    canonical = _canonical_msi_state(upgrade_code, menu) if isolate_identity else None
    with tempfile.TemporaryDirectory(prefix="GaoYanJiu-install-") as directory:
        root = Path(directory)
        install = root / "安装 # Windows"
        profile = root / "旧版 # 资料"
        runtime = root / "runtime"
        local_appdata = root / "local appdata"
        runtime.mkdir()
        local_appdata.mkdir()
        env = dict(os.environ, GAO_RESEARCH_DATA_DIR=str(profile), LOCALAPPDATA=str(local_appdata),
                   PYTHONUTF8="1", TEMP=str(runtime), TMP=str(runtime))
        cli = install / "GaoYanJiu-cli.exe"
        app = install / "GaoYanJiu.exe"
        namespace = uuid.uuid4()
        key = rf"Software\GaoSeries\GaoYanJiu.InstallSmoke.{namespace.hex}"
        if isolate_identity:
            clone = root / "candidate-isolated.msi"
            product_code, temporary_upgrade = _isolate_installer(package, clone, namespace, key)
            package = clone
            if previous:
                clone = root / "previous-isolated.msi"
                previous_code, previous_upgrade = _isolate_installer(previous, clone, namespace, key)
                assert previous_upgrade == temporary_upgrade and previous_code != product_code
                previous = clone
            assert not _related_products(temporary_upgrade)
        properties = [f"INSTALLFOLDER={install}", f"GAOYANJIU_STATE_KEY={key}"]
        if not register_shell:
            properties.append("GAOYANJIU_TEST_INSTALL=1")
        library = profile / "library.json"
        attachment = profile / "Attachments" / "legacy-work" / "old.txt"
        try:
            if previous:
                msi_run(root, "/i", str(previous), properties, "-previous")
                assert ctypes.windll.msi.MsiQueryProductStateW(previous_code) == 5
            if legacy or previous:
                subprocess.run([str(legacy or cli), "--create-empty"], env=env, creationflags=NO_WINDOW, timeout=45, check=True)
                fixture = legacy_fixture(profile)
                original = library.read_bytes()
            msi_run(root, "/i", str(package), properties, "-candidate")
            if previous_code:
                assert ctypes.windll.msi.MsiQueryProductStateW(previous_code) == -1
            for file in (app, cli):
                check_x64(file)
            assert Path(read_registry(key, "InstallPath")) == install
            if register_shell:
                assert read_registry(protocol + r"\shell\open\command") == f'"{app}" "%1"'
                assert read_registry(NOTIFICATION_KEY, "CustomActivator") == NOTIFICATION_ACTIVATOR
                assert len(list(menu.glob("*.lnk"))) == 3
            assert (install / "ThirdPartyNotices.txt").is_file()
            version = subprocess.check_output([str(cli), "--version"], env=env, creationflags=NO_WINDOW, timeout=30)
            assert version.decode("ascii").strip() == expected_version
            if legacy or previous:
                assert library.read_bytes() == original
                assert attachment.read_bytes() == b"Trusted synthetic legacy attachment"
            else:
                assert not profile.exists()
                subprocess.run([str(cli), "--create-empty"], env=env, creationflags=NO_WINDOW, timeout=45, check=True)
                fixture = legacy_fixture(profile)
            exercise(install, profile, fixture, env, expected_version)
            data_hash = hashlib.sha256(library.read_bytes()).hexdigest()
        finally:
            try:
                for code in (product_code, previous_code):
                    if code and ctypes.windll.msi.MsiQueryProductStateW(code) == 5:
                        msi_run(root, "/x", code, properties, "-candidate" if code == product_code else "-previous")
                assert read_registry(key, "InstallPath") is None
                try:
                    winreg.DeleteKey(winreg.HKEY_CURRENT_USER, key)
                except FileNotFoundError:
                    pass
            finally:
                if canonical is not None:
                    assert _canonical_msi_state(upgrade_code, menu) == canonical, "Canonical MSI or shell state changed"
        assert not app.exists() and not cli.exists()
        assert hashlib.sha256(library.read_bytes()).hexdigest() == data_hash
        assert attachment.read_bytes() == b"Trusted synthetic legacy attachment"
        if register_shell:
            assert not registry_key_exists(protocol) and not menu.exists()
            assert read_registry(NOTIFICATION_KEY, "CustomActivator") is None
    print("MSI smoke passed: SHA-256, x64, install, app and CLI, local assets, records, attachments, city, layouts, uninstall")
    if legacy:
        print("Legacy Windows data passed: install preserves bytes; current app retains project, funding, unknown fields and city")
    if previous:
        print("MSI upgrade passed: earlier build was removed and legacy data and attachment bytes were preserved")
    if isolate_identity:
        print(f"Isolated identities passed: {len(canonical[0])} canonical products and their shell registrations were preserved")
    if register_shell:
        print("Shell registration passed: deep link, three Start menu shortcuts, and notification identity installed and removed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    sources = parser.add_mutually_exclusive_group()
    sources.add_argument("--legacy-cli", type=Path)
    sources.add_argument("--upgrade-from", type=Path)
    parser.add_argument("--register-shell", action="store_true", help="Use only on a disposable Windows account.")
    parser.add_argument("--isolate-msi-identity", action="store_true", help="Use temporary MSI identities and skip shell registration.")
    args = parser.parse_args()
    smoke(args.package.resolve(strict=True), args.legacy_cli.resolve(strict=True) if args.legacy_cli else None,
          args.register_shell, args.upgrade_from.resolve(strict=True) if args.upgrade_from else None,
          args.isolate_msi_identity)
