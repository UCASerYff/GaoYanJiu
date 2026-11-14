from __future__ import annotations

import base64
import json
import threading
import uuid
import zipfile
from datetime import datetime, timedelta, timezone
from http.client import HTTPConnection
from pathlib import Path

import pytest

from gaoyanjiu import BUNDLE_ID
from gaoyanjiu.analytics import chart_height, stack_cards, work_categories
from gaoyanjiu.errors import AppError
from gaoyanjiu.gaoaction import validate_import_manifest
from gaoyanjiu.library import Library
from gaoyanjiu.metrics import parse_crossref, parse_easyscholar, summary_items
from gaoyanjiu.navigation import resolve_navigation, route_widget_target
from gaoyanjiu.status import is_terminal
from gaoyanjiu.store import ResearchStore, inspect_summary
from gaoyanjiu.web import make_server, parse_multipart

NOW = datetime(2026, 11, 14, 12, 0, tzinfo=timezone.utc)


def library(tmp_path: Path) -> Library:
    opened = Library(tmp_path).open()
    opened.create_empty()
    return opened


def store(tmp_path: Path, clock=None) -> ResearchStore:
    return ResearchStore(library(tmp_path), clock=clock or (lambda: NOW))


def test_terminal_status_matches_mac_keywords():
    assert is_terminal("Accepted")
    assert is_terminal("paper published online")
    assert is_terminal("Rejected after review")
    assert is_terminal("withdrawn")
    assert is_terminal("declined")
    assert is_terminal("cancelled")
    assert is_terminal("已接收")
    assert is_terminal("录用")
    assert not is_terminal("Under Review")
    assert not is_terminal("外审")


def test_navigation_and_chart_layout():
    assert resolve_navigation("projects", "changed") == ("all", "all")
    assert resolve_navigation("changed", "all") == ("all", "changed")
    assert resolve_navigation("hidden", "all") == ("all", "hidden")
    assert resolve_navigation("existing", "all") == ("existing", "all")
    assert route_widget_target("works", "all", "changed") == ("existing", "changed")
    assert chart_height(0) == 215
    assert chart_height(8) == 275
    assert stack_cards(859)
    assert not stack_cards(860)
    rows = work_categories(
        [
            {"type": "journalArticle"},
            {"type": "patent", "patentType": "invention"},
            {"type": "patent", "patentType": None},
        ]
    )
    assert [row["id"] for row in rows] == ["journalArticle", "patent-invention", "patent-unspecified"]


def test_create_requires_confirmation_and_refuses_existing_evidence(tmp_path: Path):
    opened = Library(tmp_path).open()
    assert opened.status == "needs_create"
    assert not (tmp_path / "library.json").exists()
    opened.create_empty()
    assert opened.writable
    assert json.loads((tmp_path / "library.json").read_text(encoding="utf-8"))["version"] == 32

    other = tmp_path / "other"
    (other / "Attachments").mkdir(parents=True)
    blocked = Library(other).open()
    assert blocked.status == "blocked"
    with pytest.raises(AppError) as raised:
        blocked.create_empty()
    assert raised.value.code == "existing_data"
    assert not (other / "library.json").exists()


def test_future_corrupt_and_legacy_libraries_are_not_overwritten(tmp_path: Path):
    future = tmp_path / "future"
    future.mkdir()
    payload = json.dumps({"version": 33, "papers": [{"title": "不能覆盖"}]}, ensure_ascii=False).encode() + b"\n"
    (future / "library.json").write_bytes(payload)
    opened = Library(future).open()
    assert opened.message_code == "future_version"
    with pytest.raises(AppError):
        ResearchStore(opened, clock=lambda: NOW).save_paper(None, "新论文", "", "", "已投稿", "2026-11-01", "", "")
    assert (future / "library.json").read_bytes() == payload

    legacy = tmp_path / "legacy"
    legacy.mkdir()
    old = json.dumps({"version": 31, "papers": []}).encode()
    (legacy / "library.json").write_bytes(old)
    legacy_library = Library(legacy).open()
    assert legacy_library.message_code == "read_only_schema"
    with pytest.raises(AppError) as raised:
        ResearchStore(legacy_library, clock=lambda: NOW).save_paper(None, "新论文", "", "", "已投稿", "2026-11-01", "", "")
    assert raised.value.code == "read_only_schema"
    assert (legacy / "library.json").read_bytes() == old

    broken = tmp_path / "broken"
    broken.mkdir()
    (broken / "library.json").write_bytes(b"{")
    assert Library(broken).open().status == "blocked"
    assert (broken / "library.json").read_bytes() == b"{"


