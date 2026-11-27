from __future__ import annotations

import ctypes
import json
import os
import queue
import threading
import time
from ctypes import wintypes
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

import pytest

from gaoyanjiu import cli, session
from gaoyanjiu.library import Library


pytestmark = pytest.mark.skipif(
    os.name != "nt" or os.environ.get("GAO_RESEARCH_NATIVE_TRAY_TEST") != "1",
    reason="requires an interactive Windows Shell and opt-in native tray test",
)

WM_COMMAND = 0x0111
WM_LBUTTONUP = 0x0202
NIN_SELECT, NIN_KEYSELECT = 0x0400, 0x0401
NIM_ADD, NIM_MODIFY, NIM_DELETE, NIM_SETVERSION = 0, 1, 2, 4


class NotifyIconIdentifier(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("hWnd", wintypes.HWND),
        ("uID", wintypes.UINT),
        ("guidItem", ctypes.c_ubyte * 16),
    ]


def wait_for(predicate, description, timeout=8.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.04)
    pytest.fail(f"Timed out waiting for {description}")


def test_native_tray_desktop_lifecycle(tmp_path, monkeypatch):
    from gaoyanjiu import tray, widget, workbench
    from gaoyanjiu.notifications import paper_ref

    user32 = ctypes.WinDLL("user32", use_last_error=True)
    user32.FindWindowW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR]
    user32.FindWindowW.restype = wintypes.HWND
    user32.RegisterWindowMessageW.argtypes = [wintypes.LPCWSTR]
    user32.RegisterWindowMessageW.restype = wintypes.UINT
    user32.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
    user32.IsWindow.argtypes = [wintypes.HWND]
    shell32 = ctypes.WinDLL("shell32", use_last_error=True)
    shell32.Shell_NotifyIconGetRect.argtypes = [ctypes.POINTER(NotifyIconIdentifier), ctypes.POINTER(wintypes.RECT)]
    shell32.Shell_NotifyIconGetRect.restype = ctypes.c_long
    assert user32.FindWindowW("Shell_TrayWnd", None), "Windows Explorer taskbar is unavailable"
    taskbar_created = user32.RegisterWindowMessageW("TaskbarCreated")
    assert taskbar_created

    def shell_has_icon(hwnd):
        item = NotifyIconIdentifier(ctypes.sizeof(NotifyIconIdentifier), hwnd, tray.TRAY_ICON_ID)
        return shell32.Shell_NotifyIconGetRect(ctypes.byref(item), ctypes.byref(wintypes.RECT())) == 0

    openings = queue.Queue()
    confirmations = queue.Queue()
    closing = []
    external = []
    widgets = []
    instances = []
    operations = []
    registrations = []
    outcome = queue.Queue()
    original_start = tray.TrayIcon.start
    shell_notify = tray.TrayIcon._notify

    def start_icon(icon, *args, **kwargs):
        result = original_start(icon, *args, **kwargs)
        instances.append(icon)
        return result

    def notify_icon(icon, operation, data):
        result = bool(shell_notify(icon, operation, data))
        operations.append((operation, result))
        if operation == NIM_ADD and result:
            registrations.append(data)
        return result

    def record_open(browser, url, *, restore=True):
        openings.put((url, restore))
        return True

    def record_confirm(icon):
        allowed = confirmations.get_nowait()
        confirmations.task_done()
        return allowed

    def unexpected_workbench_fallback(_url):
        pytest.fail("desktop entry incorrectly fell back to opening a foreground browser")

    monkeypatch.setattr(tray.TrayIcon, "start", start_icon)
    monkeypatch.setattr(tray.TrayIcon, "_notify", notify_icon)
    monkeypatch.setattr(tray.TrayIcon, "confirm_exit", record_confirm)
    monkeypatch.setattr(workbench.WorkbenchBrowser, "open", record_open)
    monkeypatch.setattr(workbench.WorkbenchBrowser, "close", lambda browser: closing.append(browser))
    monkeypatch.setattr(widget, "show_widget", lambda root, kind, *, inspect: widgets.append((root, kind, inspect)))
    monkeypatch.setattr(cli, "open_application", unexpected_workbench_fallback)
    monkeypatch.setattr(session, "open_application", unexpected_workbench_fallback)
    monkeypatch.setattr(session.webbrowser, "open", lambda url: external.append(url) or True)
    profile = tmp_path / "tray profile"
    monkeypatch.setenv("GAO_RESEARCH_DATA_DIR", str(profile))
    Library(profile).open().create_empty()
    arguments = ["--data-dir", str(profile)]

    def launch():
        try:
            outcome.put(cli.main(arguments, desktop_entry=True))
        except BaseException as error:
            outcome.put(error)

    def start():
        service = threading.Thread(target=launch, name="test-research-desktop", daemon=True)
        service.start()
        return service

    def post_to(hwnd, message, wparam=0, lparam=0):
        assert user32.PostMessageW(hwnd, message, wparam, lparam), ctypes.get_last_error()

    def service_api(port, token, endpoint, payload=None):
        return json.loads(session._request(port, "GET" if payload is None else "POST", endpoint, token, payload))

    service = start()
    try:
        url, port, token = wait_for(lambda: session.existing_session(profile), "desktop service")
        assert openings.get(timeout=8)[0] == url
        icon = wait_for(lambda: instances and instances[0], "desktop tray controller")
        assert icon.registered.wait(8), operations
        hwnd = icon.hwnd
        wait_for(lambda: shell_has_icon(hwnd), "registered Windows notification icon")
        assert (NIM_ADD, True) in operations and (NIM_SETVERSION, True) in operations

        work_title = "隔离托盘验证保留记录"
        service_api(port, token, "/api/works", {"title": work_title, "type": "journalArticle"})
        service_api(port, token, "/api/settings", {"appearance": "light", "language": "en", "followUpDays": 17})
        wait_for(lambda: (NIM_MODIFY, True) in operations, "native Shell icon modification")
        assert registrations[-1].szTip == "GaoYanJiu is running"

        for activation in (NIN_SELECT, NIN_KEYSELECT, WM_LBUTTONUP):
            post_to(hwnd, tray.TRAY_CALLBACK, lparam=(tray.TRAY_ICON_ID << 16) | activation)
            assert openings.get(timeout=8) == (url, True)
        assert cli.main([*arguments, "gaoyanjiu://works"], desktop_entry=True) == 0
        assert openings.get(timeout=8)[0] == url + "#works"
        assert service_api(port, token, "/api/session/route") == {"destination": "works", "stopping": False}
        assert service_api(port, token, "/api/session/route") == {"destination": "", "stopping": False}
        paper = service_api(port, token, "/api/papers", {"title": "隔离提醒", "status": "审稿中", "statusSince": "2026-08-01"})
        reminder_route = "follow-up/" + paper_ref(paper["key"])
        assert cli.main([*arguments, "gaoyanjiu://" + reminder_route], desktop_entry=True) == 0
        assert openings.get(timeout=8) == (url + "#" + reminder_route, True)
        assert service_api(port, token, "/api/session/route")["destination"] == reminder_route
        assert cli.main([*arguments, "gaoyanjiu://achievement-widget"], desktop_entry=True) == 0
        assert cli.main([*arguments, "gaoyanjiu://submission-widget"], desktop_entry=True) == 0
        assert widgets == [(profile.resolve(), "works", False), (profile.resolve(), "submissions", False)]
        external_url = "https://example.invalid/research"
        assert service_api(port, token, "/api/session/external", {"url": external_url}) == {"ok": True}
        with pytest.raises(OSError, match="HTTP 401"):
            service_api(port, "", "/api/session/external", {"url": external_url})
        assert external == [external_url]
        assert session.existing_session(profile) == (url, port, token)
        assert len(instances) == 1

        # Remove only this fixture icon to simulate Explorer forgetting it.
        assert shell_notify(icon, NIM_DELETE, registrations[-1])
        wait_for(lambda: not shell_has_icon(hwnd), "simulated loss of the fixture icon")
        adds = len(registrations)
        post_to(hwnd, taskbar_created)
        wait_for(lambda: len(registrations) > adds, "notification re-registration")
        wait_for(lambda: shell_has_icon(hwnd), "restored Windows notification icon")

        confirmations.put(False)
        post_to(hwnd, WM_COMMAND, tray.TRAY_QUIT)
        wait_for(lambda: confirmations.unfinished_tasks == 0, "dismissed tray confirmation")
        post_to(hwnd, WM_COMMAND, tray.TRAY_OPEN)
        assert openings.get(timeout=8)[0] == url
        assert service.is_alive() and shell_has_icon(hwnd)

        deletions = operations.count((NIM_DELETE, True))
        confirmations.put(True)
        post_to(hwnd, WM_COMMAND, tray.TRAY_QUIT)
        service.join(8)
        assert not service.is_alive()
        assert outcome.get_nowait() == 0
        wait_for(lambda: operations.count((NIM_DELETE, True)) > deletions, "native Shell icon deletion")
        wait_for(lambda: not shell_has_icon(hwnd) and not user32.IsWindow(hwnd), "removed notification icon and callback window")
        assert closing
        assert not (profile / "server.json").exists()

        service = start()
        new_url, new_port, new_token = wait_for(lambda: session.existing_session(profile), "desktop relaunch")
        assert new_token != token and openings.get(timeout=8)[0] == new_url
        assert service_api(new_port, new_token, "/api/works")["works"][0]["title"] == work_title
        settings = service_api(new_port, new_token, "/api/bootstrap")["settings"]
        assert settings["followUpDays"] == 17 and settings["language"] == "en"
    finally:
        if service.is_alive():
            current = session.existing_session(profile)
            if current:
                _, connection_port, connection_token = current
                service_api(connection_port, connection_token, "/api/shutdown", {})
            service.join(8)
        assert not service.is_alive(), "isolated desktop service did not shut down"


