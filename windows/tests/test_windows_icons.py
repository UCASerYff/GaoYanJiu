from __future__ import annotations

import ctypes as c
import os
import struct
import subprocess
from ctypes import wintypes as w
from pathlib import Path

import pytest

pytestmark = pytest.mark.skipif(os.name != "nt", reason="requires Win32 icon metrics and handles")

ROOT = Path(__file__).resolve().parents[2]


class IconInfo(c.Structure):
    _fields_ = [("icon", w.BOOL), ("x", w.DWORD), ("y", w.DWORD), ("mask", w.HBITMAP), ("color", w.HBITMAP)]


class Bitmap(c.Structure):
    _fields_ = [("type", w.LONG), ("width", w.LONG), ("height", w.LONG), ("stride", w.LONG),
                ("planes", w.WORD), ("bits_per_pixel", w.WORD), ("bits", c.c_void_p)]


@pytest.fixture(scope="module")
def branded_ico(tmp_path_factory):
    icon = tmp_path_factory.mktemp("research-icons") / "GaoYanJiu.ico"
    powershell = Path(os.environ["SystemRoot"]) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    subprocess.run([str(powershell), "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-File",
                    str(ROOT / "windows/installer/create-icon.ps1"), "-Source",
                    str(ROOT / "Resources/AcademicAchievementManagerIcon.png"), "-OutputPath", str(icon)],
                   check=True, creationflags=subprocess.CREATE_NO_WINDOW, timeout=40)
    return icon


def test_manifest_frames_and_native_shell_sizes(branded_ico):
    from gaoyanjiu.win_icons import bind, icon_dimensions, load_application_icon

    ico = branded_ico.read_bytes()
    reserved, kind, count = struct.unpack_from("<HHH", ico)
    assert (reserved, kind) == (0, 1)
    entries = {}
    for index in range(count):
        width, height, _, _, _, bpp, size, offset = struct.unpack_from("<BBBBHHII", ico, 6 + 16 * index)
        assert width == height and bpp == 32
        frame = ico[offset:offset + size]
        assert len(frame) == size and frame[:8] == b"\x89PNG\r\n\x1a\n"
        assert struct.unpack_from(">IIBB", frame, 16) == (width or 256, height or 256, 8, 6)
        entries[width or 256] = frame
    assert len(entries) == count and {16, 20, 24, 28, 32, 40, 48, 56, 64, 256}.issubset(entries)

    user, gdi = c.WinDLL("user32", use_last_error=True), c.WinDLL("gdi32", use_last_error=True)
    get_icon = bind(user, "GetIconInfo", w.BOOL, w.HICON, c.POINTER(IconInfo))
    get_object = bind(gdi, "GetObjectW", c.c_int, w.HANDLE, c.c_int, w.LPVOID)
    delete_object = bind(gdi, "DeleteObject", w.BOOL, w.HANDLE)
    destroy_icon = bind(user, "DestroyIcon", w.BOOL, w.HICON)
    for dpi, sizes in zip((96, 120, 144, 168, 192), ((16, 32), (20, 40), (24, 48), (28, 56), (32, 64))):
        for small, size in zip((True, False), sizes):
            dimensions = icon_dimensions(user, dpi, small=small)
            assert dimensions == (size, size)
            icon = load_application_icon(user, dimensions, source=branded_ico)
            assert icon
            info = IconInfo()
            try:
                assert get_icon(icon, c.byref(info))
                bitmap = Bitmap()
                assert get_object(info.color, c.sizeof(bitmap), c.byref(bitmap))
                assert (bitmap.width, bitmap.height, bitmap.bits_per_pixel) == (size, size, 32)
            finally:
                if info.color:
                    delete_object(info.color)
                if info.mask:
                    delete_object(info.mask)
                destroy_icon(icon)


