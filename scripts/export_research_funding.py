#!/usr/bin/env python3
"""Export a pinned, frozen Research library for the Savings v1 importer.

No default live paths and no live writes. Root must quit/freeze source writers,
back up the whole library and attachments, and provide a verified snapshot.
This tool does not certify the freeze, import into Savings, or switch authority.
"""
import argparse
import datetime
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import uuid

FIELDS = {'id', 'name', 'amount', 'year', 'months', 'receivingAccount', 'createdAt', 'updatedAt'}
MAX_LIBRARY = 128 * 1024 * 1024

class ExportError(ValueError):
    pass

def require(value, reason):
    if not value:
        raise ExportError(reason)

def sha(raw):
    return hashlib.sha256(raw).hexdigest()

def signature(s):
    return (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_gid, s.st_nlink,
            s.st_size, s.st_mtime_ns, s.st_ctime_ns)

def no_links(path):
    path = Path(path)
    require(path.is_absolute(), 'explicit_absolute_path_required')
    for part in [path] + list(path.parents):
        s = part.lstat()
        require(not stat.S_ISLNK(s.st_mode), 'symlink_path_refused')
    return path

def read_pinned(path, expected):
    path = no_links(path)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid() and
                0 < before.st_size <= MAX_LIBRARY, 'source_not_owned_regular_bounded_library')
        chunks, total = [], 0
        while True:
            chunk = os.read(fd, min(1024 * 1024, MAX_LIBRARY + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            require(total <= MAX_LIBRARY, 'source_grew_beyond_limit')
        raw = b''.join(chunks)
        require(signature(before) == signature(os.fstat(fd)) == signature(path.lstat()), 'source_changed_during_read')
        require(sha(raw) == expected, 'source_revision_mismatch')
        return raw, signature(before)
    finally:
        os.close(fd)

def strict_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, 'duplicate_json_key')
        result[key] = value
    return result

def valid_date(value):
    require(isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})', value), 'invalid_iso8601_date')
    try:
        parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
    except ValueError as exc:
        raise ExportError('invalid_iso8601_date') from exc
    require(parsed.tzinfo is not None, 'missing_date_timezone')

def record(value):
    require(isinstance(value, dict) and set(value) == FIELDS, 'funding_fields_missing_or_unknown')
    require(isinstance(value['id'], str) and 0 < len(value['id']) <= 1024 and '\x00' not in value['id'], 'invalid_funding_id')
    require(isinstance(value['name'], str) and value['name'].strip() and isinstance(value['receivingAccount'], str), 'invalid_funding_text')
    amount = value['amount']
    require(type(amount) in (int, float) and math.isfinite(amount) and amount >= 0, 'invalid_funding_amount')
    require(type(value['year']) is int and 1 <= value['year'] <= 9999, 'invalid_funding_year')
    months = value['months']
    require(isinstance(months, list) and all(type(x) is int and 1 <= x <= 12 for x in months) and len(months) == len(set(months)), 'invalid_funding_months')
    valid_date(value['createdAt']); valid_date(value['updatedAt'])
    return value['id']

