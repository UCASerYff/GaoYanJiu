"""Read the Windows executable identity values used for legacy app handoffs."""

from __future__ import annotations

import ctypes
import os
from ctypes import wintypes
from pathlib import Path


def version_strings(path: Path) -> dict[str, str]:
    if os.name != "nt":
        return {}
    version = ctypes.WinDLL("version", use_last_error=True)
    version.GetFileVersionInfoSizeW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(wintypes.DWORD)]
    version.GetFileVersionInfoSizeW.restype = wintypes.DWORD
    version.GetFileVersionInfoW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID]
    version.GetFileVersionInfoW.restype = wintypes.BOOL
    version.VerQueryValueW.argtypes = [wintypes.LPCVOID, wintypes.LPCWSTR, ctypes.POINTER(wintypes.LPVOID), ctypes.POINTER(wintypes.UINT)]
    version.VerQueryValueW.restype = wintypes.BOOL

    filename = os.fspath(path)
    resource_size = version.GetFileVersionInfoSizeW(filename, None)
    if not 0 < resource_size <= 1024 * 1024:
        return {}
    resource = ctypes.create_string_buffer(resource_size)
    if not version.GetFileVersionInfoW(filename, 0, resource_size, resource):
        return {}

    pointer = wintypes.LPVOID()
    length = wintypes.UINT()

    def query(sub_block):
        return version.VerQueryValueW(resource, sub_block, ctypes.byref(pointer), ctypes.byref(length))

    if not query(r"\VarFileInfo\Translation") or not 4 <= length.value <= 256 or length.value % 4:
        return {}
    words = ctypes.cast(pointer, ctypes.POINTER(wintypes.WORD))
    translations = [(words[index], words[index + 1]) for index in range(0, length.value // 2, 2)]
    keys = ("CompanyName", "ProductName", "FileVersion", "ProductVersion")
    for language, codepage in translations:
        prefix = rf"\StringFileInfo\{language:04x}{codepage:04x}"
        data = {}
        for key in keys:
            if query(prefix + "\\" + key) and 0 < length.value <= 1024:
                data[key] = ctypes.wstring_at(pointer, length.value).rstrip("\0")
        if len(data) == len(keys):
            return data
    return {}
