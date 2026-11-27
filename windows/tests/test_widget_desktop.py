from datetime import datetime, timezone

import pytest

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
