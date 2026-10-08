#!/usr/bin/env python3
"""Private, read-only upgrade snapshots and post-install data verification.

Examples (quit the app before snapshotting):
  python3 scripts/upgrade_data.py snapshot --version 4.09
  python3 scripts/upgrade_data.py verify-live /path/returned/as/backup

Snapshots keep the original data paths. This tool never restores, migrates,
installs, or deletes live data. A failed check always has a nonzero exit status.
Only aggregate counts are printed; file names, IDs, settings and credentials
remain in the private snapshot. Fixture paths can be supplied for local tests.
"""

from __future__ import annotations

import argparse
import copy
from contextlib import closing
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
from urllib.parse import quote


FORMAT = 1
APP_ID = "com.academic-achievement.manager"
DOMAINS = (APP_ID, APP_ID + ".Research")
COLLECTIONS = (
    "papers", "portals", "existingWorks", "projects", "certificates",
    "fundingRecords", "documentFolders", "managedDocuments", "trashItems",
)
REWARD_FIELDS = (
    "coins", "buildingTickets", "decorationTickets", "unlockedPlotIDs",
    "inventory", "placements", "terrainInventory", "plotTerrains",
    "rewardedWorkIDs", "rewardedCertificateIDs", "buildingPity",
    "decorationPity", "lastCoinCollectionAt", "highestZIndex",
)
REWARD_SETS = ("unlockedPlotIDs", "rewardedWorkIDs", "rewardedCertificateIDs")
ATTACHMENT_DIRS = ("Attachments", "CertificateAttachments", "ManagedDocuments", "TrashStorage")
LIBRARY_REL = "AcademicAchievementManager/library.json"
MANIFEST = "manifest.json"
REQUIRED_STRINGS = {
    "papers": "key sourceID site url manuscriptID title journal status checkedAt statusSince statusSinceSource",
    "portals": "id publisherID publisherName kind name url identity createdAt",
    "existingWorks": "id title type venue authors completedAt identifier url notes createdAt updatedAt",
    "projects": "id title content createdAt updatedAt",
    "certificates": "id name eventDate createdAt updatedAt",
    "fundingRecords": "id name receivingAccount createdAt updatedAt",
    "documentFolders": "id libraryKind name createdAt updatedAt",
    "managedDocuments": "id folderID originalName displayName storedName fileExtension uploadedAt updatedAt",
    "trashItems": "id kind title deletedAt",
}
DATE_KEYS = {"createdAt", "updatedAt", "checkedAt", "statusSince", "completedAt",
             "eventDate", "uploadedAt", "deletedAt", "addedAt", "startDate", "endDate"}


class SafetyError(Exception):
    """The message is a public, non-sensitive error code."""


def fail(code: str) -> None:
    raise SafetyError(code)


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":"),
                      ensure_ascii=False, allow_nan=False).encode("utf-8")


def parse_json(data: bytes) -> object:
    def unique_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                fail("duplicate_json_key")
            result[key] = value
        return result

    def reject_constant(_):
        fail("nonfinite_json_number")

    try:
        return json.loads(data, object_pairs_hook=unique_keys, parse_constant=reject_constant)
    except (ValueError, UnicodeError):
        fail("invalid_json")


def file_hash(path: Path) -> str:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    checksum = hashlib.sha256()
    with os.fdopen(os.open(path, flags), "rb") as source:
        before = os.fstat(source.fileno())
        if not stat.S_ISREG(before.st_mode):
            fail("unsupported_file_type")
        while data := source.read(1024 * 1024):
            checksum.update(data)
        after = os.fstat(source.fileno())
        if (before.st_size, before.st_mtime_ns, before.st_ino) != (
                after.st_size, after.st_mtime_ns, after.st_ino):
            fail("source_changed_during_read")
    return checksum.hexdigest()


def read_file(path: Path) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags), "rb") as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            fail("unsupported_file_type")
        return source.read()


def inventory(root: Path) -> dict:
    if root.is_symlink() or not root.is_dir():
        fail("required_data_root_missing_or_unsafe")
    files, directories = {}, []
    def traversal_error(error):
        raise error

    for current, names, filenames in os.walk(root, followlinks=False, onerror=traversal_error):
        names.sort()
        filenames.sort()
        base = Path(current)
        for name in names:
            entry = base / name
            if entry.is_symlink() or not entry.is_dir():
                fail("unsafe_directory_entry")
            directories.append(entry.relative_to(root).as_posix())
        for name in filenames:
            entry = base / name
            metadata = entry.lstat()
            if not stat.S_ISREG(metadata.st_mode):
                fail("unsupported_file_type")
            relative = entry.relative_to(root).as_posix()
            files[relative] = {"sha256": file_hash(entry), "bytes": metadata.st_size}
    return {"files": files, "directories": sorted(directories)}


