"""Own the dedicated Edge app windows without touching the user's browser session."""

from __future__ import annotations

import ctypes as c
import logging
import os
import subprocess
import tempfile
import threading
import time
import webbrowser
from ctypes import wintypes as w
from pathlib import Path

from gaoyanjiu.session import edge_executable
from gaoyanjiu.tray import WM_CLOSE
from gaoyanjiu.win_icons import bind
from gaoyanjiu.workbench_shell import WorkbenchShell

ENUM_WINDOWS = c.WINFUNCTYPE(w.BOOL, w.HWND, w.LPARAM)


class StartupInfo(c.Structure):
    _fields_ = [
        ("size", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR), ("title", w.LPWSTR),
        ("x", w.DWORD), ("y", w.DWORD), ("width", w.DWORD), ("height", w.DWORD),
        ("columns", w.DWORD), ("rows", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD),
        ("show", w.WORD), ("reserved_size", w.WORD), ("reserved_bytes", c.c_void_p),
        ("input", w.HANDLE), ("output", w.HANDLE), ("error", w.HANDLE),
    ]


class ProcessInfo(c.Structure):
    _fields_ = [("process", w.HANDLE), ("thread", w.HANDLE), ("pid", w.DWORD), ("tid", w.DWORD)]


class BasicJobLimits(c.Structure):
    _fields_ = [
        ("process_time", c.c_int64), ("job_time", c.c_int64), ("flags", w.DWORD),
        ("min_working_set", c.c_size_t), ("max_working_set", c.c_size_t),
        ("active_process_limit", w.DWORD), ("affinity", c.c_size_t),
        ("priority", w.DWORD), ("scheduling", w.DWORD),
    ]


class JobLimits(c.Structure):
    _fields_ = [
        ("basic", BasicJobLimits), ("io", c.c_uint64 * 6),
        ("process_memory", c.c_size_t), ("job_memory", c.c_size_t),
        ("peak_process_memory", c.c_size_t), ("peak_job_memory", c.c_size_t),
    ]


class JobAccounting(c.Structure):
    _fields_ = [
        ("times", c.c_int64 * 4), ("page_faults", w.DWORD), ("total", w.DWORD),
        ("active", w.DWORD), ("terminated", w.DWORD),
    ]


