from __future__ import annotations

import json
from pathlib import Path

from gaoyanjiu import SCHEMA_VERSION
from gaoyanjiu.errors import AppError
from gaoyanjiu.fsutil import atomic_write
from gaoyanjiu.timeutil import format_iso, utcnow

COLLECTIONS = (
    "papers",
    "portals",
    "existingWorks",
    "projects",
    "certificates",
    "fundingRecords",
    "documentFolders",
    "managedDocuments",
    "trashItems",
)
EVIDENCE_DIRECTORIES = (
    "Attachments",
    "CertificateAttachments",
    "ManagedDocuments",
    "TrashStorage",
    "indexes",
)
EVIDENCE_FILES = ("library.json", "widget-snapshot.json")
IGNORED_FILES = {"settings.json", "server.json", "windows-startup.log"}
MAX_LIBRARY_BYTES = 128 * 1024 * 1024


def default_data_dir() -> Path:
    import os

    override = os.environ.get("GAO_RESEARCH_DATA_DIR", "").strip()
    if override:
        return Path(override)
    appdata = os.environ.get("APPDATA", "").strip()
    if appdata:
        return Path(appdata) / "GaoSeries" / "Research" / "AcademicAchievementManager"
    return Path.home() / ".local" / "share" / "GaoSeries" / "Research" / "AcademicAchievementManager"


def default_reward_city(now=None) -> dict:
    moment = format_iso(now or utcnow())
    plots = [f"{row}:{column}" for row in range(2, 5) for column in range(2, 5)]
    return {
        "coins": 0,
        "buildingTickets": 0,
        "decorationTickets": 0,
        "unlockedPlotIDs": plots,
        "inventory": [],
        "placements": [],
        "terrainInventory": [],
        "plotTerrains": {},
        "rewardedWorkIDs": [],
        "rewardedCertificateIDs": [],
        "buildingPity": 0,
        "decorationPity": 0,
        "lastCoinCollectionAt": moment,
        "highestZIndex": 0,
    }


def empty_library() -> dict:
    data = {"version": SCHEMA_VERSION}
    for name in COLLECTIONS:
        data[name] = []
    data["rewardCity"] = default_reward_city()
    return data


def has_user_evidence(root: Path) -> bool:
    if not root.exists():
        return False
    for name in EVIDENCE_FILES:
        if (root / name).exists():
            return True
    for name in EVIDENCE_DIRECTORIES:
        if (root / name).exists():
            return True
    secrets = root / "secrets"
    if secrets.exists():
        return True
    return False


def _normalize(data: dict) -> tuple[dict, int]:
    version = data.get("version", 1)
    if not isinstance(version, int) or isinstance(version, bool):
        raise AppError("unreadable")
    for name in COLLECTIONS:
        if name not in data:
            data[name] = []
        elif not isinstance(data[name], list):
            raise AppError("unreadable")
    if "rewardCity" not in data or not isinstance(data.get("rewardCity"), dict):
        if version == SCHEMA_VERSION:
            data["rewardCity"] = default_reward_city()
    return data, version


class Library:
    def __init__(self, root: Path):
        self.root = Path(root)
        self.path = self.root / "library.json"
        self.data: dict | None = None
        self.snapshot: bytes | None = None
        self.version = 0
        self.status = "blocked"
        self.message_code = "unreadable"
        self.writable = False

    def open(self) -> Library:
        self.root.mkdir(parents=True, exist_ok=True)
        if not self.path.exists():
            if has_user_evidence(self.root):
                self.status = "blocked"
                self.message_code = "existing_data"
                self.writable = False
                self.data = None
                return self
            self.status = "needs_create"
            self.message_code = "needs_confirmation"
            self.writable = False
            self.data = None
            return self
        try:
            raw = self.path.read_bytes()
        except OSError as exc:
            raise AppError("unreadable") from exc
        if len(raw) > MAX_LIBRARY_BYTES:
            self.status = "blocked"
            self.message_code = "unreadable"
            return self
        try:
            parsed = json.loads(raw.decode("utf-8"))
        except (UnicodeError, json.JSONDecodeError):
            self.status = "blocked"
            self.message_code = "unreadable"
            self.data = None
            self.writable = False
            return self
        if not isinstance(parsed, dict):
            self.status = "blocked"
            self.message_code = "unreadable"
            return self
        try:
            data, version = _normalize(parsed)
        except AppError:
            self.status = "blocked"
            self.message_code = "unreadable"
            self.data = None
            return self
        self.data = data
        self.version = version
        self.snapshot = raw
        self.status = "ready"
        if version == SCHEMA_VERSION:
            self.writable = True
            self.message_code = ""
        else:
            self.writable = False
            self.message_code = "future_version" if version > SCHEMA_VERSION else "read_only_schema"
        return self

    def create_empty(self) -> None:
        if self.path.exists() or has_user_evidence(self.root):
            raise AppError("existing_data", 409)
        if self.status != "needs_create":
            raise AppError("needs_confirmation", 409)
        self.root.mkdir(parents=True, exist_ok=True)
        self.data = empty_library()
        self.version = SCHEMA_VERSION
        self._write(creating=True)
        self.status = "ready"
        self.writable = True
        self.message_code = ""

    def save(self) -> None:
        if self.data is None or self.status != "ready":
            raise AppError("read_required", 409)
        if not self.writable or self.version != SCHEMA_VERSION or self.data.get("version") != SCHEMA_VERSION:
            raise AppError("read_only_schema" if self.version != SCHEMA_VERSION else "read_required", 409)
        if not self.path.exists():
            raise AppError("missing_library", 409)
        try:
            current = self.path.read_bytes()
        except OSError as exc:
            raise AppError("unreadable") from exc
        if current != self.snapshot:
            raise AppError("changed_since_read", 409)
        self._write(creating=False)

    def _write(self, creating: bool) -> None:
        payload = json.dumps(self.data, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        atomic_write(self.path, payload)
        self.snapshot = self.path.read_bytes()
        self.writable = True
        self.status = "ready"

    def require_writable(self) -> dict:
        if self.status == "needs_create":
            raise AppError("needs_confirmation", 409)
        if self.data is None or self.status != "ready":
            raise AppError(self.message_code or "not_ready", 409)
        if not self.writable:
            raise AppError(self.message_code or "read_only_schema", 409)
        return self.data
