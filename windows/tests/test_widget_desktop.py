from datetime import datetime, timezone

import pytest

from gaoyanjiu import widget
from gaoyanjiu.errors import AppError
from gaoyanjiu.library import Library
from gaoyanjiu.session import link_destination, url_for
from gaoyanjiu.store import ResearchStore
from gaoyanjiu.widget import SNAPSHOT_NAME, paper_rows, read_snapshot


def test_desktop_links_only_select_known_local_views():
    assert link_destination("GAOYANJIU://SUBMISSIONS/") == ("submissions", "")
    assert link_destination("gaoyanjiu://works") == ("works", "")
    assert link_destination("gaoyanjiu://achievement-widget") == ("", "works")
    assert url_for("http://127.0.0.1:8080/", "works") == "http://127.0.0.1:8080/#works"
    for unsafe in ("gaoyanjiu://works/other", "gaoyanjiu://works?path=secret", "https://works",
                   "gaoyanjiu://works#submissions", "gaoyanjiu://funding", "gaoyanjiu://submissions:80"):
        with pytest.raises(AppError):
            link_destination(unsafe)


def test_widget_keeps_statistics_time_on_refresh_and_language_change(tmp_path):
    library = Library(tmp_path).open()
    library.create_empty()
    current = [datetime(2026, 11, 28, tzinfo=timezone.utc)]
    store = ResearchStore(library, clock=lambda: current[0])
    store.save_paper(None, "Synthetic", "", "", "Under Review", "2026-10-10", "", "")
    store.save_work({"title": "Synthetic patent", "type": "patent", "patentType": "design", "authorPosition": "first"})
    first = read_snapshot(tmp_path / SNAPSHOT_NAME)
    assert first["schema"] == 1 and first["activeSubmissions"] == 1
    assert first["papers"][0]["id"] == store.list_papers("all")[0]["key"]
    assert first["categories"][0]["id"] == "patent-design"
    assert first["authors"][0]["count"] == 1
    current[0] = datetime(2026, 11, 29, tzinfo=timezone.utc)
    store.update_settings("dark", "en", 12)
    second = read_snapshot(tmp_path / SNAPSHOT_NAME)
    assert second["language"] == "en" and second["appearance"] == "dark"
    assert second["categories"][0]["label"] != first["categories"][0]["label"]
    assert second["statisticsRevision"] == first["statisticsRevision"]
    assert second["dataChangedAt"] == first["dataChangedAt"] and second["generatedAt"] != first["generatedAt"]
    assert paper_rows(second, current[0])[0]["days"] == paper_rows(first, datetime(2026, 11, 28, tzinfo=timezone.utc))[0]["days"] + 1
    key = store.list_papers("all")[0]["key"]
    store.set_hidden(key, True)
    hidden = read_snapshot(tmp_path / SNAPSHOT_NAME)
    assert hidden["papers"] == [] and hidden["statisticsRevision"] != first["statisticsRevision"]


def test_widget_retains_legacy_counts_and_rejects_invalid_details(tmp_path):
    snapshot = tmp_path / SNAPSHOT_NAME
    snapshot.write_text('{"schema": 1, "platform": "windows", "works": 4}', encoding="utf-8")
    assert read_snapshot(snapshot)["works"] == 4
    snapshot.write_text('{"schema": 1, "platform": "windows", "statisticsRevision": "invalid"}', encoding="utf-8")
    assert read_snapshot(snapshot) == {}


