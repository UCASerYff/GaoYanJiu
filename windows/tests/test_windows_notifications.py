from __future__ import annotations

import base64
import json
import os
import subprocess
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from xml.etree import ElementTree

import pytest

from gaoyanjiu.errors import AppError
from gaoyanjiu.library import Library
from gaoyanjiu.notifications import (
    GROUP,
    MAX_SCHEDULED,
    STATE_NAME,
    ReminderInput,
    ReminderWorker,
    SubmissionState,
    WindowsReminderTransport,
    paper_ref,
    plan_reminders,
    reminder_paper,
)
from gaoyanjiu.session import link_destination
from gaoyanjiu.store import ResearchStore
from gaoyanjiu.timeutil import format_iso

SHANGHAI = timezone(timedelta(hours=8))
NOW = datetime(2026, 11, 27, 10, tzinfo=timezone.utc)


def paper(key: str, *, since="2026-11-01T08:00:00Z", status="审稿中", hidden=False):
    return SubmissionState(key, "测试论文 <样本> & 中文", status, since, hidden)


def test_plans_local_morning_excludes_ineligible_and_safely_routes_exact_record():
    rows = (
        paper("overdue"), paper("future", since="2026-11-20T23:00:00Z"),
        paper("archived", hidden=True), paper("terminal", status="Accepted"),
        paper("missing-time", since=""), paper("unknown-status", status=""),
    )
    change = ReminderInput(True, 14, "zh-Hans", rows)
    scheduled, prior, removed = plan_reminders(change, NOW, {}, SHANGHAI)
    reference = paper_ref("overdue")
    assert len(scheduled) == 2
    assert scheduled[0]["due"] == "2026-11-28T01:00:00Z"
    assert scheduled[1]["due"] == "2026-12-05T01:00:00Z"
    toast = ElementTree.fromstring(scheduled[0]["xml"])
    assert toast.attrib == {"activationType": "protocol", "launch": f"gaoyanjiu://follow-up/{reference}"}
    assert "测试论文 <样本> & 中文" in toast.findall(".//text")[1].text
    assert "14 天" in toast.findall(".//text")[1].text
    assert link_destination(toast.attrib["launch"]) == (f"follow-up/{reference}", "")
    with pytest.raises(AppError):
        link_destination(toast.attrib["launch"] + "?path=C:\\private")
    assert sorted(prior) == sorted(paper_ref(row.key) for row in rows[:2])
    assert removed == []


def test_pending_morning_does_not_slide_and_delivered_epoch_does_not_repeat():
    old = paper("stable")
    change = ReminderInput(True, 14, "en", (old,))
    initial, saved, _ = plan_reminders(change, NOW, {}, SHANGHAI)
    later = NOW + timedelta(hours=10)
    same, saved, _ = plan_reminders(change, later, saved, SHANGHAI)
    assert same == initial
    waiting_overdue, saved, _ = plan_reminders(change, later + timedelta(hours=8), saved, SHANGHAI)
    assert waiting_overdue == initial
    saved[paper_ref(old.key)]["sent"] = True
    delivered, saved, _ = plan_reminders(change, later + timedelta(hours=8), saved, SHANGHAI)
    assert not delivered
    assert set(saved) == {paper_ref(old.key)}

    advancing = ReminderInput(True, 14, "en", (paper(old.key, since="2026-11-28T00:00:00Z"),))
    next_time, _, removed = plan_reminders(advancing, later + timedelta(hours=8), saved, SHANGHAI)
    assert len(next_time) == 1
    assert next_time[0]["due"] == "2026-12-12T01:00:00Z"
    assert next_time[0]["tag"] != initial[0]["tag"]
    assert removed == [initial[0]["tag"]]


def test_scheduling_caps_active_toasts_and_removes_terminal_and_hidden_entries():
    rows = tuple(paper(str(index)) for index in range(MAX_SCHEDULED + 2))
    expected = ReminderInput(True, 14, "en", rows)
    scheduled, prior, _ = plan_reminders(expected, NOW, {}, timezone.utc)
    assert len(scheduled) == MAX_SCHEDULED
    assert len({entry["tag"] for entry in scheduled}) == MAX_SCHEDULED
    reduced = ReminderInput(True, 14, "en", (paper("0", status="Rejected"), paper("1", hidden=True), *rows[2:]))
    new, _, removed = plan_reminders(reduced, NOW, prior, timezone.utc)
    assert len(new) == MAX_SCHEDULED
    assert set(removed) == {scheduled[0]["tag"], scheduled[1]["tag"]}
    disabled = ReminderInput(False, 14, "en", rows)
    pending, ledger, removed = plan_reminders(disabled, NOW, prior, timezone.utc)
    assert pending == [] and ledger == {} and len(removed) == MAX_SCHEDULED