def projection(raw, expected, exported_at=None):
    require(sha(raw) == expected, 'source_revision_mismatch')
    try:
        library = json.loads(raw, object_pairs_hook=strict_object,
                             parse_constant=lambda _: (_ for _ in ()).throw(ExportError('nonfinite_json_number')))
    except (ValueError, UnicodeDecodeError) as exc:
        raise ExportError('invalid_source_json:' + str(exc)) from exc
    require(isinstance(library, dict) and type(library.get('version')) is int and library['version'] == 32, 'unsupported_source_schema')
    collections = ['papers', 'portals', 'existingWorks', 'projects', 'certificates',
                   'fundingRecords', 'documentFolders', 'managedDocuments', 'trashItems']
    require(all(isinstance(library.get(key), list) for key in collections) and
            isinstance(library.get('rewardCity'), dict), 'incomplete_current_library_structure')
    active = library['fundingRecords']; ids = [record(value) for value in active]
    require(len(ids) == len(set(ids)), 'duplicate_active_funding_id')
    trashed, trash_ids, funding_ids = [], set(), set(ids)
    for item in library['trashItems']:
        require(isinstance(item, dict) and isinstance(item.get('kind'), str), 'malformed_trash_item')
        require(isinstance(item.get('id'), str) and item['id'] and item['id'] not in trash_ids, 'invalid_or_duplicate_trash_id')
        trash_ids.add(item['id'])
        if item['kind'] != 'funding':
            require(item.get('funding') is None, 'funding_under_nonfunding_trash_kind')
            continue
        require(isinstance(item.get('title'), str), 'invalid_funding_trash_title')
        valid_date(item.get('deletedAt'))
        fid = record(item.get('funding'))
        require(fid not in funding_ids, 'duplicate_active_or_deleted_funding_id')
        funding_ids.add(fid)
        # Schema32 declares no funding payload. Unexpected relationships need
        # a new reviewed contract, never silently empty attachments/projects.
        for field in ['paper', 'work', 'project', 'documentFolder', 'certificate', 'attachment', 'parentID']:
            require(item.get(field) is None, 'unexpected_funding_relationship')
        require(item.get('documents', []) == [], 'unexpected_funding_documents')
        trashed.append(item)
    return {'format': 'gaoseries.research-funding', 'schemaVersion': 1,
            'sourceBundleID': 'com.academic-achievement.manager', 'sourceLibrarySchema': 32,
            'sourceRevision': expected,
            'exportedAt': exported_at or datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z'),
            'fundingRecords': active, 'trashItems': trashed, 'relatedProjects': [], 'attachments': []}

def export(library_path, expected, output):
    require(isinstance(expected, str) and re.fullmatch('[0-9a-f]{64}', expected), 'expected_revision_required')
    library_path, output = Path(library_path), Path(output)
    require(output.name == 'research-funding-v1.json', 'canonical_export_filename_required')
    parent = no_links(output.parent)
    info = parent.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid() and stat.S_IMODE(info.st_mode) == 0o700, 'private_0700_export_directory_required')
    require(not output.exists() and not output.is_symlink(), 'existing_output_refused')
    raw, identity = read_pinned(library_path, expected)
    value = projection(raw, expected)
    encoded = (json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(',', ':')) + '\n').encode()
    temporary = parent / ('.funding-export-' + uuid.uuid4().hex + '.partial.noindex')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, 'wb') as stream:
            stream.write(encoded); stream.flush(); os.fsync(stream.fileno())
        require(temporary.read_bytes() == encoded, 'staged_export_mismatch')
        reread, fresh_identity = read_pinned(library_path, expected)
        require(reread == raw and fresh_identity == identity, 'source_changed_before_export_commit')
        require(signature(parent.lstat())[:5] == signature(info)[:5], 'export_parent_changed')
        # Exclusive hardlink commits a completed regular file without replacing
        # any destination created since the original absence check.
        os.link(temporary, output, follow_symlinks=False)
        temporary.unlink()
        directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        require(output.read_bytes() == encoded, 'committed_export_mismatch')
    finally:
        if temporary.exists():
            temporary.unlink()
    return {'ok': True, 'sourceRevision': expected, 'output': str(output),
            'exportSHA256': sha(encoded), 'activeFunding': len(value['fundingRecords']),
            'fundingTrash': len(value['trashItems']), 'sourceWritten': False,
            'targetImported': False, 'authoritySwitched': False}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--library', type=Path, required=True, help='Verified frozen full-library snapshot, never a default live path')
    parser.add_argument('--expected-library-sha', required=True)
    parser.add_argument('--output', type=Path, required=True, help='New research-funding-v1.json under an owned0700 directory')
    args = parser.parse_args()
    print(json.dumps(export(args.library, args.expected_library_sha, args.output), ensure_ascii=False))

if __name__ == '__main__':
    try:
        main()
    except Exception as exc:
        print(json.dumps({'ok': False, 'error': str(exc), 'sourceWritten': False, 'authoritySwitched': False}), file=__import__('sys').stderr)
        raise SystemExit(1)