def test_workbench_closes_its_real_edge_job_and_profile(tmp_path, monkeypatch):
    from gaoyanjiu import workbench

    class JobProcesses(ctypes.Structure):
        _fields_ = [("assigned", wintypes.DWORD), ("listed", wintypes.DWORD), ("pids", ctypes.c_size_t * 64)]

    def running_browser(debug_file):
        try:
            port = int(debug_file.read_text(encoding="ascii").splitlines()[0])
            with urlopen(f"http://127.0.0.1:{port}/json/version", timeout=0.5) as response:
                endpoint = json.load(response)
            return port if endpoint.get("webSocketDebuggerUrl") else 0
        except (IndexError, ValueError, OSError):
            return 0

    edge = workbench.edge_executable()
    if edge is None:
        pytest.skip("Microsoft Edge is unavailable for the owned browser smoke")
    format_command = workbench.subprocess.list2cmdline

    def headless_edge(arguments):
        if arguments and Path(arguments[0]) == edge and any(arg.startswith("--app=") for arg in arguments):
            arguments = [*arguments, "--headless=new", "--disable-gpu", "--disable-crash-reporter",
                         "--disable-background-networking", "--disable-component-update", "--disable-sync",
                         "--remote-debugging-port=0"]
        return format_command(arguments)

    monkeypatch.setattr(workbench.subprocess, "list2cmdline", headless_edge)
    monkeypatch.setattr(workbench.tempfile, "tempdir", str(tmp_path))
    browser = workbench.WorkbenchBrowser()
    other_browser = workbench.WorkbenchBrowser()
    processes = []
    try:
        assert other_browser.open("about:blank") is False
        other_debugger = Path(other_browser._profile.name) / "DevToolsActivePort"
        other_port = wait_for(lambda: running_browser(other_debugger), "unrelated synthetic Edge readiness", timeout=15)
        assert browser.open("about:blank") is False
        assert browser._process and browser._job and browser._profile
        profile = Path(browser._profile.name)
        port = wait_for(lambda: running_browser(profile / "DevToolsActivePort"), "headless workbench readiness", timeout=15)
        assert port != other_port
        job_processes = JobProcesses()
        query = workbench.bind(browser._kernel, "QueryInformationJobObject", wintypes.BOOL, wintypes.HANDLE,
                               ctypes.c_int, wintypes.LPVOID, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD))
        assert query(browser._job, 3, ctypes.byref(job_processes), ctypes.sizeof(job_processes), None)
        open_process = workbench.bind(browser._kernel, "OpenProcess", wintypes.HANDLE,
                                      wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
        for pid in job_processes.pids[:job_processes.listed]:
            process = open_process(0x00100000, False, pid)  # SYNCHRONIZE
            if process:
                processes.append(process)
        assert any(browser._wait(process, 0) == 258 for process in processes)  # WAIT_TIMEOUT
        browser.close()
        for process in processes:
            assert browser._wait(process, 5000) == 0  # WAIT_OBJECT_0
        with pytest.raises(URLError):
            with urlopen(f"http://127.0.0.1:{port}/json/version", timeout=0.5):
                pass
        wait_for(lambda: not profile.exists(), "owned workbench profile removal")
        assert running_browser(other_debugger) == other_port
    finally:
        browser.close()
        other_browser.close()
        for process in processes:
            browser._close_handle(process)