def private_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    with os.fdopen(os.open(path, flags, 0o600), "wb") as target:
        target.write(data)
        target.flush()
        os.fsync(target.fileno())


def mirror(source: Path, target: Path, listing: dict) -> None:
    target.mkdir(mode=0o700, parents=True)
    for relative in listing["directories"]:
        (target / relative).mkdir(mode=0o700, parents=True, exist_ok=True)
    for relative, expected in listing["files"].items():
        original, destination = source / relative, target / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
        with os.fdopen(os.open(original, flags), "rb") as reader:
            if not stat.S_ISREG(os.fstat(reader.fileno()).st_mode):
                fail("unsupported_file_type")
            with destination.open("xb") as writer:
                os.chmod(destination, 0o600)
                shutil.copyfileobj(reader, writer, 1024 * 1024)
                writer.flush()
                os.fsync(writer.fileno())
        if file_hash(destination) != expected["sha256"]:
            fail("snapshot_copy_checksum_failed")


def component(value: object) -> str:
    if not isinstance(value, str) or not value or value in (".", ".."):
        fail("invalid_attachment_reference")
    if "/" in value or "\\" in value or "\0" in value:
        fail("unsafe_attachment_reference")
    return value


def required_strings(record: dict, keys: str) -> None:
    for key in keys.split():
        value = record.get(key)
        if not isinstance(value, str):
            fail("business_record_field_missing_or_invalid")
        if key in DATE_KEYS:
            try:
                parsed = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
                if parsed.tzinfo is None:
                    fail("business_date_invalid")
            except ValueError:
                fail("business_date_invalid")


def typed_list(record: dict, key: str, element_type: type) -> list:
    values = record.get(key)
    if not isinstance(values, list) or any(type(value) is not element_type for value in values):
        fail("business_collection_field_invalid")
    return values


def validate_record(record: dict, collection: str) -> None:
    required_strings(record, REQUIRED_STRINGS[collection])
    if collection == "papers":
        if any(type(record.get(key)) is not bool for key in ("changed", "hidden")):
            fail("business_boolean_invalid")
        for event in typed_list(record, "history", dict):
            required_strings(event, "status checkedAt")
    elif collection in ("existingWorks", "certificates"):
        for attachment in typed_list(record, "attachments", dict):
            required_strings(attachment, "id originalName storedName kind addedAt")
        if collection == "certificates":
            typed_list(record, "tags", str)
        elif record["type"] not in ("journalArticle", "conferencePaper", "graduationThesis", "book",
                                    "bookChapter", "patent", "dataset", "software", "other"):
            fail("business_enum_invalid")
    elif collection == "projects":
        for step in typed_list(record, "steps", dict):
            required_strings(step, "id title details startDate endDate")
            if type(step.get("isCompleted")) is not bool:
                fail("business_boolean_invalid")
    elif collection == "fundingRecords":
        typed_list(record, "months", int)
        if type(record.get("year")) is not int or type(record.get("amount")) not in (int, float):
            fail("business_number_invalid")
    elif collection == "managedDocuments":
        typed_list(record, "tags", str)
        if type(record.get("byteCount")) is not int:
            fail("business_number_invalid")
    elif collection == "documentFolders":
        if record["libraryKind"] not in ("experimentData", "summaryReports", "importantLiterature"):
            fail("business_enum_invalid")
    elif collection == "trashItems":
        typed_list(record, "documents", dict)
        if record["kind"] not in ("submission", "work", "project", "documentFolder", "document",
                                  "certificate", "funding", "workAttachment", "certificateAttachment"):
            fail("business_enum_invalid")


def required_attachment(root: Path, relative: Path, hashes: dict) -> None:
    name = relative.as_posix()
    if name not in hashes:
        fail("referenced_attachment_missing")
    if not (root / relative).is_file():
        fail("referenced_attachment_unreadable")


