from datetime import datetime, timezone

from pypdf import PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject

from gaoyanjiu.library import Library
from gaoyanjiu.store import ResearchStore
from gaoyanjiu.web import Api


def ready(tmp_path):
    library = Library(tmp_path / "data").open()
    library.create_empty()
    return ResearchStore(library, clock=lambda: datetime(2026, 11, 27, 10, tzinfo=timezone.utc))


def test_legacy_history_survives_v414_workspace_activity(tmp_path):
    store = ready(tmp_path)
    data = store.library.data
    data.update(projects=[{"id": "historic", "steps": [{"finished": True}]}],
                fundingRecords=[{"id": "legacy-funds", "amount": 12}],
                futureMetadata={"opaque": [1, 2, 3]})
    store.library.save()
    store = ResearchStore(Library(store.library.root).open(), clock=store.clock)
    api = Api(store)
    code, response = api.call("GET", "/api/bootstrap", {}, None)
    assert code == 200
    assert "projects" not in response["overview"]
    assert "fundingRecords" not in response["overview"]

    work = store.save_work({"title": "成果", "type": "patent", "patentType": "design"})
    cert = store.save_certificate({"name": "证书", "eventDate": "2026-11-23", "tags": ["竞赛"]})
    assert store.list_works()[0]["id"] == work
    assert store.list_certificates()[0]["id"] == cert
    loaded = Library(store.library.root).open().data
    for name in ("projects", "fundingRecords", "futureMetadata"):
        assert loaded[name] == data[name]


def test_reviewed_portal_capture_transitions_and_archive(tmp_path):
    store = ready(tmp_path)
    api = Api(store)
    source = store.save_portal({"name": "Fixture", "url": "https://site.example/journal/"})
    papers = [{"id": "JR-101", "title": "A synthetic manuscript", "journal": "Fixture Journal", "status": "Submitted"}]
    payload = {"id": source, "capture": {"url": "https://site.example/journal/status?session=synthetic",
                                          "checkedAt": "2026-11-26T00:00:00Z", "papers": papers}}
    code, response = api.call("POST", "/api/portals/capture", {}, payload)
    assert code == 200 and response == {"reviewed": 1, "imported": 1, "changed": 0, "stale": 0}
    paper = store.list_papers()[0]
    key = paper["key"]
    assert paper["url"] == "https://site.example/journal/status"
    assert not paper["changed"]

    wrong = {**payload["capture"], "url": "https://different.example/status"}
    assert api.call("POST", "/api/portals/capture", {}, {**payload, "capture": wrong})[0] == 400
    update = {**payload["capture"], "checkedAt": "2026-11-27T09:00:00Z", "papers": [{**papers[0], "status": "Under review"}]}
    code, response = api.call("POST", "/api/portals/capture", {}, {**payload, "capture": update})
    assert code == 200 and response["changed"] == 1
    [paper] = store.list_papers("changed")
    assert [row["status"] for row in paper["history"]] == ["Submitted", "Under review"]
    assert paper["statusSince"] == "2026-11-27T09:00:00Z"
    assert api.call("POST", "/api/portals/capture", {}, payload)[1]["stale"] == 1
    assert api.call("POST", "/api/papers/read", {}, {"key": key})[0] == 200
    assert not store.list_papers("changed")
    store.set_hidden(key, True)
    assert store.list_papers("hidden")[0]["key"] == key
    store.set_hidden(key, False)
    assert store.list_papers()[0]["status"] == "Under review"
    assert not store.list_papers("changed")


def test_folder_browse_reorder_and_compressed_pdf_search(tmp_path):
    store = ready(tmp_path)
    api = Api(store)
    archive = store.create_folder("importantLiterature", "文献")
    comparison = store.create_folder("importantLiterature", "实验对照")
    experiments = store.create_folder("experimentData", "实验")
    api.call("POST", "/api/reorder", {}, {"kind": "folder", "sourceID": comparison, "targetID": archive})
    assert [item["id"] for item in store.folders("importantLiterature")] == [comparison, archive]
    assert api.call("POST", "/api/reorder", {}, {"kind": "folder", "sourceID": experiments, "targetID": archive})[0] == 400
    assert api.call("POST", "/api/documents/folder", {}, {"kind": "importantLiterature", "name": "文献记录", "id": archive})[1]["id"] == archive
    assert api.call("GET", "/api/documents", {"kind": "importantLiterature", "view": "folders"}, None)[1]["folderID"] == ""

    pdf = tmp_path / "compressed.pdf"
    writer = PdfWriter()
    page = writer.add_blank_page(650, 600)
    font = DictionaryObject({NameObject("/Type"): NameObject("/Font"), NameObject("/Subtype"): NameObject("/Type1"),
                             NameObject("/BaseFont"): NameObject("/Helvetica")})
    page[NameObject("/Resources")] = DictionaryObject({NameObject("/Font"): DictionaryObject({NameObject("/F1"): font})})
    stream = DecodedStreamObject()
    stream.set_data(b"BT /F1 12 Tf 32 32 Td (compressed synthetic phrase) Tj ET")
    page[NameObject("/Contents")] = writer._add_object(stream.flate_encode())
    writer.write(pdf)
    source = store.import_path(archive, pdf, ["压缩"])["document"]
    derivative = store.import_bytes(archive, b"ocr page text", "OCR.txt")["document"]
    derivative["windowsProvenance"] = {"targetRecordID": source["id"], "originalSHA256": source["sha256"],
                                       "sourceName": "compressed.pdf", "pages": [{"pageNumber": 1, "text": "ocr page text"}]}
    store.library.save()

    status, result = api.call("GET", "/api/documents", {"kind": "importantLiterature", "view": "folders", "q": "synthetic phrase"}, None)
    assert status == 200
    assert [item["name"] for item in result["folders"]] == ["文献记录"]
    status, result = api.call("GET", "/api/documents", {"kind": "importantLiterature", "folder": archive, "q": "synthetic phrase"}, None)
    assert status == 200 and [item["id"] for item in result["documents"]] == [source["id"]]
    assert result["tags"] == [{"label": "压缩", "count": 1}]
    assert api.call("GET", "/api/documents/ocr-source", {"id": derivative["id"]}, None)[0] == 200
    store._document_path(source).write_bytes(b"synthetic changed bytes")
    status, result = api.call("GET", "/api/documents/ocr-source", {"id": derivative["id"]}, None)
    assert status == 409 and result["error"] == "ocr_source_changed"


def test_snapshot_failure_does_not_discard_attachment(tmp_path, monkeypatch):
    store = ready(tmp_path)
    owner = store.save_certificate({"name": "Fixture"})
    original = tmp_path / "attachment.txt"
    original.write_bytes(b"isolated bytes")

    def fail_snapshot():
        raise PermissionError("synthetic widget state error")

    monkeypatch.setattr(store, "write_snapshot", fail_snapshot)
    attachment = store.add_attachment("certificate", owner, original)
    disk = Library(store.library.root).open().data["certificates"][0]
    assert disk["attachments"] == [attachment]
    assert store.file_for_download("certificate", owner, attachment["storedName"]).read_bytes() == b"isolated bytes"
