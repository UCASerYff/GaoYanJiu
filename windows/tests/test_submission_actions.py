from datetime import date, datetime, timedelta

import pytest

from gaoyanjiu.errors import AppError
from gaoyanjiu.library import Library
from gaoyanjiu.store import ResearchStore
from gaoyanjiu.timeutil import format_iso
from gaoyanjiu.web import Api
from gaoyanjiu.workspace import merge_portal_capture


@pytest.fixture
def actions(tmp_path):
    library = Library(tmp_path).open()
    library.create_empty()
    local_now = [datetime(2026, 5, 28, 0, 5).astimezone()]
    return ResearchStore(library, clock=lambda: local_now[0]), local_now


def manuscript(store, title, status="审稿中", key=None):
    return store.save_paper(key, title, "隔离期刊", "", status, "2026-05-02", "", "")


def test_next_actions_use_local_dates_and_survive_library_reload(actions):
    store, now = actions
    today = now[0].date()
    expected = {"overdue": [], "today": [], "upcoming": [], "later": []}
    for title, offset, group in (("迟二", -1, "overdue"), ("迟一", -4, "overdue"),
                                 ("今日", 0, "today"), ("明日", 1, "upcoming"),
                                 ("七天内", 7, "upcoming"), ("七天以后", 8, "later"), ("远期", 60, "later")):
        key = manuscript(store, title)
        assert "nextAction" not in store.list_papers()[-1]
        action = store.change_submission_action(key, "save", None, "整理审稿意见", (today + timedelta(days=offset)).isoformat())
        expected[group].append((key, action["dueDate"]))
    expected["overdue"].reverse()

    reopened = ResearchStore(Library(store.library.root).open(), clock=store.clock)
    assert reopened.library.data["version"] == 32
    groups = reopened.submission_actions()
    assert {group: [(row["key"], row["nextAction"]["dueDate"]) for row in rows]
            for group, rows in groups.items()} == expected
    now[0] += timedelta(days=1)
    assert reopened.submission_actions()["today"][0]["key"] == expected["upcoming"][0][0]
    assert reopened.submission_actions()["overdue"][-1]["key"] == expected["today"][0][0]
    assert reopened.submission_actions()["upcoming"][-1]["key"] == expected["later"][0][0]


def test_completion_is_explicit_and_keeps_status_history_reminders_and_extensions(actions):
    store, now = actions
    key = manuscript(store, "旧稿件")
    due = now[0].date().isoformat()
    reminder_keys = [paper["key"] for paper in store.follow_ups()]
    action = store.change_submission_action(key, "save", None, "提交修订稿", due)
    assert [paper["key"] for paper in store.follow_ups()] == reminder_keys
    manuscript(store, "更正后的旧稿件", "大修", key)
    assert store.paper_detail(key)["nextAction"] == action
    status_history = store.paper_detail(key)["history"].copy()

    completed = store.change_submission_action(key, "complete", action["revision"])
    assert completed["completedAt"] == format_iso(now[0])
    assert store.paper_detail(key)["history"] == status_history
    assert store.paper_detail(key)["status"] == "大修"
    assert not store.submission_actions()["today"]
    with pytest.raises(AppError) as stale:
        store.change_submission_action(key, "complete", action["revision"])
    assert stale.value.status == 409

    reopened = store.change_submission_action(key, "reopen", completed["revision"])
    assert reopened["completedAt"] is None
    store.set_hidden(key, True)
    assert not store.submission_actions()["today"]
    assert store.paper_detail(key)["nextAction"] == reopened
    store.set_hidden(key, False)
    assert store.submission_actions()["today"][0]["key"] == key
    manuscript(store, "更正后的旧稿件", "已接受", key)
    assert store.paper_detail(key)["nextAction"]["completedAt"] is None
    assert not store.submission_actions()["today"]
    with pytest.raises(AppError) as terminal:
        store.change_submission_action(key, "save", reopened["revision"], "另一个行动", due)
    assert terminal.value.code == "invalid_field"
    explicitly_finished = store.change_submission_action(key, "complete", reopened["revision"])
    assert explicitly_finished["completedAt"] == format_iso(now[0])
    assert store.paper_detail(key)["status"] == "已接受"


def test_portal_capture_keeps_an_assigned_action_and_rejects_invalid_updates(actions):
    store, now = actions
    url = "https://portal.example.invalid/manuscripts"
    portal = store.save_portal({"name": "测试投稿门户", "url": url})
    payload = {"url": url, "checkedAt": format_iso(now[0]),
               "papers": [{"id": "TEST-5", "title": "审核导入的论文", "status": "已投稿"}]}
    assert merge_portal_capture(store, portal, payload)["imported"] == 1
    key = store.list_papers()[0]["key"]
    stamp = date(2028, 2, 29).isoformat()
    for invalid in ("2027-02-29", "2028-2-29", "2028-02-29T00:00:00Z", "20280229", None):
        with pytest.raises(AppError) as bad:
            store.change_submission_action(key, "save", None, "核对附件", invalid)
        assert bad.value.code == "invalid_field"
    for invalid_text in (" ", "长" * 241, 7):
        with pytest.raises(AppError):
            store.change_submission_action(key, "save", None, invalid_text, stamp)
    action = store.change_submission_action(key, "save", None, "核对附件", stamp)
    now[0] += timedelta(minutes=5)
    payload["checkedAt"] = format_iso(now[0])
    payload["papers"][0]["status"] = "审稿中"
    assert merge_portal_capture(store, portal, payload)["changed"] == 1
    assert store.paper_detail(key)["nextAction"] == action
    assert store.paper_detail(key)["status"] == "审稿中"


def test_submission_action_api_scope_detail_replace_and_remove(actions):
    store, now = actions
    key = manuscript(store, "行动入口稿件")
    due = now[0].date().isoformat()
    api = Api(store)
    path = "/api/papers/next-action"
    status, initial = api.call("POST", path, {}, {"key": key, "operation": "save", "text": "送审", "dueDate": due})
    assert status == 200
    status, scoped = api.call("GET", "/api/papers", {"scope": "hidden", "q": "no-match"}, None)
    assert status == 200 and scoped["papers"] == []
    assert scoped["nextActions"]["today"][0]["nextAction"] == initial["nextAction"]
    status, details = api.call("GET", "/api/papers/detail", {"key": key}, None)
    assert status == 200 and details["paper"]["nextAction"] == initial["nextAction"]

    done = store.change_submission_action(key, "complete", initial["nextAction"]["revision"])
    status, replacement = api.call("POST", path, {}, {"key": key, "operation": "save", "revision": done["revision"],
                                                     "text": "提交补充材料", "dueDate": due})
    assert status == 200 and replacement["nextAction"]["completedAt"] is None
    status, removed = api.call("POST", path, {}, {"key": key, "operation": "remove",
                                                 "revision": replacement["nextAction"]["revision"]})
    assert status == 200 and removed["nextAction"] is None
    assert not store.submission_actions()["today"]