def test_changed_since_read_and_unknown_keys(tmp_path: Path):
    opened = library(tmp_path)
    opened.data["macOnly"] = {"kept": True}
    opened.data["projects"] = [{"id": "p1", "title": "历史项目", "steps": []}]
    opened.data["fundingRecords"] = [{"id": "f1", "name": "历史经费", "amount": 3}]
    opened.save()
    raw = opened.path.read_bytes()
    opened.path.write_bytes(raw + b" ")
    with pytest.raises(AppError) as raised:
        ResearchStore(opened, clock=lambda: NOW).save_paper(None, "论文", "", "", "已投稿", "2026-11-01", "", "")
    assert raised.value.code == "changed_since_read"
    assert opened.path.read_bytes() == raw + b" "

    reloaded = Library(tmp_path).open()
    research = ResearchStore(reloaded, clock=lambda: NOW)
    reloaded.data["papers"].append({"key": "manual:old", "title": "旧题", "status": "已投稿", "futureField": "stay", "history": []})
    reloaded.save()
    research.save_paper("manual:old", "新题", "Nature", "M-1", "外审", "2026-11-02", "https://example.test", "备注")
    paper = reloaded.data["papers"][0]
    assert paper["title"] == "新题"
    assert paper["futureField"] == "stay"
    assert paper["previousStatus"] == "已投稿"
    assert paper["changed"] is False
    assert len(paper["history"]) == 1
    again = Library(tmp_path).open()
    assert again.data["macOnly"] == {"kept": True}
    assert again.data["projects"][0]["title"] == "历史项目"
    assert again.data["fundingRecords"][0]["amount"] == 3
    summary = json.dumps(inspect_summary(again.data), ensure_ascii=False)
    assert "历史项目" not in summary
    assert "新题" not in summary
    assert summary.count("papers") >= 1


def test_papers_works_rewards_and_followups(tmp_path: Path):
    research = store(tmp_path)
    key = research.save_paper(None, "第一篇", "Nature", "", "外审", "2026-10-01", "", "", flag_changed=True)
    assert research.list_papers("changed")[0]["key"] == key
    assert research.list_papers("all")[0]["manuscriptID"] == "未填写"
    work_id = research.save_work(
        {
            "title": "期刊成果",
            "type": "journalArticle",
            "venue": "Cell",
            "authors": "非凡",
            "completedAt": "2026-01-02",
            "authorPosition": "first",
        }
    )
    thesis_id = research.save_work({"title": "毕业论文", "type": "graduationThesis", "completedAt": "2026-01-03"})
    research.save_work({"id": work_id, "title": "期刊成果修订", "type": "journalArticle", "completedAt": "2026-01-02"})
    certificate_id = research.save_certificate({"name": "优秀论文", "eventDate": "2025-06-01", "tags": ["获奖"]})
    research.save_certificate({"id": certificate_id, "name": "优秀论文", "eventDate": "2025-06-01", "tags": ["获奖"]})
    city = research.library.data["rewardCity"]
    assert city["buildingTickets"] == 15
    assert city["decorationTickets"] == 1
    assert city["rewardedWorkIDs"] == [work_id, thesis_id]
    assert len(research.follow_ups()) == 1
    research.library.data["rewardCity"]["buildingTickets"] = 1
    research.library.data["rewardCity"]["buildingPity"] = 79
    drawn = research.reward_draw("building-campus", 1)
    assert drawn[0]["rarity"] == "legendary"
    assert research.library.data["rewardCity"]["buildingPity"] == 0
    assert research.library.data["rewardCity"]["buildingTickets"] == 0
    with pytest.raises(AppError) as raised:
        research.reward_draw("building-campus", 1)
    assert raised.value.code == "insufficient_tickets"


