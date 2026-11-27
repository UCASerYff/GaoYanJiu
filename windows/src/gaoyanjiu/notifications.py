from __future__ import annotations

import base64
import hashlib
import json
import os
import subprocess
import threading
from dataclasses import dataclass
from datetime import datetime, time, timedelta, timezone, tzinfo
from pathlib import Path
from xml.etree import ElementTree

from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import atomic_write, read_regular_bytes
from gaoyanjiu.status import is_terminal
from gaoyanjiu.timeutil import format_iso, parse_iso

APP_ID = "GaoSeries.GaoYanJiu"
REGISTRY_IDENTITY = r"Software\Classes\AppUserModelId\GaoSeries.GaoYanJiu"
GROUP = "GaoResearch"
STATE_NAME = "windows-reminders.json"
MAX_SCHEDULED = 60
MAX_STATE_BYTES = 2 * 1024 * 1024
WINDOWS_ID_LENGTH = 15

_NATIVE = r"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.ToastNotifier, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.ToastNotificationHistory, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.NotificationSetting, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.UI.Notifications.NotificationMirroring, Windows.UI.Notifications, ContentType=WindowsRuntime]
[void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType=WindowsRuntime]
$request = ConvertFrom-Json -InputObject ([Console]::In.ReadToEnd())
$notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($request.appID)
$history = [Windows.UI.Notifications.ToastNotificationManager]::History
if ($request.clearHistory) { $history.RemoveGroup($request.group, $request.appID) }
else {
    foreach ($tag in @($request.removeTags)) { $history.Remove($tag, $request.group, $request.appID) }
}
$setting = [string]$notifier.Setting
if ($request.enabled -and $setting -and $setting -ne 'Enabled') {
    [Console]::Out.Write((ConvertTo-Json -InputObject @{state='blocked'; count=0} -Compress))
    exit 0
}
$knownTags = @()
if ($request.records.Count -gt 0) {
    $knownTags = @($history.GetHistory($request.appID) | Where-Object Group -EQ $request.group | ForEach-Object Tag)
}
$shown = @(
    foreach ($record in @($request.records)) {
        if ($knownTags -notcontains $record.tag) {
            $content = [Windows.Data.Xml.Dom.XmlDocument]::new()
            $content.LoadXml($record.xml)
            $toast = [Windows.UI.Notifications.ToastNotification]::new($content)
            $toast.Tag = $record.tag
            $toast.Group = $request.group
            try { $toast.NotificationMirroring = [Windows.UI.Notifications.NotificationMirroring]::Disabled } catch {}
            $toast.SuppressPopup = [bool]$request.suppressPopup
            $notifier.Show($toast)
        }
        $record.tag
    }
)
[Console]::Out.Write((ConvertTo-Json -InputObject @{state='active'; count=$shown.Count; tags=$shown} -Compress))
"""


def _digest(*values: str) -> str:
    return hashlib.sha256(json.dumps(values, ensure_ascii=True, separators=(",", ":")).encode("ascii")).hexdigest()


def paper_ref(key: str) -> str:
    return _digest(key)[:40]


def _toast_tag(reference: str, epoch: str) -> str:
    return _digest(reference, epoch)[:WINDOWS_ID_LENGTH]


def reminder_paper(store, reference: str) -> dict | None:
    if len(reference) != 40 or any(character not in "0123456789abcdef" for character in reference):
        return None
    data = store.library.data or {}
    for paper in data.get("papers", []):
        key = paper.get("key")
        if isinstance(key, str) and paper_ref(key) == reference:
            return paper
    return None


def _xml_text(value: str, limit: int) -> str:
    allowed = (char for char in value if char in "\t\n\r" or 0x20 <= ord(char) <= 0xD7FF
               or 0xE000 <= ord(char) <= 0xFFFD or ord(char) >= 0x10000)
    text = " ".join("".join(allowed).split())
    return text if len(text) <= limit else text[:limit - 1] + "…"


def _toast_xml(reference: str, title: str, status: str, days: int, language: str) -> str:
    link = f"gaoyanjiu://follow-up/{reference}"
    toast = ElementTree.Element("toast", {"activationType": "protocol", "launch": link})
    visual = ElementTree.SubElement(toast, "visual")
    binding = ElementTree.SubElement(visual, "binding", {"template": "ToastGeneric"})
    if language == "en":
        heading = "Submission status reminder"
        body = f"“{title}” has been “{status}” for at least {days} days. Check the submission or update its status."
    else:
        heading = "投稿状态提醒"
        body = f"“{title}”保持“{status}”状态已达到 {days} 天，请考虑检查或更新。"
    ElementTree.SubElement(binding, "text").text = heading
    ElementTree.SubElement(binding, "text").text = body
    return ElementTree.tostring(toast, encoding="unicode")


@dataclass(frozen=True)
class SubmissionState:
    key: str
    title: str
    status: str
    since: str
    hidden: bool


@dataclass(frozen=True)
class ReminderInput:
    enabled: bool
    days: int
    language: str
    papers: tuple[SubmissionState, ...]


def _snapshot(store) -> ReminderInput:
    data = store.library.data
    settings = store.settings
    enabled = bool(store.library.writable and data is not None and settings.get("notificationsEnabled") is True)
    papers = tuple(
        SubmissionState(row["key"], str(row.get("title") or ""), str(row.get("status") or ""),
                        str(row.get("statusSince") or ""), bool(row.get("hidden")))
        for row in data.get("papers", []) if isinstance(row.get("key"), str) and row["key"]
    ) if enabled else ()
    return ReminderInput(enabled, settings["followUpDays"], store.language(), papers)


def _morning(day, local_zone: tzinfo | None) -> datetime:
    return datetime.combine(day, time(9), tzinfo=local_zone).astimezone(timezone.utc)


def _target(since: datetime, days: int, now: datetime, local_zone: tzinfo | None) -> datetime:
    preferred = _morning(since.astimezone(local_zone).date() + timedelta(days=days), local_zone)
    if preferred > now:
        return preferred
    tomorrow = now.astimezone(local_zone).date() + timedelta(days=1)
    return _morning(tomorrow, local_zone)


def plan_reminders(
    change: ReminderInput, now: datetime, prior: dict,
    local_zone: tzinfo | None = None,
) -> tuple[list[dict], dict, list[str]]:
    records = []
    state = {}
    stale_tags = set(prior)
    if not change.enabled:
        return records, state, sorted(_toast_tag(ref, prior[ref]["epoch"]) for ref in stale_tags)
    for paper in change.papers:
        if paper.hidden or not paper.status.strip() or is_terminal(paper.status):
            continue
        try:
            since = parse_iso(paper.since)
            epoch = _digest(paper.status, format_iso(since), str(change.days))
            ref = paper_ref(paper.key)
            previous = prior.get(ref, {})
            if previous.get("epoch") == epoch:
                stale_tags.discard(ref)
                due = parse_iso(previous.get("due", ""))
                if previous.get("sent") is True:
                    state[ref] = {"epoch": epoch, "due": format_iso(due), "sent": True}
                    continue
            else:
                due = _target(since, change.days, now, local_zone)
        except (ValueError, OverflowError):
            continue
        if len(records) >= MAX_SCHEDULED:
            continue
        title = _xml_text(paper.title, 160) or ("Untitled submission" if change.language == "en" else "未命名稿件")
        status = _xml_text(paper.status, 80)
        xml = _toast_xml(ref, title, status, change.days, change.language)
        due_string = format_iso(due)
        records.append({"tag": _toast_tag(ref, epoch), "ref": ref, "due": due_string, "xml": xml})
        state[ref] = {"epoch": epoch, "due": due_string, "sent": False}
    return records, state, sorted(_toast_tag(ref, prior[ref]["epoch"]) for ref in stale_tags)


def _read_state(path: Path) -> dict:
    try:
        saved = json.loads(read_regular_bytes(path, MAX_STATE_BYTES))
        rows = saved.get("papers", {}) if isinstance(saved, dict) and saved.get("schema") == 1 else {}
        if not isinstance(rows, dict):
            return {}
        output = {}
        for reference, row in rows.items():
            if len(reference) != 40 or any(character not in "0123456789abcdef" for character in reference):
                continue
            if not isinstance(row, dict) or not isinstance(row.get("epoch"), str) or not isinstance(row.get("due"), str):
                continue
            try:
                parse_iso(row["due"])
            except ValueError:
                continue
            output[reference] = {"epoch": row["epoch"], "due": row["due"], "sent": row.get("sent") is True}
        return output
    except (AppError, OSError, ValueError):
        return {}


class WindowsReminderTransport:
    def __init__(self, app_id: str = APP_ID, suppress_popup: bool = False):
        self.app_id = app_id
        self.suppress_popup = suppress_popup

    def synchronize(self, enabled: bool, records: list[dict], removed: list[str]) -> dict:
        payload = json.dumps({"appID": self.app_id, "group": GROUP, "enabled": enabled, "records": records,
                              "removeTags": removed, "clearHistory": not enabled, "suppressPopup": self.suppress_popup},
                             ensure_ascii=False).encode("utf-8")
        root = Path(os.environ.get("SystemRoot", r"C:\Windows"))
        executable = root / "System32" / "WindowsPowerShell" / "v1.0" / "powershell.exe"
        encoded = base64.b64encode(_NATIVE.encode("utf-16-le")).decode("ascii")
        process = subprocess.run(
            [str(executable), "-NoProfile", "-NonInteractive", "-EncodedCommand", encoded],
            input=payload, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=True,
            timeout=10, creationflags=subprocess.CREATE_NO_WINDOW,
        )
        result = json.loads(process.stdout)
        if not isinstance(result, dict):
            raise OSError("Windows returned an invalid reminder schedule")
        if result.get("state") == "active":
            expected = {row["tag"] for row in records}
            if set(result.get("tags", [])) != expected or result.get("count") != len(records):
                raise OSError("Windows returned incomplete reminder delivery")
        elif result.get("state") != "blocked":
            raise OSError("Windows returned an invalid reminder schedule")
        return result


def _registered_identity() -> bool:
    import winreg

    try:
        with winreg.OpenKey(winreg.HKEY_CURRENT_USER, REGISTRY_IDENTITY) as identity:
            return winreg.QueryValueEx(identity, "CustomActivator")[0] == "{F35C7BDD-954B-41DD-A863-F60CC0C192D7}"
    except OSError:
        return False


def clear_system_reminders() -> None:
    if os.name == "nt" and _registered_identity():
        WindowsReminderTransport().synchronize(False, [], [])


class ReminderWorker:
    def __init__(self, root: Path, transport: WindowsReminderTransport, clock):
        self._path = root / STATE_NAME
        self._transport = transport
        self._clock = clock
        self._condition = threading.Condition()
        self._pending: ReminderInput | None = None
        self._scheduled: ReminderInput | None = None
        self._running: ReminderInput | None = None
        self._wake_at: datetime | None = None
        self._closed = False
        self._status = {"state": "off", "count": 0}
        self._thread = threading.Thread(target=self._work, name="Windows reminders", daemon=True)
        self._thread.start()

    @classmethod
    def for_store(cls, store) -> ReminderWorker | None:
        appdata = os.environ.get("APPDATA", "").strip()
        if os.name != "nt" or not appdata:
            return None
        default = Path(appdata) / "GaoSeries" / "Research" / "AcademicAchievementManager"
        if store.library.root.resolve() != default.resolve() or not _registered_identity():
            return None
        return cls(store.library.root, WindowsReminderTransport(), store.clock)

    def submit(self, store) -> None:
        change = _snapshot(store)
        with self._condition:
            if self._closed:
                return
            if change in (self._pending, self._running):
                if self._pending != change and self._running == change:
                    self._pending = None
                return
            if self._running is None and self._pending is None and self._scheduled == change:
                return
            self._pending = change
            self._status = {"state": "pending", "count": 0}
            self._condition.notify()

    def status(self) -> dict:
        with self._condition:
            return dict(self._status)

    def close(self) -> None:
        with self._condition:
            self._closed = True
            self._condition.notify()
        self._thread.join()

    def _work(self) -> None:
        while True:
            with self._condition:
                while self._pending is None and not self._closed:
                    if self._wake_at is None:
                        self._condition.wait()
                        continue
                    remaining = (self._wake_at - self._clock()).total_seconds()
                    if remaining <= 0:
                        self._pending = self._scheduled
                        break
                    # Recompute on resume or clock changes without a busy loop.
                    self._condition.wait(min(remaining, 60))
                if self._pending is None:
                    return
                change = self._pending
                self._pending = None
                self._running = change
            try:
                result, next_check = self._synchronize(change)
            except (OSError, ValueError, TypeError, subprocess.SubprocessError):
                result, next_check = {"state": "error", "count": 0}, self._clock() + timedelta(minutes=1)
            with self._condition:
                self._running = None
                self._scheduled = change
                self._wake_at = next_check
                if self._pending is None:
                    self._status = result

    def _synchronize(self, change: ReminderInput) -> tuple[dict, datetime | None]:
        if not change.enabled and not self._path.exists():
            return {"state": "off", "count": 0}, None
        now = self._clock()
        prior = _read_state(self._path)
        records, state, removed = plan_reminders(change, now, prior)
        due, waiting = [], []
        for row in records:
            moment = parse_iso(row["due"])
            if moment <= now:
                due.append(row)
            else:
                waiting.append(moment)
        # Create a marker before delivery so disabling can clear history after
        # an interrupted first send. Existing Windows history also deduplicates it.
        if change.enabled and not self._path.exists():
            self._save({})
        result = self._transport.synchronize(change.enabled, due, removed)
        if not change.enabled:
            self._path.unlink(missing_ok=True)
            return {"state": "off", "count": 0}, None
        if result["state"] == "active":
            for row in due:
                state[row["ref"]]["sent"] = True
            self._save(state)
            return {"state": "active", "count": len(waiting)}, min(waiting, default=None)
        return {"state": "blocked", "count": 0}, now + timedelta(minutes=1)

    def _save(self, state: dict) -> None:
        atomic_write(self._path, (json.dumps({"schema": 1, "papers": state}, separators=(",", ":")) + "\n").encode("ascii"))
