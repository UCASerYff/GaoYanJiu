from __future__ import annotations

import argparse
import json
import os
import sys
from contextlib import suppress
from pathlib import Path

from gaoyanjiu import __build__, __version__
from gaoyanjiu.errors import AppError
from gaoyanjiu.i18n import translate
from gaoyanjiu.library import Library, default_data_dir
from gaoyanjiu.session import app_session, link_destination, open_application, publish_in_session, receive_in_session, url_for
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
    parser.add_argument("--widget", choices=("submissions", "works"))
    parser.add_argument("--gaoaction", metavar="PATH")
    parser.add_argument("--capabilities", action="store_true")
    parser.add_argument("--clear-reminders", action="store_true", help=argparse.SUPPRESS)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--version", action="store_true")
    parser.add_argument("url", nargs="?")
    args = parser.parse_args(argv)
    if args.version:
        emit(f"{__version__}+{__build__}")
        return 0
    try:
        return run(args)
    except AppError as error:
        language = "zh-Hans"
        return fail(error.detail or translate(language, error.code))
    except KeyboardInterrupt:
        return 0


def run(args) -> int:
    if args.clear_reminders:
        from gaoyanjiu.notifications import clear_system_reminders

        clear_system_reminders()
        return 0
    if args.capabilities:
        from gaoyanjiu.exchange import research_capabilities

        emit(json.dumps(research_capabilities(), ensure_ascii=False))
        return 0
    root = (Path(args.data_dir).expanduser() if args.data_dir else default_data_dir()).resolve()
    if args.data_dir:
        os.environ["GAO_RESEARCH_DATA_DIR"] = str(root)
    destination, linked_widget = link_destination(args.url) if args.url else ("", "")
    widget = args.widget or linked_widget
    if widget:
        from gaoyanjiu.widget import show_widget

        details = show_widget(root, widget, inspect=args.inspect)
        if details is not None:
            emit(json.dumps(details))
        return 0
    if args.inspect and not args.create_empty:
        return inspect_library(Library(root).open())
    incoming = Path(args.gaoaction).expanduser().resolve() if args.gaoaction else None
    if incoming:
        destination = "exchange"
    with app_session(root) as existing:
        if existing:
            origin, port, token = existing
            if incoming:
                receive_in_session(port, token, incoming)
            if args.create_empty:
                raise AppError("existing_data", 409)
            if args.widget_snapshot:
                from gaoyanjiu.widget import SNAPSHOT_NAME, read_snapshot

                snapshot = publish_in_session(port, token) or read_snapshot(root / SNAPSHOT_NAME)
                if not snapshot:
                    raise AppError("not_ready", 409)
                emit_snapshot(snapshot)
            elif not args.no_browser:
                open_application(url_for(origin, destination))
            return 0
        library = Library(root).open()
        store = ResearchStore(library)
        if args.create_empty:
            library.create_empty()
        if args.inspect:
            return inspect_library(library)
        if args.widget_snapshot:
            emit_snapshot(store.write_snapshot())
            return 0
        if library.writable:
            if not args.create_empty:
                store.purge_expired()
            with suppress(AppError, OSError):
                store.write_snapshot()
        if args.create_empty and not args.serve and not incoming:
            return 0
        if incoming:
            from gaoyanjiu.exchange import ResearchExchange

            ResearchExchange(store).receive(incoming)
        from gaoyanjiu.web import serve

        if not args.no_browser:
            from gaoyanjiu.notifications import ReminderWorker

            store.reminders = ReminderWorker.for_store(store)
            if store.reminders:
                store.reminders.submit(store)
        serve(store, port=args.port, open_browser=not args.no_browser, lock_path=root / "server.json",
              destination=destination)
        return 0


def inspect_library(library: Library) -> int:
    if library.data is None:
        return fail(translate(ResearchStore(library).language(), library.message_code or "not_ready"))
    emit(json.dumps(inspect_summary(library.data), ensure_ascii=False, indent=2))
    return 0


def emit_snapshot(snapshot: dict) -> None:
    fields = ("schema", "platform", "generatedAt", "activeSubmissions", "changedSubmissions", "works",
              "certificates", "documents", "trash", "followUps")
    emit(json.dumps({key: snapshot[key] for key in fields if key in snapshot}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    raise SystemExit(main())
