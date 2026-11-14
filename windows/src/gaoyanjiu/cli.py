from __future__ import annotations

import argparse
import json
import os
import sys
import webbrowser
from pathlib import Path

from gaoyanjiu import __build__, __version__
from gaoyanjiu.errors import AppError
from gaoyanjiu.i18n import translate
from gaoyanjiu.library import Library, default_data_dir
from gaoyanjiu.store import ResearchStore, inspect_summary


def emit(text: str) -> None:
    stream = sys.stdout
    if stream is None:
        return
    stream.write(text)
    if not text.endswith("\n"):
        stream.write("\n")
    stream.flush()


def fail(message: str) -> int:
    stream = sys.stderr
    if stream is not None:
        stream.write(message + "\n")
        stream.flush()
    return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="gaoyanjiu", description="搞研究 Windows 版")
    parser.add_argument("--data-dir", default="")
    parser.add_argument("--create-empty", action="store_true")
    parser.add_argument("--inspect", action="store_true")
    parser.add_argument("--widget-snapshot", action="store_true")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--version", action="store_true")
    args = parser.parse_args(argv)
    if args.version:
        emit(f"{__version__}+{__build__}")
        return 0
    root = Path(args.data_dir).expanduser() if args.data_dir else default_data_dir()
    if args.data_dir:
        os.environ["GAO_RESEARCH_DATA_DIR"] = str(root)
    try:
        library = Library(root).open()
        store = ResearchStore(library)
        if args.create_empty:
            library.create_empty()
        if args.inspect:
            if library.data is None:
                return fail(translate(store.language(), library.message_code or "not_ready"))
            emit(json.dumps(inspect_summary(library.data), ensure_ascii=False, indent=2))
            return 0
        if args.widget_snapshot:
            emit(json.dumps(store.write_snapshot(), ensure_ascii=False, indent=2))
            return 0
        if args.create_empty and not args.serve and not args.widget_snapshot and not args.inspect:
            return 0
        if library.status == "ready":
            store.purge_expired()
        lock = root / "server.json"
        if lock.exists():
            try:
                info = json.loads(lock.read_text(encoding="utf-8"))
                os.kill(int(info["pid"]), 0)
            except (OSError, ValueError, KeyError, json.JSONDecodeError):
                info = None
            else:
                if not args.no_browser and info.get("url"):
                    webbrowser.open(info["url"])
                return 0
        from gaoyanjiu.web import serve

        serve(store, port=args.port, open_browser=not args.no_browser, lock_path=lock)
        return 0
    except AppError as error:
        language = "zh-Hans"
        return fail(error.detail or translate(language, error.code))
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