class FakeNativeTransport:
    def __init__(self):
        self.calls = []

    def synchronize(self, enabled, records, removed):
        self.calls.append((enabled, records, removed))
        return {"state": "active", "count": len(records)}


def test_isolated_settings_worker_preserves_old_clients_and_uses_opaque_routes(tmp_path):
    root = tmp_path / "isolated"
    library = Library(root).open()
    library.create_empty()
    (root / "settings.json").write_text('{"followUpDays":14,"customSetting":"preserve"}', encoding="utf-8")
    store = ResearchStore(library, clock=lambda: NOW)
    assert not store.settings["notificationsEnabled"]
    assert ReminderWorker.for_store(store) is None
    key = store.save_paper(None, "合成题目", "Test", "ABC", "审稿中", "2026-11-22", "", "")
    reference = paper_ref(key)
    assert reminder_paper(store, reference)["key"] == key
    assert reminder_paper(store, "0" * 40) is None
    assert reminder_paper(store, key) is None

    native = FakeNativeTransport()
    store.reminders = ReminderWorker(root, native, store.clock)
    store.update_settings("dark", "zh-Hans", 14, True)
    store.update_settings("dark", "zh-Hans", 14)
    store.reminders.close()
    assert native.calls == [(True, [], [])]
    assert store.reminders.status() == {"state": "active", "count": 1}
    assert store.settings["customSetting"] == "preserve"
    persisted = json.loads((root / STATE_NAME).read_text(encoding="ascii"))
    assert set(persisted["papers"]) == {reference}
    assert "合成题目" not in str(persisted)

    due = datetime(2026, 12, 20, 13, tzinfo=timezone.utc)
    store.clock = lambda: due
    store.reminders = ReminderWorker(root, native, store.clock)
    store.reminders.submit(store)
    store.reminders.close()
    sent = native.calls[-1][1]
    assert len(sent) == 1 and sent[0]["ref"] == reference

    store.reminders = ReminderWorker(root, native, store.clock)
    store.reminders.submit(store)
    store.reminders.close()
    assert native.calls[-1] == (True, [], [])
    assert store.reminders.status() == {"state": "active", "count": 0}

    store.reminders = ReminderWorker(root, native, store.clock)
    store.update_settings("dark", "zh-Hans", 14, False)
    store.reminders.close()
    assert native.calls[-1] == (False, [], [sent[0]["tag"]])
    assert store.reminders.status() == {"state": "off", "count": 0}
    assert not (root / STATE_NAME).exists()


def _run_native_test(script, request):
    command = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
    powershell = Path(os.environ["SystemRoot"]) / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
    result = subprocess.run([str(powershell), "-NoProfile", "-NonInteractive", "-EncodedCommand", command],
                            input=json.dumps(request, ensure_ascii=True).encode("ascii"), capture_output=True,
                            check=True, timeout=12, creationflags=subprocess.CREATE_NO_WINDOW)
    return json.loads(result.stdout)


def _register_test_shortcut(app_id, clsid, shortcut):
    return _run_native_test(r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$request = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd())
