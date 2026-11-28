"""Associate the app's private Edge windows with its registered shell shortcut."""

from __future__ import annotations

import ctypes as c
from ctypes import wintypes as w
from uuid import UUID

from gaoyanjiu.notifications import APP_ID
from gaoyanjiu.win_icons import NativeWindowIcons, bind, window_dpi


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
        self.native_icons = NativeWindowIcons(user)
        self.identified = set()
        self.shell = c.WinDLL("shell32", use_last_error=True)
        self.get_store = bind(self.shell, "SHGetPropertyStoreForWindow", c.c_long,
                              w.HWND, c.POINTER(Guid), c.POINTER(c.c_void_p))

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
        self.identified.intersection_update(owned_windows)
        for hwnd in owned_windows:
            # Edge can load a favicon after the first HWND update or after a navigation.
            self.native_icons.apply(hwnd, window_dpi(self.user, hwnd))
            if hwnd not in self.identified and self.set_identity(hwnd, APP_ID):
                self.identified.add(hwnd)

    def clear_window_identity(self, hwnd) -> None:
        if hwnd in self.identified:
            self.set_identity(hwnd, None)

    def close(self) -> None:
        self.native_icons.close()
        self.identified.clear()
