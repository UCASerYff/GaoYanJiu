"""Windows notification-area entry for the workbench's owning process."""

from __future__ import annotations

import ctypes as c
import logging
import sys
import threading
from ctypes import wintypes as w
from pathlib import Path

TRAY_ICON_ID = 1
TRAY_CALLBACK = 0x8001
TRAY_UPDATE = 0x8002
TRAY_CLOSE = 0x8003
TRAY_OPEN = 1
TRAY_QUIT = 2
NIM_ADD, NIM_MODIFY, NIM_DELETE, NIM_SETFOCUS, NIM_SETVERSION = range(5)
WM_CLOSE = 0x10
WM_DESTROY = 0x02
WM_ENDSESSION = 0x16
WM_CONTEXTMENU = 0x7B
WM_COMMAND = 0x111
WM_TIMER = 0x113
WM_LBUTTONUP = 0x202
WM_RBUTTONUP = 0x205
NIN_SELECT, NIN_KEYSELECT = 0x400, 0x401

WNDPROC = c.WINFUNCTYPE(w.LPARAM, w.HWND, w.UINT, w.WPARAM, w.LPARAM)


class WindowClass(c.Structure):
    _fields_ = [
        ("style", w.UINT), ("procedure", WNDPROC), ("class_extra", c.c_int),
        ("window_extra", c.c_int), ("instance", w.HINSTANCE), ("icon", w.HICON),
        ("cursor", w.HANDLE), ("background", w.HBRUSH), ("menu_name", w.LPCWSTR), ("name", w.LPCWSTR),
    ]


class NotifyIconData(c.Structure):
    _fields_ = [
        ("cbSize", w.DWORD), ("hWnd", w.HWND), ("uID", w.UINT), ("uFlags", w.UINT),
        ("uCallbackMessage", w.UINT), ("hIcon", w.HICON), ("szTip", w.WCHAR * 128),
        ("dwState", w.DWORD), ("dwStateMask", w.DWORD), ("szInfo", w.WCHAR * 256),
        ("uVersion", w.UINT), ("szInfoTitle", w.WCHAR * 64), ("dwInfoFlags", w.DWORD),
        ("guidItem", c.c_byte * 16), ("hBalloonIcon", w.HICON),
    ]


def bind(library, name, result, *arguments):
    function = getattr(library, name)
    function.argtypes = arguments
    function.restype = result
    return function