def test_city_coins_plots_and_placement(tmp_path: Path):
    research = store(tmp_path)
    city = research.library.data["rewardCity"]
    city["placements"] = [
        {
            "id": "placed",
            "catalogID": "building-campus-001",
            "x": 0,
            "y": 0,
            "zIndex": 1,
            "placedAt": "2026-11-01T00:00:00Z",
            "anchorRow": 2,
            "anchorColumn": 2,
            "rotationQuarterTurns": 0,
        }
    ]
    city["inventory"] = [{"catalogID": "building-campus-001", "count": 2}]
    city["lastCoinCollectionAt"] = "2026-11-10T04:00:00Z"
    assert research.reward_collect() == 3.6
    city["coins"] = 100
    research.reward_purchase("1:2")
    assert "1:2" in city["unlockedPlotIDs"]
    assert city["coins"] == 0
    with pytest.raises(AppError):
        research.reward_purchase("0:0")
    research.reward_place("building-campus-001", "2:3")
    with pytest.raises(AppError) as raised:
        research.reward_place("building-campus-001", "2:3")
    assert raised.value.code == "plot_occupied"


def test_documents_search_trash_and_secrets(tmp_path: Path):
    research = store(tmp_path)
    folder_id = research.create_folder("experimentData", "批次一")
    source = tmp_path / "notes.txt"
    source.write_text("独特检索词 alpha", encoding="utf-8")
    docx = tmp_path / "report.docx"
    with zipfile.ZipFile(docx, "w") as archive:
        archive.writestr(
            "word/document.xml",
            '<document xmlns:w="urn:test"><w:t>实验记录正文</w:t></document>',
        )
    first = research.import_path(folder_id, source)
    second = research.import_path(folder_id, source)
    assert first["imported"] == 1
    assert second["existing"] == 1
    assert len(research.library.data["managedDocuments"]) == 1
    office = research.import_path(folder_id, docx)
    assert "实验记录正文" in office["document"]["contentText"]
    assert research.search("独特检索词")["documents"]
    link = tmp_path / "link.txt"
    try:
        link.symlink_to(source)
    except OSError:
        link = None
    if link is not None:
        with pytest.raises(AppError) as raised:
            research.import_path(folder_id, link)
        assert raised.value.code == "unsafe_file"
    work_id = research.save_work({"title": "带附件", "type": "software", "completedAt": "2026-02-02"})
    attachment = research.add_attachment("work", work_id, source)
    stored = research.library.root / "Attachments" / work_id / attachment["storedName"]
    assert stored.read_text(encoding="utf-8") == "独特检索词 alpha"
    (stored.parent / "extra.bin").write_bytes(b"extra")
    with pytest.raises(AppError):
        research.trash_work(work_id)
    assert any(item["id"] == work_id for item in research.library.data["existingWorks"])
    (stored.parent / "extra.bin").unlink()
    trash_id = research.trash_work(work_id)
    assert not stored.exists()
    restored = research.library.root / "TrashStorage" / trash_id / attachment["storedName"]
    assert restored.read_text(encoding="utf-8") == "独特检索词 alpha"
    research.restore(trash_id)
    assert stored.read_text(encoding="utf-8") == "独特检索词 alpha"
    research.set_easyscholar_key("top-secret-key")
    research.save_portal(
        {
            "publisherID": "nature",
            "name": "Nature",
            "url": "https://submission.nature.com/",
            "identity": "author@example.com",
            "password": "portal-password",
        }
    )
    raw = research.library.path.read_text(encoding="utf-8")
    assert "top-secret-key" not in raw
    assert "portal-password" not in raw
    assert research.portal_has_password(research.library.data["portals"][0]["id"])


def test_trash_retention_conflict_and_history_readonly(tmp_path: Path):
    current = {"now": NOW}
    research = store(tmp_path, clock=lambda: current["now"])
    key = research.save_paper(None, "将删除", "", "", "已投稿", "2026-11-01", "", "")
    current["now"] = NOW - timedelta(days=31)
    trash_id = research.trash_paper(key)
    current["now"] = NOW
    assert research.purge_expired() == 1
    assert research.library.data["trashItems"] == []
    kept = research.save_paper(None, "仍保留", "", "", "已投稿", "2026-11-01", "", "")
    current["now"] = NOW - timedelta(days=3)
    kept_trash = research.trash_paper(kept)
    current["now"] = NOW
    assert research.purge_expired() == 0
    research.library.data["papers"].append(dict(research.library.data["trashItems"][0]["paper"]))
    research.library.save()
    with pytest.raises(AppError) as raised:
        research.restore(kept_trash)
    assert raised.value.code == "conflict"
    assert research.history()["projects"] == []