def validate_attachments(root: Path, library: dict, listing: dict) -> dict:
    base = Path("AcademicAchievementManager")
    files = listing["files"]
    folders = {item["id"]: item for item in library["documentFolders"]}
    for collection, directory in (("existingWorks", "Attachments"),
                                   ("certificates", "CertificateAttachments")):
        for record in library[collection]:
            attachments = record.get("attachments")
            if not isinstance(attachments, list):
                fail("invalid_attachment_collection")
            for attachment in attachments:
                if not isinstance(attachment, dict):
                    fail("invalid_attachment_reference")
                relative = base / directory / component(record["id"]) / component(attachment.get("storedName"))
                required_attachment(root, relative, files)
    for document in library["managedDocuments"]:
        folder = folders.get(document.get("folderID"))
        if not folder or folder.get("libraryKind") not in (
                "experimentData", "summaryReports", "importantLiterature"):
            fail("document_folder_reference_missing")
        relative = (base / "ManagedDocuments" / component(folder["libraryKind"])
                    / component(folder["id"]) / component(document.get("storedName")))
        required_attachment(root, relative, files)
    # Recycled attachments must also remain readable; metadata-only deletions
    # legitimately have no payload. Empty work/folder payloads are optional.
    for item in library["trashItems"]:
        payload = base / "TrashStorage" / component(item["id"]) / "payload"
        kind = item.get("kind")
        if kind in ("work", "certificate"):
            record = item.get(kind)
            if not isinstance(record, dict) or not isinstance(record.get("attachments"), list):
                fail("invalid_trash_record")
            for attachment in record["attachments"]:
                required_attachment(root, payload / component(attachment.get("storedName")), files)
        elif kind == "documentFolder":
            documents = item.get("documents", [])
            if not isinstance(documents, list):
                fail("invalid_trash_record")
            for document in documents:
                required_attachment(root, payload / component(document.get("storedName")), files)
        elif kind in ("document", "workAttachment", "certificateAttachment"):
            required_attachment(root, payload, files)
    prefixes = tuple((base / directory).as_posix() + "/" for directory in ATTACHMENT_DIRS)
    attachments = {name: value for name, value in files.items() if name.startswith(prefixes)}
    return {"count": len(attachments), "bytes": sum(v["bytes"] for v in attachments.values()),
            "sha256": digest(canonical(attachments))}


def library_summary(root: Path, listing: dict) -> dict:
    if LIBRARY_REL not in listing["files"]:
        fail("existing_library_missing")
    library = parse_json(read_file(root / LIBRARY_REL))
    if not isinstance(library, dict) or type(library.get("version")) is not int or library["version"] < 1:
        fail("invalid_library_schema")
    collections = {}
    for name in COLLECTIONS:
        records = library.get(name)
        if not isinstance(records, list):
            fail("business_collection_missing_or_invalid")
        ids = []
        for record in records:
            id_key = "key" if name == "papers" else "id"
            if not isinstance(record, dict) or not isinstance(record.get(id_key), str) or not record[id_key]:
                fail("business_record_id_invalid")
            validate_record(record, name)
            ids.append(record[id_key])
        if len(set(ids)) != len(ids):
            fail("duplicate_business_record_id")
        collections[name] = {"count": len(records), "ids_sha256": digest(canonical(sorted(ids))),
                             "records_sha256": digest(canonical(records))}
    reward = library.get("rewardCity")
    if not isinstance(reward, dict) or any(key not in reward for key in REWARD_FIELDS):
        fail("reward_city_state_missing_or_invalid")
    normalized = copy.deepcopy(library)
    for key in REWARD_SETS:
        values = reward[key]
        if not isinstance(values, list) or any(not isinstance(v, str) for v in values) or len(set(values)) != len(values):
            fail("reward_city_set_invalid")
        normalized["rewardCity"][key] = sorted(values)
    for key in ("inventory", "placements", "terrainInventory"):
        if not isinstance(reward[key], list):
            fail("reward_city_collection_invalid")
    if not isinstance(reward["plotTerrains"], dict):
        fail("reward_city_terrain_invalid")
    for key in ("coins", "buildingTickets", "decorationTickets", "buildingPity",
                "decorationPity", "highestZIndex"):
        if type(reward[key]) not in (int, float):
            fail("reward_city_number_invalid")
    return {"schema": library["version"], "collections": collections,
            "reward_city_fields": len(reward), "reward_city_sha256": digest(canonical(normalized["rewardCity"])),
            "library_sha256": digest(canonical(normalized)),
            "attachments": validate_attachments(root, library, listing)}


def statistics_digest(path: Path) -> str:
    value = parse_json(read_file(path))
    if not isinstance(value, dict) or "updatedAt" not in value:
        fail("invalid_widget_statistics")
    value.pop("updatedAt")
    return digest(canonical(value))