class TrayIcon:
    def __init__(self, title, on_open, on_quit, *, language):
        self.title = title
        self.on_open = on_open
        self.on_quit = on_quit
        self.language = language
        self.hwnd = None
        self.registered = threading.Event()
        self._ready = threading.Event()
        self._closing = threading.Event()
        self._thread = threading.Thread(target=self._run, name="GaoYanJiuTray", daemon=True)
        self._version4 = False
        self._context_active = False
        self._confirming = False

    def start(self):
        self._thread.start()
        self._ready.wait(5)

    def close(self):
        self._closing.set()
        self._post(TRAY_CLOSE)
        self._thread.join(timeout=5)

    def set_language(self, language):
        if self.language != language:
            self.language = language
            self._post(TRAY_UPDATE)

    def _post(self, message):
        if self.hwnd:
            self.post_message(self.hwnd, message, 0, 0)

    def _text(self, chinese, english):
        return english if self.language == "en" else chinese

    def _notify(self, operation, data):
        return bool(self.notify_icon(operation, c.byref(data)))

    def _run(self):
        user = c.WinDLL("user32", use_last_error=True)
        shell = c.WinDLL("shell32", use_last_error=True)
        kernel = c.WinDLL("kernel32", use_last_error=True)
        if hasattr(user, "SetThreadDpiAwarenessContext"):
            bind(user, "SetThreadDpiAwarenessContext", c.c_void_p, c.c_void_p)(c.c_void_p(-4))
        self.post_message = bind(user, "PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
        self.default_proc = bind(user, "DefWindowProcW", w.LPARAM, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
        self.notify_icon = bind(shell, "Shell_NotifyIconW", w.BOOL, w.DWORD, c.POINTER(NotifyIconData))
        self.destroy_window = bind(user, "DestroyWindow", w.BOOL, w.HWND)
        self.post_quit = bind(user, "PostQuitMessage", None, c.c_int)
        self.taskbar_created = bind(user, "RegisterWindowMessageW", w.UINT, w.LPCWSTR)("TaskbarCreated")
        timer = bind(user, "SetTimer", w.WPARAM, w.HWND, w.WPARAM, w.UINT, c.c_void_p)
        instance = bind(kernel, "GetModuleHandleW", w.HINSTANCE, w.LPCWSTR)(None)
        callback = WNDPROC(self._process_message)
        class_name = "GaoYanJiu.NotifyWindow"
        definition = WindowClass(0, callback, 0, 0, instance, None, None, None, None, class_name)
        register = bind(user, "RegisterClassW", w.ATOM, c.POINTER(WindowClass))
        unregister = bind(user, "UnregisterClassW", w.BOOL, w.LPCWSTR, w.HINSTANCE)
        atom = 0
        owned_icon = None
        try:
            atom = register(c.byref(definition))
            if not atom:
                raise c.WinError(c.get_last_error())
            create = bind(user, "CreateWindowExW", w.HWND, w.DWORD, w.LPCWSTR, w.LPCWSTR, w.DWORD,
                          c.c_int, c.c_int, c.c_int, c.c_int, w.HWND, w.HMENU, w.HINSTANCE, w.LPVOID)
            self.hwnd = create(0, class_name, self.title, 0x80000000, 0, 0, 0, 0, None, None, instance, None)
            if not self.hwnd:
                raise c.WinError(c.get_last_error())
            owned_icon = self._application_icon(user, shell)
            icon = owned_icon or bind(user, "LoadIconW", w.HICON, w.HINSTANCE, c.c_void_p)(None, 32512)
            self.data = NotifyIconData()
            self.data.cbSize = c.sizeof(NotifyIconData)
            self.data.hWnd = self.hwnd
            self.data.uID = TRAY_ICON_ID
            self.data.uFlags = 0x87  # NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP
            self.data.uCallbackMessage = TRAY_CALLBACK
            self.data.hIcon = icon
            self.data.uVersion = 4
            self._update_tooltip()
            self._add_icon()
            timer(self.hwnd, 1, 2000, None)
            self._ready.set()
            if self._closing.is_set():
                self._post(TRAY_CLOSE)
            message = w.MSG()
            get = bind(user, "GetMessageW", c.c_int, c.POINTER(w.MSG), w.HWND, w.UINT, w.UINT)
            translate = bind(user, "TranslateMessage", w.BOOL, c.POINTER(w.MSG))
            dispatch = bind(user, "DispatchMessageW", w.LPARAM, c.POINTER(w.MSG))
            while get(c.byref(message), None, 0, 0) > 0:
                translate(c.byref(message))
                dispatch(c.byref(message))
        except OSError:
            logging.getLogger(__name__).exception("Could not initialize the GaoYanJiu tray")
        finally:
            if self.hwnd:
                self.destroy_window(self.hwnd)
            if owned_icon:
                bind(user, "DestroyIcon", w.BOOL, w.HICON)(owned_icon)
            if atom:
                unregister(class_name, instance)
            self._ready.set()

    @staticmethod
    def _application_icon(user, shell):
        if getattr(sys, "frozen", False):
            small = w.HICON()
            extract = bind(shell, "ExtractIconExW", w.UINT, w.LPCWSTR, c.c_int,
                           c.POINTER(w.HICON), c.POINTER(w.HICON), w.UINT)
            if extract(sys.executable, 0, None, c.byref(small), 1) > 0:
                return small
        icon_path = Path(__file__).resolve().parents[2] / "build" / "GaoYanJiu.ico"
        load_image = bind(user, "LoadImageW", w.HANDLE, w.HINSTANCE, w.LPCWSTR, w.UINT, c.c_int, c.c_int, w.UINT)
        return load_image(None, str(icon_path), 1, 0, 0, 0x0050) if icon_path.is_file() else None

    def _add_icon(self):
        if self._notify(NIM_ADD, self.data):
            self._version4 = self._notify(NIM_SETVERSION, self.data)
            self.registered.set()
        else:
            self.registered.clear()

    def _update_tooltip(self):
        self.data.szTip = self._text("搞研究 · 正在运行", "GaoYanJiu is running")

    def _process_message(self, hwnd, message, wparam, lparam):
        try:
            if message == WM_DESTROY:
                if hasattr(self, "data"):
                    self._notify(NIM_DELETE, self.data)
                self.registered.clear()
                self.hwnd = None
                self.post_quit(0)
                return 0
            if message in (TRAY_CLOSE, WM_CLOSE):
                self.destroy_window(hwnd)
                return 0
            if message == WM_ENDSESSION and wparam:
                self.on_quit()
                return 0
            if self._closing.is_set():
                return self.default_proc(hwnd, message, wparam, lparam)
            if message == self.taskbar_created or (message == WM_TIMER and not self.registered.is_set()):
                self._add_icon()
                return 0
            if message == TRAY_UPDATE:
                self._update_tooltip()
                if self.registered.is_set() and not self._notify(NIM_MODIFY, self.data):
                    self.registered.clear()
                return 0
            if message == TRAY_CALLBACK:
                if self._version4 and ((lparam >> 16) & 0xFFFF) != TRAY_ICON_ID:
                    return 0
                event = lparam & 0xFFFF
                if event == WM_LBUTTONUP or (self._version4 and event in (NIN_SELECT, NIN_KEYSELECT)):
                    self._command(TRAY_OPEN)
                elif event == (WM_CONTEXTMENU if self._version4 else WM_RBUTTONUP):
                    self._show_menu(hwnd, wparam)
                return 0
            if message == WM_COMMAND:
                self._command(wparam & 0xFFFF)
                return 0
        except Exception:
            logging.getLogger(__name__).exception("Could not handle the notification area command")
        return self.default_proc(hwnd, message, wparam, lparam)

    def _command(self, command):
        if command == TRAY_OPEN:
            self.on_open()
        elif command == TRAY_QUIT and not self._confirming:
            self._confirming = True
            try:
                if self.confirm_exit():
                    self.on_quit()
            finally:
                self._confirming = False

    def confirm_exit(self):
        user = c.WinDLL("user32", use_last_error=True)
        message_box = bind(user, "MessageBoxW", c.c_int, w.HWND, w.LPCWSTR, w.LPCWSTR, w.UINT)
        prompt = self._text("退出搞研究？工作台、投稿门户和小组件将关闭。请先保存正在编辑的内容。",
                            "Quit GaoYanJiu? The workbench, portal and widgets will close. Save any open edits before quitting.")
        return message_box(self.hwnd, prompt, self.title, 0x00010124) == 6

    def _show_menu(self, hwnd, coordinates):
        if self._context_active or self._confirming:
            return
        self._context_active = True
        user = c.WinDLL("user32", use_last_error=True)
        menu = bind(user, "CreatePopupMenu", w.HMENU)()
        destroy_menu = bind(user, "DestroyMenu", w.BOOL, w.HMENU)
        try:
            if not menu:
                return
            append = bind(user, "AppendMenuW", w.BOOL, w.HMENU, w.UINT, w.WPARAM, w.LPCWSTR)
            append(menu, 0, TRAY_OPEN, self._text("打开 搞研究", "Open GaoYanJiu"))
            append(menu, 0x800, 0, None)
            append(menu, 0, TRAY_QUIT, self._text("退出", "Quit"))
            point = w.POINT(c.c_short(coordinates & 0xFFFF).value, c.c_short((coordinates >> 16) & 0xFFFF).value)
            if not self._version4 or (point.x, point.y) in {(0, 0), (-1, -1)}:
                bind(user, "GetCursorPos", w.BOOL, c.POINTER(w.POINT))(c.byref(point))
            bind(user, "SetForegroundWindow", w.BOOL, w.HWND)(hwnd)
            track = bind(user, "TrackPopupMenu", w.UINT, w.HMENU, w.UINT, c.c_int, c.c_int, c.c_int, w.HWND, w.LPVOID)
            command = track(menu, 0x0182, point.x, point.y, 0, hwnd, None)
            self.post_message(hwnd, 0, 0, 0)
            if not self._closing.is_set():
                self._notify(NIM_SETFOCUS, self.data)
                self._command(command)
        finally:
            if menu:
                destroy_menu(menu)
            self._context_active = False