def _package(root: Path, now: datetime, payload: bytes, name: str = "note.txt", **overrides) -> Path:
    package = root / "incoming.gaoaction"
    target = package / "payload"
    target.mkdir(parents=True)
    (target / name).write_bytes(payload)
    created = now - timedelta(seconds=10)
    expires = created + timedelta(seconds=60)
    item = {
        "id": "item-1",
        "relativePath": f"payload/{name}",
        "uti": "public.plain-text",
        "byteCount": len(payload),
        "sha256": __import__("hashlib").sha256(payload).hexdigest(),
    }
    manifest = {
        "schemaVersion": 1,
        "kind": "request",
        "requestID": str(uuid.uuid4()),
        "sourceBundleID": "com.example.sender",
        "targetBundleID": BUNDLE_ID,
        "action": "research.importDocuments",
        "createdAt": created.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "expiresAt": expires.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "nonce": base64.b64encode(b"n" * 32).decode("ascii"),
        "items": [item],
        "references": [],
        "parameters": {},
    }
    manifest.update(overrides)
    (package / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    return package


def test_gaoaction_import_and_rejections(tmp_path: Path):
    research = store(tmp_path)
    folder_id = research.create_folder("importantLiterature", "来稿")
    package = _package(tmp_path, NOW, b"handoff body")
    result = research.import_gaoaction(package, folder_id)
    assert result["imported"] == 1
    again = research.import_gaoaction(package, folder_id)
    assert again["duplicate"] is True
    assert len(research.library.data["managedDocuments"]) == 1
    bad = _package(tmp_path / "bad", NOW, b"x", **{"parameters": {"targetRecordID": "legacy"}})
    with pytest.raises(AppError) as raised:
        research.import_gaoaction(bad, folder_id)
    assert raised.value.code == "invalid_parameters"
    expired = _package(tmp_path / "old", NOW, b"x")
    manifest = json.loads((expired / "manifest.json").read_text(encoding="utf-8"))
    manifest["expiresAt"] = "2026-11-14T11:00:00Z"
    (expired / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(AppError) as raised:
        research.import_gaoaction(expired, folder_id)
    assert raised.value.code == "expired"
    traversal = _package(tmp_path / "walk", NOW, b"x")
    manifest = json.loads((traversal / "manifest.json").read_text(encoding="utf-8"))
    manifest["items"][0]["relativePath"] = "payload/../secret.txt"
    (traversal / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(AppError) as raised:
        validate_import_manifest((traversal / "manifest.json").read_bytes(), NOW)
    assert raised.value.code == "unsafe_path"
    mismatch = _package(tmp_path / "sum", NOW, b"real")
    manifest = json.loads((mismatch / "manifest.json").read_text(encoding="utf-8"))
    manifest["items"][0]["sha256"] = "a" * 64
    (mismatch / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(AppError) as raised:
        research.import_gaoaction(mismatch, folder_id)
    assert raised.value.code == "checksum_mismatch"


def test_journal_metrics_parser_and_secret_stays_out_of_library(tmp_path: Path):
    payload = {
        "code": 200,
        "data": {
            "publicationName": "Nature",
            "officialRank": {
                "all": {"sci": "Q1", "sciif": 50.5, "ignored": False, "pku": "-"},
                "select": {"ssci": "Q2"},
            },
            "customRank": {
                "rank": ["u1&&&1"],
                "rankInfo": [{"uuid": "u1", "abbName": "CSSCI", "oneRankText": "核心"}],
            },
        },
    }
    snapshot = parse_easyscholar(payload, "nat", now=NOW)
    keys = [item["key"] for item in snapshot["items"]]
    assert keys[:2] == ["sci", "sciif"] or "sci" in keys
    assert "ssci" in keys
    assert "pku" not in keys
    assert "ignored" not in keys
    assert "custom:u1" in keys
    assert summary_items(snapshot["items"])[0]["key"] == "sci"
    suggestions = parse_crossref(
        {"message": {"items": [{"title": "Nature", "ISSN": ["0028-0836"], "publisher": "Springer"}, {"title": "Nature", "ISSN": ["0028-0836"]}]}}
    )
    assert len(suggestions) == 1
    research = store(tmp_path)

    def transport(url: str):
        assert "top-secret" in url
        return payload

    research.set_easyscholar_key("top-secret")
    found = research.lookup_metrics("Nature", transport=transport)
    assert found["matchedJournalName"] == "Nature"
    assert "top-secret" not in research.library.path.read_text(encoding="utf-8")
    with pytest.raises(AppError) as raised:
        parse_easyscholar({"code": 200, "data": {"officialRank": {"all": {}}}}, "x")
    assert raised.value.code == "no_metrics"


def test_http_api_create_import_and_host_guard(tmp_path: Path):
    opened = Library(tmp_path).open()
    research = ResearchStore(opened, clock=lambda: NOW)
    server = make_server(research)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    port = server.server_address[1]
    try:
        page = HTTPConnection("127.0.0.1", port)
        page.request("GET", "/")
        body = page.getresponse().read().decode("utf-8")
        assert "搞研究" in body
        assert server.token in body
        denied = HTTPConnection("127.0.0.1", port)
        denied.request("GET", "/api/bootstrap", headers={"Host": "evil.example"})
        assert denied.getresponse().status == 403
        missing = HTTPConnection("127.0.0.1", port)
        missing.request("GET", "/api/bootstrap")
        assert missing.getresponse().status == 401
        headers = {"X-Gao-Token": server.token, "Content-Type": "application/json"}
        created = HTTPConnection("127.0.0.1", port)
        created.request("POST", "/api/library/create", body=b"{}", headers=headers)
        assert created.getresponse().status == 200
        paper = HTTPConnection("127.0.0.1", port)
        paper.request(
            "POST",
            "/api/papers",
            body=json.dumps(
                {"title": "接口论文", "venue": "Science", "status": "已投稿", "statusSince": "2026-11-01"}
            ).encode(),
            headers=headers,
        )
        assert paper.getresponse().status == 200
        listed = HTTPConnection("127.0.0.1", port)
        listed.request("GET", "/api/papers?scope=all", headers=headers)
        payload = json.loads(listed.getresponse().read().decode("utf-8"))
        assert payload["papers"][0]["title"] == "接口论文"
        folder = HTTPConnection("127.0.0.1", port)
        folder.request(
            "POST",
            "/api/documents/folder",
            body=json.dumps({"kind": "summaryReports", "name": "周报"}).encode(),
            headers=headers,
        )
        folder_id = json.loads(folder.getresponse().read().decode("utf-8"))["id"]
        boundary = "gaoboundary"
        multipart = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="folderID"\r\n\r\n{folder_id}\r\n'
            f"--{boundary}\r\n"
            'Content-Disposition: form-data; name="file"; filename="a.txt"\r\n\r\n'
            "hello\r\n\r\n"
            f"--{boundary}--\r\n"
        ).encode()
        upload = HTTPConnection("127.0.0.1", port)
        upload.request(
            "POST",
            "/api/documents/import",
            body=multipart,
            headers={"X-Gao-Token": server.token, "Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        uploaded = json.loads(upload.getresponse().read().decode("utf-8"))
        assert uploaded["imported"] == 1
        assert uploaded["document"]["contentText"] == "hello"
    finally:
        server.shutdown()
        server.server_close()


def test_multipart_preserves_trailing_newline():
    body = (
        b"--edge\r\n"
        b'Content-Disposition: form-data; name="file"; filename="a.txt"\r\n\r\n'
        b"hello\r\n"
        b"\r\n--edge--\r\n"
    )
    parsed = parse_multipart(body, "edge")
    assert parsed["files"]["file"]["content"] == b"hello\r\n"


def test_cli_inspect_is_aggregate(tmp_path: Path, capsys):
    from gaoyanjiu.cli import main

    root = tmp_path / "data"
    assert main(["--data-dir", str(root), "--create-empty"]) == 0
    assert main(["--data-dir", str(root), "--inspect"]) == 0
    output = capsys.readouterr().out
    assert '"papers": 0' in output
    snapshot = main(["--data-dir", str(root), "--widget-snapshot"])
    assert snapshot == 0
    assert "activeSubmissions" in capsys.readouterr().out
