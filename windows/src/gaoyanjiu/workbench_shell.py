"""Associate the app's private Edge windows with its registered shell shortcut."""

from __future__ import annotations

import ctypes as c
from ctypes import wintypes as w
from uuid import UUID

from gaoyanjiu.notifications import APP_ID
from gaoyanjiu.win_icons import bind, icon_dimensions, load_application_icon, window_dpi


class Guid(c.Structure):
    _fields_ = [("bytes", c.c_ubyte * 16)]


class PropertyKey(c.Structure):
    _fields_ = [("fmtid", Guid), ("pid", w.DWORD)]


class PropertyValue(c.Structure):
    _fields_ = [("vt", w.USHORT), ("reserved", w.USHORT * 3), ("text", w.LPCWSTR), ("tail", c.c_size_t)]


_PROPERTY_STORE = Guid.from_buffer_copy(UUID("886d8eeb-8cf2-4446-8d02-cdba1dbdcf99").bytes_le)
_APP_ID_PROPERTY = PropertyKey(Guid.from_buffer_copy(UUID("9f4c2855-9f79-4b39-a8d0-e1d42de1d5f3").bytes_le), 5)


class WorkbenchShell:
    def __init__(self, user):
        self.user = user
        self.icons = {}
        self.windows = {}
        self.shell = c.WinDLL("shell32", use_last_error=True)
        self.get_store = bind(self.shell, "SHGetPropertyStoreForWindow", c.c_long,
                              w.HWND, c.POINTER(Guid), c.POINTER(c.c_void_p))
        self.send = bind(user, "SendMessageTimeoutW", w.LPARAM, w.HWND, w.UINT, w.WPARAM, w.LPARAM,
                         w.UINT, w.UINT, c.POINTER(c.c_size_t))
        self.destroy_icon = bind(user, "DestroyIcon", w.BOOL, w.HICON)

    def set_identity(self, hwnd, app_id: str | None) -> bool:
        store = c.c_void_p()
        if self.get_store(hwnd, c.byref(_PROPERTY_STORE), c.byref(store)) < 0 or not store:
            return False
        table = c.cast(store, c.POINTER(c.POINTER(c.c_void_p))).contents
        release = c.WINFUNCTYPE(w.ULONG, c.c_void_p)(table[2])
        set_value = c.WINFUNCTYPE(c.c_long, c.c_void_p, c.POINTER(PropertyKey), c.POINTER(PropertyValue))(table[6])
        value = PropertyValue()
        if app_id is not None:
            value.vt = 31  # VT_LPWSTR
            value.text = app_id
        try:
            return set_value(store, c.byref(_APP_ID_PROPERTY), c.byref(value)) >= 0
        finally:
            release(store)

    def update(self, owned_windows) -> None:
        for hwnd in self.windows.keys() - set(owned_windows):
            self.windows.pop(hwnd)
        for hwnd in owned_windows:
            last_dpi, identified = self.windows.get(hwnd, (0, False))
            dpi = window_dpi(self.user, hwnd)
            if last_dpi != dpi and self._set_icons(hwnd, dpi):
                last_dpi = dpi
            if not identified:
                identified = self.set_identity(hwnd, APP_ID)
            self.windows[hwnd] = last_dpi, identified

    def _set_icons(self, hwnd, dpi: int) -> bool:
        applied = True
        for kind, small in ((0, True), (1, False)):
            dimensions = icon_dimensions(self.user, dpi, small=small)
            icon = self.icons.get(dimensions)
            if not icon:
                icon = load_application_icon(self.user, dimensions)
                if icon:
                    self.icons[dimensions] = icon
            if icon:
                result = c.c_size_t()
                if not self.send(hwnd, 0x0080, kind, icon, 0x0003, 150, c.byref(result)):  # WM_SETICON
                    applied = False
        return applied

    def clear_window_identity(self, hwnd) -> None:
        if self.windows.get(hwnd, (0, False))[1]:
            self.set_identity(hwnd, None)

    def close(self) -> None:
        for icon in self.icons.values():
            self.destroy_icon(icon)
        self.icons.clear()
        self.windows.clear()