def parse_preferences(data: bytes) -> dict:
    try:
        value = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException):
        fail("invalid_preferences")
    if not isinstance(value, dict):
        fail("invalid_preferences")
    return value


def preference_digest(value: dict, *, allowed_change: bool = False) -> str:
    value = copy.deepcopy(value)
    if allowed_change:
        value.pop("lastWidgetLayoutRelease", None)
    return digest(plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True))


def preferences(preferences_dir: Path | None) -> dict:
    result = {}
    for domain in DOMAINS:
        if preferences_dir is not None:
            path = preferences_dir / (domain + ".plist")
            if not path.exists() and not path.is_symlink():
                result[domain] = None
                continue
            result[domain] = parse_preferences(read_file(path))
        else:
            command = subprocess.run(["/usr/bin/defaults", "export", domain, "-"],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     env={**os.environ, "LC_ALL": "C"}, check=False)
            if command.returncode:
                # Absence is explicit. Authorization, I/O and export errors
                # never become an empty preferences dictionary.
                error = command.stderr.decode("utf-8", "replace")
                if "does not exist" in error:
                    result[domain] = None
                    continue
                fail("preferences_export_failed")
            result[domain] = parse_preferences(command.stdout)
    return result


def sqlite_snapshots(roots: dict[str, Path], listings: dict, target: Path) -> dict:
    databases = {}
    for namespace, root in roots.items():
        files = listings[namespace]["files"]
        for relative, metadata in files.items():
            source = root / relative
            with source.open("rb") as handle:
                sqlite_header = handle.read(16) == b"SQLite format 3\0"
            if not sqlite_header:
                if source.suffix.lower() in (".sqlite", ".sqlite3"):
                    fail("invalid_sqlite_header")
                continue
            # Preserve raw db/WAL/SHM in the payload. Open a disposable copy so
            # SQLite can update its shared-memory files without touching live
            # data or changing the byte-for-byte archive.
            with tempfile.TemporaryDirectory(prefix="gao-research-sqlite-") as scratch:
                scratch_path = Path(scratch)
                copied = scratch_path / "database"
                shutil.copyfile(source, copied)
                for suffix in ("-wal", "-shm", "-journal"):
                    sidecar = relative + suffix
                    if sidecar in files:
                        shutil.copyfile(root / sidecar, Path(str(copied) + suffix))
                uri = "file:" + quote(str(copied), safe="/") + "?mode=ro"
                destination = target / namespace / relative
                destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                with closing(sqlite3.connect(uri, uri=True, timeout=10)) as reader:
                    if reader.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                        fail("sqlite_source_integrity_failed")
                    with closing(sqlite3.connect(destination)) as writer:
                        reader.backup(writer)
                        writer.commit()
                os.chmod(destination, 0o600)
                check_sqlite(destination)
                databases[namespace + "/" + relative] = {
                    "sha256": file_hash(destination), "bytes": destination.stat().st_size,
                }
    return databases


def check_sqlite(path: Path) -> None:
    uri = "file:" + quote(str(path), safe="/") + "?mode=ro&immutable=1"
    with closing(sqlite3.connect(uri, uri=True, timeout=10)) as connection:
        if connection.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
            fail("sqlite_snapshot_integrity_failed")


def resolve_roots(args, saved: dict | None = None) -> dict[str, Path]:
    home = Path.home()
    defaults = {"research": home / "Library/Application Support/GaoSeries/Research",
                "app_group": home / "Library/Group Containers/5G96498KGJ.com.academic-achievement.manager"}
    result = {}
    for name, argument in (("research", args.research_root), ("app_group", args.group_root)):
        selected = argument or (saved[name] if saved else defaults[name])
        path = Path(selected).expanduser().absolute()
        if path.is_symlink() or path.resolve() != path:
            # Resolve the OS /var -> /private/var alias for fixture paths, but
            # refuse symlinks within actual data trees through inventory().
            if path.is_symlink():
                fail("unsafe_data_root_symlink")
            path = path.resolve()
        result[name] = path
    if result["research"] == result["app_group"] or any(
            a in b.parents for a in result.values() for b in result.values() if a != b):
        fail("overlapping_data_roots")
    return result


def public_counts(listings: dict, summary: dict, sqlite_count: int) -> dict:
    return {"files": sum(len(v["files"]) for v in listings.values()),
            "bytes": sum(f["bytes"] for v in listings.values() for f in v["files"].values()),
            "business_records": {k: v["count"] for k, v in summary["collections"].items()},
            "attachments": summary["attachments"]["count"], "sqlite_databases": sqlite_count,
            "reward_city_fields": summary["reward_city_fields"]}


