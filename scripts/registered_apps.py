#!/usr/bin/env python3
"""Emit NUL-separated, missing LaunchServices host paths for one exact app ID.

Read-only: consumes a captured `lsregister -dump` and never edits registrations.
Existing bundles, broken symlinks, extensions and ambiguous records are excluded.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import sys


def missing_hosts(dump: str, identifier: str) -> list[str]:
    result = []
    for record in re.split(r"(?m)^\s*bundle id:", dump)[1:]:
        # Other LS tables follow the bundle table; stop at their record boundary.
        record = re.split(r"(?m)^-{20,}\s*$", record, maxsplit=1)[0]
        identifiers = re.findall(r"(?m)^\s*identifier:\s*(\S+)\s*$", record)
        paths = re.findall(r"(?m)^\s*path:\s*(.+?)\s*$", record)
        if identifiers != [identifier] or len(paths) != 1:
            continue
        candidate = re.sub(r"\s+\(0x[0-9a-fA-F]+\)$", "", paths[0])
        path = Path(candidate)
        if (not path.is_absolute() or path.suffix != ".app" or
                any(part in (".", "..") for part in candidate.split("/")) or
                "\0" in candidate):
            continue
        # lexists preserves a broken symlink for manual review. stat failures
        # must not be interpreted as a missing host (permission or I/O error).
        try:
            os.lstat(path)
        except FileNotFoundError:
            try:
                path.parent.stat()
            except FileNotFoundError:
                # Missing parent trees are normal for removed integrated apps.
                pass
            except OSError:
                continue
            if candidate not in result:
                result.append(candidate)
        except OSError:
            continue
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dump", type=Path)
    parser.add_argument("identifier")
    args = parser.parse_args()
    for path in missing_hosts(args.dump.read_text(encoding="utf-8"), args.identifier):
        sys.stdout.buffer.write(os.fsencode(path) + b"\0")


if __name__ == "__main__":
    main()