if (Test-Path -LiteralPath $request.shortcut) { throw 'Synthetic shortcut already exists' }
$link = (New-Object -ComObject WScript.Shell).CreateShortcut($request.shortcut)
$link.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$link.Save()
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class SyntheticToastLink {
    [StructLayout(LayoutKind.Sequential)]
    struct PropertyKey { public Guid Format; public int Id; }
    [StructLayout(LayoutKind.Explicit, Size = 24)]
    struct Value {
        [FieldOffset(0)] public ushort Type;
        [FieldOffset(8)] public IntPtr Data;
    }
    [ComImport, Guid("886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IPropertyStore {
        void GetCount(out uint count);
        void GetAt(uint index, out PropertyKey key);
        void GetValue(ref PropertyKey key, out Value value);
        void SetValue(ref PropertyKey key, ref Value value);
        void Commit();
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern void SHChangeNotify(uint eventId, uint flags, string path, IntPtr reserved);
    public static void Set(string path, string appId, string activator) {
        object link = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("00021401-0000-0000-C000-000000000046")));
        IntPtr name = Marshal.StringToCoTaskMemUni(appId);
        IntPtr guid = Marshal.AllocCoTaskMem(16);
        try {
            Marshal.StructureToPtr(new Guid(activator), guid, false);
            var storage = (IPersistFile)link;
            var properties = (IPropertyStore)link;
            storage.Load(path, 2);
            var key = new PropertyKey { Format = new Guid("9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3"), Id = 5 };
            var value = new Value { Type = 31, Data = name };
            properties.SetValue(ref key, ref value);
            key.Id = 26;
            value = new Value { Type = 72, Data = guid };
            properties.SetValue(ref key, ref value);
            properties.Commit();
            storage.Save(path, true);
            SHChangeNotify(0x00000002, 0x0005, path, IntPtr.Zero);
        } finally {
            Marshal.FreeCoTaskMem(name);
            Marshal.FreeCoTaskMem(guid);
            Marshal.FinalReleaseComObject(link);
        }
    }
}
'@
[SyntheticToastLink]::Set($request.shortcut, $request.appID, $request.clsid)
[Console]::Out.Write('true')
""", {"appID": app_id, "clsid": clsid, "shortcut": str(shortcut)})


def _native_history(app_id):
    script = r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.ToastNotificationHistory, Windows.UI.Notifications, ContentType=WindowsRuntime]
$appID = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd())
$history = [Windows.UI.Notifications.ToastNotificationManager]::History
$results = @($history.GetHistory($appID) | ForEach-Object { @{group=$_.Group; tag=$_.Tag; xml=$_.Content.GetXml()} })
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::Out.Write((ConvertTo-Json -InputObject $results -Compress))
"""
    return _run_native_test(script, app_id)


@pytest.mark.skipif(os.name != "nt" or os.environ.get("GAO_RESEARCH_NATIVE_REMINDER_TEST") != "1",
                    reason="requires Windows and opt-in for an isolated no-banner test AUMID")
def test_native_winrt_worker_delivers_once_and_removes_obsolete_notification(tmp_path):
    import winreg

    app_id = "GaoSeries.GaoYanJiu.ReminderProbe." + uuid.uuid4().hex
    registration = r"Software\Classes\AppUserModelId" + "\\" + app_id
    clsid = "{" + str(uuid.uuid4()).upper() + "}"
    programs = Path(os.environ["APPDATA"]) / "Microsoft" / "Windows" / "Start Menu" / "Programs"
    shortcut = programs / (app_id + ".lnk")
    transport = WindowsReminderTransport(app_id, suppress_popup=True)
    worker = None
    try:
        with winreg.CreateKeyEx(winreg.HKEY_CURRENT_USER, registration, 0, winreg.KEY_WRITE) as key:
            winreg.SetValueEx(key, "DisplayName", 0, winreg.REG_SZ, "搞研究隔离测试")
            winreg.SetValueEx(key, "CustomActivator", 0, winreg.REG_SZ, clsid)
        assert _register_test_shortcut(app_id, clsid, shortcut)
        library = Library(tmp_path / "data").open()
        library.create_empty()
        store = ResearchStore(library)
        key = store.save_paper(None, "合成稿件标题", "Test", "ABC", "审稿中", "2026-11-22", "", "")
        reference = paper_ref(key)
        store.update_settings("system", "zh-Hans", 14, True)

        change = ReminderInput(True, 14, "zh-Hans", (paper(key, since=store.list_papers()[0]["statusSince"]),))
        now = store.clock()
        records, state, _ = plan_reminders(change, now, {})
        state[reference]["due"] = format_iso(now + timedelta(seconds=4))
        (store.library.root / STATE_NAME).write_text(json.dumps({"schema": 1, "papers": state}), encoding="ascii")
        worker = store.reminders = ReminderWorker(store.library.root, transport, store.clock)
        worker.submit(store)
        until = time.monotonic() + 12
        while time.monotonic() < until:
            history = [entry for entry in _native_history(app_id) if entry["group"] == GROUP and entry["tag"] == records[0]["tag"]]
            if history:
                break
            time.sleep(0.25)
        assert len(history) == 1
        launch = ElementTree.fromstring(history[0]["xml"]).attrib["launch"]
        assert link_destination(launch) == (f"follow-up/{reference}", "")
        worker.close()

        worker = store.reminders = ReminderWorker(store.library.root, transport, store.clock)
        worker.submit(store)
        worker.close()
        assert len(_native_history(app_id)) == 1
        worker = store.reminders = ReminderWorker(store.library.root, transport, store.clock)
        store.set_hidden(key, True)
        worker.close()
        assert not _native_history(app_id)
    finally:
        if worker:
            worker.close()
        try:
            transport.synchronize(False, [], [])
        finally:
            winreg.DeleteKey(winreg.HKEY_CURRENT_USER, registration)
            shortcut.unlink(missing_ok=True)