def test_widget_quit_signals_an_existing_profile_and_allows_reopen(tmp_path, monkeypatch):
    monkeypatch.delenv(widget._WIDGET_QUIT_ENV, raising=False)
    profile = tmp_path / "research"
    other = tmp_path / "other"
    profile.mkdir()
    other.mkdir()
    marker, baseline = widget._quit_registration(profile)
    independent = widget._quit_registration(other)

    class PendingTkWindow:
        callback = None
        destroyed = False

        def after(self, delay, callback):
            assert 0 <= delay <= 400
            self.callback = callback

        def destroy(self):
            self.destroyed = True

    first_window = PendingTkWindow()
    widget._watch_quit(first_window, marker, baseline)
    first_window.callback()
    assert not first_window.destroyed and baseline is None and not marker.exists()

    widget.signal_widget_shutdown(profile / ".." / "research", "first-session-secret")
    first_window.callback()
    assert first_window.destroyed
    assert not widget._quit_changed(*independent)
    first_signal = marker.read_text("ascii")
    assert len(first_signal) == 64 and "first-session-secret" not in first_signal

    reopened = widget._quit_registration(profile)
    stamp = marker.stat().st_mtime_ns
    widget.signal_widget_shutdown(profile, "first-session-secret")
    assert marker.stat().st_mtime_ns == stamp
    assert not widget._quit_changed(*reopened)
    widget.signal_widget_shutdown(profile, "next-session-secret")
    assert widget._quit_changed(*reopened)
    assert marker.read_text("ascii") != first_signal


def test_widget_open_racing_with_quit_uses_the_launched_profile_baseline(tmp_path, monkeypatch):
    tk = pytest.importorskip("tkinter")
    profile = tmp_path / "research"
    other = tmp_path / "other"
    profile.mkdir()
    other.mkdir()
    starts = []
    monkeypatch.setattr(widget.subprocess, "Popen", lambda command, **kwargs: starts.append((command, kwargs)))
    widget.launch_widget(profile, "works")
    command, options = starts[0]
    assert command[-4:] == ["--data-dir", str(profile.resolve()), "--widget", "works"]
    inherited = options["env"][widget._WIDGET_QUIT_ENV]
    widget.signal_widget_shutdown(profile, "workbench-session")
    widget.signal_widget_shutdown(other, "workbench-session")

    monkeypatch.setenv(widget._WIDGET_QUIT_ENV, inherited)
    assert not widget._quit_changed(*widget._quit_registration(other))

    monkeypatch.setenv(widget._WIDGET_QUIT_ENV, inherited)
    monkeypatch.setattr(tk, "Tk", lambda: pytest.fail("A pending widget should exit before creating its window"))
    assert widget.show_widget(profile, "works") is None
    assert widget._WIDGET_QUIT_ENV not in widget.os.environ


def test_widget_quit_ignores_invalid_markers(tmp_path):
    marker = widget._quit_marker(tmp_path)
    for invalid in (b"0" * 65, b"x" * 64, b"\x80" * 64):
        marker.write_bytes(invalid)
        assert not widget._quit_changed(marker, None)


def test_widget_quit_rejects_symlinks(tmp_path):
    marker = widget._quit_marker(tmp_path)
    outside = tmp_path / "outside"
    outside.write_bytes(b"0" * 64)
    try:
        marker.symlink_to(outside)
    except (OSError, NotImplementedError):
        pytest.skip("The environment does not permit file symlinks")
    assert not widget._quit_changed(marker, None)
    with pytest.raises(OSError, match="Invalid widget quit marker"):
        widget.signal_widget_shutdown(tmp_path, "workbench-session")
    assert marker.is_symlink() and outside.read_bytes() == b"0" * 64


def test_widget_inspection_never_registers_for_quit(tmp_path, monkeypatch):
    tk = pytest.importorskip("tkinter")
    widget.signal_widget_shutdown(tmp_path, "workbench-session")
    marker = widget._quit_marker(tmp_path)
    expected = marker.read_bytes()

    class InspectionReachedTk(Exception):
        pass

    def inspect_tk():
        raise InspectionReachedTk

    monkeypatch.setattr(tk, "Tk", inspect_tk)
    monkeypatch.setattr(widget, "_quit_registration", lambda *_: pytest.fail("Inspection registered for quit"))
    with pytest.raises(InspectionReachedTk):
        widget.show_widget(tmp_path, "submissions", inspect=True)
    assert marker.read_bytes() == expected