def test_tray_refreshes_existing_entry_when_taskbar_dpi_changes(monkeypatch):
    from gaoyanjiu import tray

    icon = tray.TrayIcon("fixture", lambda: None, lambda: None, language="zh-Hans")
    icon.taskbar_created = 0xC104
    icon.data = tray.NotifyIconData()
    icon._user = object()
    icon._find_window = lambda name, title: 99 if name == "Shell_TrayWnd" else None
    released, notified, requested = [], [], []
    icon._destroy_icon = released.append
    icon._notify = lambda operation, data: notified.append((operation, data.hIcon)) or True
    dpi = 96

    def load(_user, dimensions):
        requested.append(dimensions)
        return dimensions[0]

    monkeypatch.setattr(tray, "window_dpi", lambda _user, hwnd: dpi if hwnd == 99 else 0)
    monkeypatch.setattr(tray, "load_application_icon", load)
    icon._refresh_icon()
    icon._add_icon()
    assert notified == [(tray.NIM_ADD, 16), (tray.NIM_SETVERSION, 16)]
    dpi = 168
    icon._process_message(1, tray.WM_DPICHANGED, 0, 0)
    icon._process_message(1, tray.WM_TIMER, 0, 0)
    assert requested == [(16, 16), (28, 28)] and released == [16]
    assert notified[-1] == (tray.NIM_MODIFY, 28)
    icon.registered.clear()
    icon._process_message(1, icon.taskbar_created, 0, 0)
    assert notified[-2:] == [(tray.NIM_ADD, 28), (tray.NIM_SETVERSION, 28)]


def test_workbench_applies_matching_shortcut_identity_and_window_icons(branded_ico, monkeypatch):
    from gaoyanjiu import win_icons, workbench_shell
    from gaoyanjiu.notifications import APP_ID

    monkeypatch.setattr(win_icons, "application_icon_path", lambda: branded_ico)
    user, ole = c.WinDLL("user32", use_last_error=True), c.WinDLL("ole32", use_last_error=True)
    bind = win_icons.bind
    create = bind(user, "CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD,
                  c.c_int, c.c_int, c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
    destroy = bind(user, "DestroyWindow", w.BOOL, w.HWND)
    send = bind(user, "SendMessageW", w.LPARAM, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
    init = bind(ole, "CoInitializeEx", c.c_long, c.c_void_p, w.DWORD)
    clear = bind(ole, "PropVariantClear", c.c_long, c.POINTER(workbench_shell.PropertyValue))
    hwnd = create(0, "Static", "GaoYanJiu icon fixture", 0x80000000, 0, 0, 0, 0, None, None, None, None)
    assert hwnd  # Hidden HWND only. The fixture never attaches to another desktop window.
    initialized = init(None, 2) >= 0
    shell = workbench_shell.WorkbenchShell(user)
    try:
        for dpi in (96, 120, 144, 168, 192):
            monkeypatch.setattr(workbench_shell, "window_dpi", lambda u, h: dpi)
            shell.update((hwnd,))
            assert hwnd in shell.identified
            for role, small in ((0, True), (1, False)):
                assert send(hwnd, 0x007F, role, dpi) == shell.native_icons.icons[win_icons.icon_dimensions(user, dpi, small=small)]

        # A late favicon can replace the workbench icon without changing the window's DPI.
        send(hwnd, 0x0080, 0, shell.native_icons.icons[(16, 16)])
        assert send(hwnd, 0x007F, 0, 192) == shell.native_icons.icons[(16, 16)]
        shell.update((hwnd,))
        assert send(hwnd, 0x007F, 0, 192) == shell.native_icons.icons[(32, 32)]

        store = c.c_void_p()
        assert shell.get_store(hwnd, c.byref(workbench_shell._PROPERTY_STORE), c.byref(store)) == 0
        table = c.cast(store, c.POINTER(c.POINTER(c.c_void_p))).contents
        release = c.WINFUNCTYPE(w.ULONG, c.c_void_p)(table[2])
        read = c.WINFUNCTYPE(c.c_long, c.c_void_p, c.POINTER(workbench_shell.PropertyKey),
                            c.POINTER(workbench_shell.PropertyValue))(table[5])
        value = workbench_shell.PropertyValue()
        try:
            assert read(store, c.byref(workbench_shell._APP_ID_PROPERTY), c.byref(value)) == 0
            assert (value.vt, value.text) == (31, APP_ID)
        finally:
            clear(c.byref(value))
            release(store)
    finally:
        shell.clear_window_identity(hwnd)
        destroy(hwnd)
        shell.close()
        if initialized:
            bind(ole, "CoUninitialize", None)()