def verify_backup(backup: Path) -> dict:
    if backup.is_symlink() or not backup.is_dir():
        fail("invalid_backup_directory")
    data = read_file(backup / MANIFEST)
    if read_file(backup / "manifest.sha256").decode("ascii").strip() != digest(data):
        fail("backup_manifest_checksum_failed")
    manifest = parse_json(data)
    if not isinstance(manifest, dict) or manifest.get("format") != FORMAT or manifest.get("app_id") != APP_ID:
        fail("unsupported_backup_format")
    actual = inventory(backup)
    actual["files"].pop(MANIFEST, None)
    actual["files"].pop("manifest.sha256", None)
    if actual != manifest["archive"]:
        fail("backup_file_checksum_failed")
    roots = {name: backup / "payload" / name for name in manifest["roots"]}
    listings = {name: inventory(root) for name, root in roots.items()}
    if listings != manifest["sources"]:
        fail("backup_source_inventory_failed")
    if library_summary(roots["research"], listings["research"]) != manifest["library"]:
        fail("backup_business_integrity_failed")
    for key in manifest["sqlite"]:
        check_sqlite(backup / "sqlite-consistent" / key)
    return manifest


def snapshot(args) -> dict:
    if not re.fullmatch(r"V?[0-9]+(?:\.[0-9]+){1,2}", args.version):
        fail("invalid_version")
    roots = resolve_roots(args)
    preferences_dir = Path(args.preferences_dir).expanduser().resolve() if args.preferences_dir else None
    backup_root = Path(args.backup_root).expanduser().resolve() if args.backup_root else (
        Path.home() / "Library/Application Support/GaoSeries/UpgradeBackups/Research")
    project = Path(__file__).resolve().parents[1]
    if backup_root == project or project in backup_root.parents:
        fail("backup_must_not_enter_source_repository")
    if any(backup_root == root or root in backup_root.parents or backup_root in root.parents for root in roots.values()):
        fail("backup_must_not_overlap_live_data")
    listings = {name: inventory(root) for name, root in roots.items()}
    summary = library_summary(roots["research"], listings["research"])
    if "statistics.json" in listings["app_group"]["files"]:
        statistics_digest(roots["app_group"] / "statistics.json")
    settings = preferences(preferences_dir)
    backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_root, 0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    final = backup_root / (stamp + "-V" + args.version.lstrip("V"))
    stage = Path(tempfile.mkdtemp(prefix=".incomplete-", dir=backup_root))
    try:
        copied_roots = {}
        for name, root in roots.items():
            copied_roots[name] = stage / "payload" / name
            mirror(root, copied_roots[name], listings[name])
        for domain, value in settings.items():
            if value is not None:
                private_write(stage / "preferences" / (domain + ".plist"),
                              plistlib.dumps(value, fmt=plistlib.FMT_BINARY, sort_keys=True))
        databases = sqlite_snapshots(copied_roots, listings, stage / "sqlite-consistent")
        if {name: inventory(root) for name, root in roots.items()} != listings:
            fail("live_data_changed_during_snapshot")
        if preferences(preferences_dir) != settings:
            fail("preferences_changed_during_snapshot")
        manifest = {"format": FORMAT, "app_id": APP_ID, "target_version": args.version,
                    "created_at": stamp, "roots": {name: str(root) for name, root in roots.items()},
                    "preferences_dir": str(preferences_dir) if preferences_dir else None,
                    "preferences_present": {domain: value is not None for domain, value in settings.items()},
                    "sources": listings, "library": summary, "sqlite": databases,
                    "archive": inventory(stage)}
        encoded = canonical(manifest)
        private_write(stage / MANIFEST, encoded)
        private_write(stage / "manifest.sha256", (digest(encoded) + "\n").encode("ascii"))
        verify_backup(stage)
        os.rename(stage, final)
        return {"ok": True, "command": "snapshot", "backup": str(final),
                "counts": public_counts(listings, summary, len(databases))}
    finally:
        if stage.exists():
            shutil.rmtree(stage)


