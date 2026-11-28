"""Load the application's Windows icon at the size requested by the shell."""

from __future__ import annotations

import ctypes as c
import sys
from ctypes import wintypes as w
from pathlib import Path

APP_ICON_FILE = "GaoYanJiu.ico"
SM_CXICON, SM_CYICON = 11, 12
SM_CXSMICON, SM_CYSMICON = 49, 50


def bind(library, name, result, *arguments):
    function = getattr(library, name)
    function.argtypes = arguments
    function.restype = result
    return function


def application_icon_path() -> Path:
    if getattr(sys, "frozen", False):
        return Path(sys._MEIPASS) / "gaoyanjiu_assets" / APP_ICON_FILE
    return Path(__file__).resolve().parents[2] / "build" / APP_ICON_FILE


def window_dpi(user, hwnd) -> int:
    if hwnd and hasattr(user, "GetDpiForWindow"):
        dpi = bind(user, "GetDpiForWindow", w.UINT, w.HWND)(hwnd)
        if dpi:
            return dpi
    if hasattr(user, "GetDpiForSystem"):
        return bind(user, "GetDpiForSystem", w.UINT)() or 96
    return 96


def icon_dimensions(user, dpi: int, *, small: bool) -> tuple[int, int]:
    base = 16 if small else 32
    fallback = (base * dpi + 48) // 96
    if hasattr(user, "GetSystemMetricsForDpi"):
        metric = bind(user, "GetSystemMetricsForDpi", c.c_int, c.c_int, w.UINT)
        width, height = (SM_CXSMICON, SM_CYSMICON) if small else (SM_CXICON, SM_CYICON)
        return metric(width, dpi) or fallback, metric(height, dpi) or fallback
    return fallback, fallback


def load_application_icon(user, dimensions: tuple[int, int], *, source: Path | None = None):
    icon = application_icon_path() if source is None else source
    if not icon.is_file():
        return None
    load = bind(user, "LoadImageW", w.HANDLE, w.HINSTANCE, w.LPCWSTR, w.UINT, c.c_int, c.c_int, w.UINT)
    return load(None, str(icon), 1, *dimensions, 0x10)  # IMAGE_ICON, LR_LOADFROMFILE