class WorkbenchBrowser:
    def __init__(self):
        self._lock = threading.Lock()
        self._job = None
        self._profile = None
        self._process = None
        self._started = 0.0
        self._kernel = c.WinDLL("kernel32", use_last_error=True)
        self._user = c.WinDLL("user32", use_last_error=True)
        self._close_handle = bind(self._kernel, "CloseHandle", w.BOOL, w.HANDLE)
        self._wait = bind(self._kernel, "WaitForSingleObject", w.DWORD, w.HANDLE, w.DWORD)
        self._shell = WorkbenchShell(self._user)
        self._shell_stop = threading.Event()
        self._shell_thread = None

    def open(self, url, *, restore=True):
        """Return true when an existing or starting window can consume a pending route."""
        with self._lock:
            windows = self._windows()
            if restore and windows:
                hwnd = windows[0]
                if bind(self._user, "IsIconic", w.BOOL, w.HWND)(hwnd):
                    bind(self._user, "ShowWindow", w.BOOL, w.HWND, c.c_int)(hwnd, 9)  # SW_RESTORE
                if not bind(self._user, "SetForegroundWindow", w.BOOL, w.HWND)(hwnd):
                    bind(self._user, "FlashWindow", w.BOOL, w.HWND, w.BOOL)(hwnd, True)
                return True
            if time.monotonic() - self._started < 3 and self._active():
                return True
            if self._process:
                self._close_handle(self._process)
                self._process = None
            edge = edge_executable()
            if edge is not None:
                try:
                    self._start(edge, url)
                    return False
                except OSError:
                    logging.getLogger(__name__).exception("Could not start the isolated Edge workbench")
            webbrowser.open(url)
            return False

    def _start(self, edge, url):
        if self._job is None:
            job = bind(self._kernel, "CreateJobObjectW", w.HANDLE, w.LPVOID, w.LPCWSTR)(None, None)
            if not job:
                raise c.WinError(c.get_last_error())
            limits = JobLimits()
            limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            configure = bind(self._kernel, "SetInformationJobObject", w.BOOL, w.HANDLE,
                             c.c_int, w.LPVOID, w.DWORD)
            if not configure(job, 9, c.byref(limits), c.sizeof(limits)):
                error = c.get_last_error()
                self._close_handle(job)
                raise c.WinError(error)
            self._job = job
        if self._profile is None:
            self._profile = tempfile.TemporaryDirectory(prefix="gaoyanjiu-workbench-", ignore_cleanup_errors=True)
        arguments = [str(edge), f"--user-data-dir={self._profile.name}", f"--app={url}",
                     "--no-first-run", "--no-default-browser-check", "--disable-background-mode",
                     "--disable-features=msEdgeStartupBoost"]
        command = c.create_unicode_buffer(subprocess.list2cmdline(arguments))
        startup = StartupInfo()
        startup.size = c.sizeof(startup)
        child = ProcessInfo()
        create = bind(self._kernel, "CreateProcessW", w.BOOL, w.LPCWSTR, w.LPWSTR,
                      w.LPVOID, w.LPVOID, w.BOOL, w.DWORD, w.LPVOID, w.LPCWSTR,
                      c.POINTER(StartupInfo), c.POINTER(ProcessInfo))
        # Assign before the first browser thread runs so even early children belong to this app.
        if not create(str(edge), command, None, None, False, 0x4, None, str(Path(edge).parent),
                      c.byref(startup), c.byref(child)):  # CREATE_SUSPENDED
            raise c.WinError(c.get_last_error())
        try:
            assign = bind(self._kernel, "AssignProcessToJobObject", w.BOOL, w.HANDLE, w.HANDLE)
            if not assign(self._job, child.process):
                raise c.WinError(c.get_last_error())
            resume_thread = bind(self._kernel, "ResumeThread", w.DWORD, w.HANDLE)
            if resume_thread(child.thread) == 0xFFFFFFFF:
                raise c.WinError(c.get_last_error())
            self._process = child.process
            self._started = time.monotonic()
        except OSError:
            bind(self._kernel, "TerminateProcess", w.BOOL, w.HANDLE, w.UINT)(child.process, 1)
            self._wait(child.process, 1000)
            self._close_handle(child.process)
            raise
        finally:
            self._close_handle(child.thread)

        if self._shell_thread is None:
            self._shell_thread = threading.Thread(target=self._update_shell_windows, name="GaoYanJiuShell", daemon=True)
            self._shell_thread.start()

    def _update_shell_windows(self):
        ole = c.WinDLL("ole32", use_last_error=True)
        initialized = bind(ole, "CoInitializeEx", c.c_long, c.c_void_p, w.DWORD)(None, 2) >= 0
        try:
            while not self._shell_stop.is_set():
                with self._lock:
                    if self._shell_stop.is_set():
                        return
                    active = self._active()
                    self._shell.update(self._windows() if active else ())
                    delay = 0.20 if active and time.monotonic() - self._started < 4 else 1.0
                self._shell_stop.wait(delay)
        finally:
            if initialized:
                bind(ole, "CoUninitialize", None)()

    def _windows(self):
        windows = []
        if not self._job:
            return windows
        open_process = bind(self._kernel, "OpenProcess", w.HANDLE, w.DWORD, w.BOOL, w.DWORD)
        in_job = bind(self._kernel, "IsProcessInJob", w.BOOL, w.HANDLE, w.HANDLE, c.POINTER(w.BOOL))
        visible = bind(self._user, "IsWindowVisible", w.BOOL, w.HWND)
        get_class = bind(self._user, "GetClassNameW", c.c_int, w.HWND, w.LPWSTR, c.c_int)
        owner_pid = bind(self._user, "GetWindowThreadProcessId", w.DWORD, w.HWND, c.POINTER(w.DWORD))

        @ENUM_WINDOWS
        def visit(hwnd, _):
            name = c.create_unicode_buffer(64)
            if visible(hwnd) and get_class(hwnd, name, len(name)) and name.value.startswith("Chrome_WidgetWin_"):
                pid = w.DWORD()
                owner_pid(hwnd, c.byref(pid))
                process = open_process(0x1000, False, pid.value)  # PROCESS_QUERY_LIMITED_INFORMATION
                if process:
                    try:
                        member = w.BOOL()
                        if in_job(process, self._job, c.byref(member)) and member.value:
                            windows.append(hwnd)
                    finally:
                        self._close_handle(process)
            return True

        bind(self._user, "EnumWindows", w.BOOL, ENUM_WINDOWS, w.LPARAM)(visit, 0)
        return windows

    def _active(self):
        if not self._job:
            return 0
        accounting = JobAccounting()
        query = bind(self._kernel, "QueryInformationJobObject", w.BOOL, w.HANDLE, c.c_int,
                     w.LPVOID, w.DWORD, c.POINTER(w.DWORD))
        if query(self._job, 1, c.byref(accounting), c.sizeof(accounting), None):
            return accounting.active
        return 0

    def _wait_for_job(self, timeout):
        deadline = time.monotonic() + timeout
        while self._active() and time.monotonic() < deadline:
            time.sleep(.05)

    def close(self):
        self._shell_stop.set()
        with self._lock:
            if self._job:
                post = bind(self._user, "PostMessageW", w.BOOL, w.HWND, w.UINT, w.WPARAM, w.LPARAM)
                for window in self._windows():
                    self._shell.clear_window_identity(window)
                    post(window, WM_CLOSE, 0, 0)
                self._wait_for_job(1.2)
                if self._active():
                    bind(self._kernel, "TerminateJobObject", w.BOOL, w.HANDLE, w.UINT)(self._job, 0)
                    self._wait_for_job(1.2)
                self._close_handle(self._job)
                self._job = None
            self._shell.close()
            if self._process:
                self._wait(self._process, 1200)
                self._close_handle(self._process)
                self._process = None
            if self._profile:
                # Windows may still be releasing Chromium's file handles after its processes exit.
                deadline = time.monotonic() + 4
                while True:
                    self._profile.cleanup()
                    if not Path(self._profile.name).exists() or time.monotonic() >= deadline:
                        break
                    time.sleep(.10)
                self._profile = None