def verify_live(args) -> dict:
    backup = Path(args.backup).expanduser().resolve()
    manifest = verify_backup(backup)
    roots = resolve_roots(args, manifest["roots"])
    preferences_dir = (Path(args.preferences_dir).expanduser().resolve() if args.preferences_dir else
                       Path(manifest["preferences_dir"]) if manifest.get("preferences_dir") else None)
    listings = {name: inventory(root) for name, root in roots.items()}
    summary = library_summary(roots["research"], listings["research"])
    differences = {"business_collections": 0, "record_ids_or_counts": 0, "reward_city": 0,
                   "library_other_fields": 0, "attachments": 0, "files_added": 0,
                   "files_missing": 0, "files_changed": 0, "directories": 0,
                   "preferences": 0, "widget_statistics": 0}
    previous = manifest["library"]
    for name in COLLECTIONS:
        old, new = previous["collections"][name], summary["collections"][name]
        differences["business_collections"] += int(old["records_sha256"] != new["records_sha256"])
        differences["record_ids_or_counts"] += int((old["count"], old["ids_sha256"]) != (new["count"], new["ids_sha256"]))
    differences["reward_city"] = int(previous["reward_city_sha256"] != summary["reward_city_sha256"])
    differences["library_other_fields"] = int(previous["library_sha256"] != summary["library_sha256"])
    differences["attachments"] = int(previous["attachments"] != summary["attachments"])
    for name, root in roots.items():
        old, new = manifest["sources"][name], listings[name]
        old_files, new_files = old["files"], new["files"]
        differences["files_added"] += len(new_files.keys() - old_files.keys())
        differences["files_missing"] += len(old_files.keys() - new_files.keys())
        differences["directories"] += len(set(old["directories"]) ^ set(new["directories"]))
        for relative in old_files.keys() & new_files.keys():
            if name == "research" and relative == LIBRARY_REL:
                continue  # JSON order/whitespace are immaterial; full values checked above.
            if name == "app_group" and relative == "statistics.json":
                differences["widget_statistics"] += int(statistics_digest(backup / "payload" / name / relative) != statistics_digest(root / relative))
                continue
            path = Path(relative)
            if path.suffix == ".plist" and path.stem in DOMAINS:
                before = parse_preferences(read_file(backup / "payload" / name / relative))
                after = parse_preferences(read_file(root / relative))
                differences["preferences"] += int(preference_digest(before, allowed_change=True) != preference_digest(after, allowed_change=True))
                continue
            differences["files_changed"] += int(old_files[relative] != new_files[relative])
    settings = preferences(preferences_dir)
    for domain, current in settings.items():
        present = manifest["preferences_present"][domain]
        original = parse_preferences(read_file(backup / "preferences" / (domain + ".plist"))) if present else None
        # A previously absent domain may acquire only the release marker.
        before = preference_digest(original or {}, allowed_change=True)
        after = preference_digest(current or {}, allowed_change=True)
        differences["preferences"] += int(before != after)
    # This checks current SQLite + WAL in disposable copies, and preserves all
    # existing live paths. Physical journal changes are still reported above.
    with tempfile.TemporaryDirectory(prefix="gao-research-verify-") as scratch:
        databases = sqlite_snapshots(roots, listings, Path(scratch) / "sqlite")
    if {name: inventory(root) for name, root in roots.items()} != listings:
        fail("live_data_changed_during_verification")
    if preferences(preferences_dir) != settings:
        fail("preferences_changed_during_verification")
    return {"ok": not any(differences.values()), "command": "verify-live",
            "counts": public_counts(listings, summary, len(databases)), "difference_counts": differences}


def main() -> int:
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    make = commands.add_parser("snapshot", help="Validate and privately snapshot existing data")
    make.add_argument("--version", required=True, help="Target app version, e.g. 4.09")
    make.add_argument("--backup-root", help="Private backup parent; never a source repository")
    check = commands.add_parser("verify-live", help="Verify snapshot and compare all live data")
    check.add_argument("backup", help="Snapshot directory returned by snapshot")
    for command in (make, check):
        command.add_argument("--research-root", help="Override data root for fixtures")
        command.add_argument("--group-root", help="Override App Group root for fixtures")
        command.add_argument("--preferences-dir", help="Read fixture plists instead of macOS defaults")
    args = parser.parse_args()
    try:
        result = snapshot(args) if args.command == "snapshot" else verify_live(args)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0 if result["ok"] else 1
    except SafetyError as error:
        print(json.dumps({"ok": False, "command": args.command, "error": str(error)}), file=sys.stderr)
        return 1
    except (OSError, sqlite3.Error, ValueError, KeyError, TypeError) as error:
        # Do not leak user filenames, business content, or credentials through
        # exception text into shell logs or eventual GitHub descriptions.
        print(json.dumps({"ok": False, "command": args.command,
                          "error": "read_or_integrity_check_failed", "error_type": type(error).__name__}), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
