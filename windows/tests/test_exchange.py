import io
import json
import os
import re
import subprocess
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from gaoyanjiu import BUNDLE_ID
from gaoyanjiu.errors import AppError
from gaoyanjiu.exchange import CHOOSE, EDIT, IMPORT, OCR, ResearchExchange, _package_write
from gaoyanjiu.fsutil import sha256_bytes
from gaoyanjiu.gaoaction import envelope
from gaoyanjiu.library import Library
from gaoyanjiu.store import ResearchStore
from gaoyanjiu.web import Api

FILES_ID = "com.gaoseries.GaoWenJian"
OPERATIONS_ID = "com.gaoseries.GaoCaoZuo"
MOMENT = datetime(2026, 11, 27, 1, tzinfo=timezone.utc)


class ExchangeTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="gaoyanjiu-exchange-")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.now = MOMENT
        self.library = Library(self.root / "Research").open()
        self.library.create_empty()
        self.store = ResearchStore(self.library, clock=lambda: self.now)
        self.exchange = ResearchExchange(self.store)
        self.folder = self.store.create_folder("importantLiterature", "Reference")

    def package(self, manifest, outputs=()):
        path = self.root / (manifest["requestID"] + ".gaoaction")
        payloads = []
        for item_id, transport, uti, content in outputs:
            payloads.append((transport, content))
            manifest["items"].append({"id": item_id, "relativePath": transport, "uti": uti,
                                      "sha256": sha256_bytes(content), "byteCount": len(content)})
        _package_write(path, manifest, payloads)
        return path

    def test_incoming_request_review_and_receipts(self):
        manifest = envelope("request", IMPORT, FILES_ID, "com.gaoseries.GaoYanJiu", self.now, {})
        path = self.package(manifest, [("source", "payload/source.txt", "public.plain-text", b"inside")])
        api = Api(self.store)
        status, review = api.call("POST", "/api/exchange/receive", {}, {"path": str(path)})
        self.assertEqual(status, 200)
        self.assertEqual(review["status"], "pending")
        self.assertEqual(self.store.documents_in(self.folder), [])
        self.assertEqual(api.call("POST", "/api/exchange/apply", {}, {"id": review["id"], "folderID": self.folder})[0], 400)
        imported = self.exchange.apply(review["id"], True, self.folder)
        self.assertEqual(imported, {"imported": 1, "existing": 0, "duplicate": False})
        self.assertEqual(self.exchange.review(review["id"])["status"], "completed")
        first = self.exchange.receipt(review["id"])
        self.now += timedelta(minutes=5)
        second = self.exchange.receipt(review["id"])
        result = json.loads((Path(second["path"]) / "manifest.json").read_text(encoding="utf-8"))
        self.assertNotEqual(first["path"], second["path"])
        self.assertEqual(result["status"], "completed")
        self.assertEqual(result["sourceBundleID"], "com.gaoseries.GaoYanJiu")
        self.assertEqual(result["inReplyTo"], manifest["requestID"])
        self.assertEqual(result["provenance"]["requestManifestSHA256"], sha256_bytes((path / "manifest.json").read_bytes()))
        self.assertEqual(result["provenance"]["sources"][0]["status"], "imported")

    def test_choose_requires_explicit_identity_and_keeps_target(self):
        request = self.exchange.prepare(CHOOSE, folder_id=self.folder, launch=False)
        docs = self.root / "论文 文档.txt"
        docs.write_bytes(b"chosen content")
        result = envelope("result", CHOOSE, FILES_ID, BUNDLE_ID, self.now, {"multiple": True})
        result.update({"inReplyTo": request["requestID"], "status": "completed", "provenance": {}})
        result["references"] = [{"id": "choice", "kind": "file", "displayName": docs.name, "fileURL": docs.as_uri(),
                                 "sha256": sha256_bytes(docs.read_bytes()), "declaredIdentity": {"byteCount": len(docs.read_bytes())}}]
        review = self.exchange.receive(self.package(result))
        wrong = self.store.create_folder("importantLiterature", "Wrong")
        with self.assertRaises(AppError):
            self.exchange.apply(review["id"], True, wrong, {"choice": str(docs)})
        with self.assertRaises(AppError):
            self.exchange.apply(review["id"], True, self.folder)
        self.assertEqual(self.exchange.apply(review["id"], True, self.folder, {"choice": str(docs)})["imported"], 1)
        refreshed = dict(result, requestID=envelope("result", CHOOSE, FILES_ID, BUNDLE_ID, self.now, {})["requestID"])
        second = self.exchange.receive(self.package(refreshed))
        self.assertTrue(self.exchange.apply(second["id"], True, self.folder, {"choice": str(docs)})["duplicate"])

    def test_approved_selection_recovers_after_failed_commit_and_transport_expiry(self):
        request = self.exchange.prepare(CHOOSE, folder_id=self.folder, launch=False)
        docs = self.root / "selected.txt"
        docs.write_bytes(b"the approved original")
        result = envelope("result", CHOOSE, FILES_ID, BUNDLE_ID, self.now, {})
        result.update({"inReplyTo": request["requestID"], "status": "completed", "provenance": {}})
        result["references"] = [{"id": "choice", "kind": "file", "displayName": docs.name,
                                 "fileURL": docs.as_uri(), "declaredIdentity": {}}]
        review = self.exchange.receive(self.package(result))
        with patch.object(self.library, "save", side_effect=OSError("interrupted disk write")):
            with self.assertRaises(OSError):
                self.exchange.apply(review["id"], True, self.folder, {"choice": str(docs)})
        self.assertEqual(self.store.documents_in(self.folder), [])
        docs.unlink()
        self.now += timedelta(minutes=3)
        self.assertEqual(self.exchange.review(review["id"])["status"], "interrupted")
        self.assertEqual(self.exchange.apply(review["id"], True)["imported"], 1)
        [imported] = self.store.documents_in(self.folder)
        self.assertEqual(self.store._document_path(imported).read_bytes(), b"the approved original")

    def test_opened_receipt_explicit_edit_and_attachment_version_trashed_together(self):
        original = self.store.import_bytes(self.folder, b"original", "note.txt")["document"]
        source = self.store._document_path(original)
        request = self.exchange.prepare(EDIT, [original["id"]], launch=False)
        result = envelope("result", EDIT, FILES_ID, BUNDLE_ID, self.now, {})
        result.update({"inReplyTo": request["requestID"], "status": "completed", "provenance": {"workflowState": "opened"}})
        review = self.exchange.receive(self.package(result))
        self.assertFalse(review["canApply"])
        self.assertEqual(source.read_bytes(), b"original")
        self.exchange.edited_from_bytes(original["id"], "name.txt", b"related", "attachment", True)
        same = self.exchange.edited_from_bytes(original["id"], "name.txt", b"version", "version", True)
        self.assertEqual(same["documentID"], original["id"])
        self.assertEqual(source.read_bytes(), b"original")
        self.assertEqual(self.store._document_path(original).read_bytes(), b"version")
        again = self.exchange.edited_from_bytes(original["id"], "name.txt", b"version", "version", True)
        self.assertTrue(again["duplicate"])
        trashed = self.store.trash_document(original["id"])
        self.assertFalse(source.exists())
        self.store.restore(trashed)
        self.assertEqual(source.read_bytes(), b"original")
        folder_trash = self.store.trash_folder(self.folder)
        self.store.restore(folder_trash)
        self.assertEqual(source.read_bytes(), b"original")

    def test_ocr_requires_partial_acknowledgement_and_keeps_provenance(self):
        photo = self.store.import_bytes(self.folder, b"fixture photo", "test.png")["document"]
        request = self.exchange.prepare(OCR, [photo["id"]], launch=False)
        outbound = json.loads((Path(request["path"]) / "manifest.json").read_text(encoding="utf-8"))
        source_id = outbound["items"][0]["id"]
        binding = {"sourceItemID": source_id, "sourceSHA256": photo["sha256"]}
        result = envelope("result", OCR, OPERATIONS_ID, BUNDLE_ID, self.now, outbound["parameters"])
        result.update({"inReplyTo": request["requestID"], "status": "partial", "provenance": {
            "engine": "FixtureOCR", "sources": [{**binding, "outputItemIDs": ["contents"],
                "pages": [{"pageNumber": 1, "status": "completed"}, {"pageNumber": 2, "status": "failed"}]}],
            "outputs": [{**binding, "resultItemID": "contents", "format": "json"}],
        }})
        pages = {"schemaVersion": 1, "sources": [{"sha256": photo["sha256"], "pages": [
            {"page": 1, "status": "completed", "lines": [{"text": "first page"}]},
            {"page": 2, "status": "failed", "lines": []},
        ]}]}
        entries = [("contents", "OCR-1.json", "public.json", json.dumps(pages).encode())]
        review = self.exchange.receive(self.package(result, entries))
        self.assertNotEqual(review["warnings"], [])
        detail = self.exchange.review(review["id"])
        self.assertEqual(detail["outputs"][0]["pages"][0]["text"], "first page")
        self.assertEqual(detail["outputs"][0]["pages"][1]["status"], "failed")
        with self.assertRaises(AppError):
            self.exchange.apply(review["id"], True)
        self.assertEqual(self.exchange.apply(review["id"], True, accept_partial=True)["imported"], 1)
        artifact = next(row for row in self.store.documents_in(self.folder) if row["id"] != photo["id"])
        self.assertEqual(artifact["windowsProvenance"]["sourceDocumentID"], photo["id"])
        self.assertEqual(artifact["contentText"], "first page")
        self.assertEqual(self.store._document_path(photo).read_bytes(), b"fixture photo")
        fresh = envelope("result", OCR, OPERATIONS_ID, BUNDLE_ID, self.now, {})
        fresh.update({key: result[key] for key in ("inReplyTo", "status", "provenance")})
        normalized_entries = [("contents", "payload/different-transport.json", "public.json", entries[0][3])]
        other = self.exchange.receive(self.package(fresh, normalized_entries))
        self.assertTrue(self.exchange.apply(other["id"], True, accept_partial=True)["duplicate"])
        fresh = envelope("result", OCR, OPERATIONS_ID, BUNDLE_ID, self.now, {})
        fresh.update({key: result[key] for key in ("inReplyTo", "status", "provenance")})
        fresh["status"] = "completed"
        with self.assertRaises(AppError):
            self.exchange.receive(self.package(fresh, entries))

    @unittest.skipUnless(os.environ.get("GAOWENJIAN_TEST_SOURCE"), "requires current GaoWenJian Windows source and its dependencies on PYTHONPATH")
    def test_gaowenjian_source_choose_edit_and_receipt(self):
        from gaowenjian.organizer_actions import complete
        from gaowenjian.workspace import Workspace

        self.store.clock = lambda: datetime.now(timezone.utc)
        files = Workspace(self.root / "GaoWenJian")
        selected = self.root / "selected.md"
        selected.write_text("# Original chosen in GaoWenJian", encoding="utf-8")
        choose = self.exchange.prepare(CHOOSE, folder_id=self.folder, launch=False)
        reviewed = files.inspect_handoff(Path(choose["path"]))
        self.assertTrue(reviewed["organizer"]["multiple"])
        reply = complete(files, {"path": choose["path"], "sha256": reviewed["sha256"], "confirm": True,
                                 "destination": str(self.root), "paths": [str(selected)]})
        review = self.exchange.receive(Path(reply["path"]))
        chosen = review["references"][0]
        self.assertEqual(self.exchange.apply(review["id"], True, self.folder, {chosen["id"]: str(selected)})["imported"], 1)
        [original] = self.store.documents_in(self.folder)
        before = self.store._document_path(original)
        self.assertEqual(before.read_bytes(), selected.read_bytes())

        request = self.exchange.prepare(EDIT, [original["id"]], launch=False)
        inspection = files.inspect_handoff(Path(request["path"]))
        self.assertEqual(inspection["action"], EDIT)
        tab = files.import_handoff(Path(request["path"]), inspection["sha256"])
        files.edit(tab.id, "# Edited copy")
        edited = self.root / "edited.md"
        files.save(tab.id, edited, as_copy=True)
        applied = self.exchange.edited_from_path(original["id"], edited, "version", True)
        self.assertEqual(applied["documentID"], original["id"])
        self.assertEqual(self.store._document_path(original).read_text(encoding="utf-8"), "# Edited copy")
        self.assertEqual(before.read_bytes(), selected.read_bytes())

        files.edit(tab.id, "# Separately sent to research")
        package = files.export_research(tab.id, self.root)
        inbound = self.exchange.receive(Path(package["path"]))
        self.assertEqual(inbound["status"], "pending")
        self.assertEqual(self.exchange.apply(inbound["id"], True, self.folder)["imported"], 1)
        receipt = self.exchange.receipt(inbound["id"], self.root)
        acknowledged = files.handoff.import_package(Path(receipt["path"]))
        self.assertEqual(acknowledged["opened"][0], {"kind": "receipt", "status": "completed"})

    @unittest.skipUnless(os.name == "nt" and os.environ.get("GAOCAOZUO_TEST_EXE"), "requires installed isolated GaoCaoZuo CLI")
    def test_installed_provider_png_and_pdf_roundtrip(self):
        cli = os.environ["GAOCAOZUO_TEST_EXE"]
        powershell = r"""
        Add-Type -AssemblyName System.Drawing
        $bitmap = New-Object Drawing.Bitmap 1000,260
        $graphics = [Drawing.Graphics]::FromImage($bitmap)
        $font = New-Object Drawing.Font Arial,75
        try {
            $graphics.Clear([Drawing.Color]::White)
            $graphics.DrawString('12345 67890', $font, [Drawing.Brushes]::Black, 60, 75)
            $bitmap.Save($env:GAO_RESEARCH_SYNTHETIC_PNG,[Drawing.Imaging.ImageFormat]::Png)
        } finally {
            $font.Dispose()
            $graphics.Dispose()
            $bitmap.Dispose()
        }
        """
        photo_path = self.root / "digits.png"
        subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-Command", powershell], check=True,
                       env={**os.environ, "GAO_RESEARCH_SYNTHETIC_PNG": str(photo_path)}, creationflags=subprocess.CREATE_NO_WINDOW)
        photo = self.store.import_path(self.folder, photo_path)["document"]
        pdf = self.store.import_bytes(self.folder, synthetic_pdf(), "two-pages.pdf")["document"]
        self.now = datetime.now(timezone.utc)
        self.store.clock = lambda: datetime.now(timezone.utc)
        expected = {photo["id"]: photo["sha256"], pdf["id"]: pdf["sha256"]}
        capability = json.loads(subprocess.check_output([cli, "--capabilities"], creationflags=subprocess.CREATE_NO_WINDOW))
        self.assertEqual(capability["appVersion"], "1.16")
        process = subprocess.Popen([cli, "--no-browser", "--data-dir", str(self.root / "GaoCaoZuo"), "--port", "0"],
                                   creationflags=subprocess.CREATE_NO_WINDOW, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(finish_provider, process)
        output = io.BytesIO()
        threading.Thread(target=lambda: output.write(process.stdout.readline()), daemon=True).start()
        deadline = threading.Event()
        for _ in range(200):
            if output.getvalue() or process.poll() is not None:
                break
            deadline.wait(0.2)
        origin = output.getvalue().decode().strip()
        self.assertRegex(origin, r"^http://127\.0\.0\.1:\d+/$")
        direct = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with direct.open(origin, timeout=5) as response:
            token = re.search(rb'name="gao-token" content="([^"]+)"', response.read())[1].decode()

        def approve(action, payload):
            request = urllib.request.Request(origin + action, data=json.dumps(payload).encode(), headers={
                "X-Gao-Token": token, "Content-Type": "application/json; charset=utf-8",
            })
            try:
                with direct.open(request, timeout=60) as response:
                    return json.load(response).get("result")
            except urllib.error.HTTPError as exc:
                raise AssertionError(f"{action}: {exc.read().decode()}") from exc

        def shutdown():
            if process.poll() is None:
                approve("api/shutdown", {})
                self.assertEqual(process.wait(20), 0)

        self.addCleanup(shutdown)

        self.assertTrue(approve("api/screenshot/ocr/languages", {})["languages"])
        prepared = self.exchange.prepare(OCR, [photo["id"], pdf["id"]], launch=False)
        provider = approve("api/ocr-provider/review", {"path": prepared["path"]})
        self.assertEqual(provider["status"], "pending")
        executed = approve("api/ocr-provider/approve", {"requestID": provider["requestID"], "confirm": True})
        self.assertEqual(executed["status"], "completed")

        def export():
            delivered = approve("api/ocr-provider/result", {"requestID": provider["requestID"], "directory": str(self.root), "confirm": True})
            return self.exchange.receive(Path(delivered["path"]))

        result = export()
        details = self.exchange.review(result["id"])
        self.assertEqual(len(details["outputs"]), 6)
        self.assertEqual(sorted(len(source["pages"]) for source in details["sources"]), [1, 2])
        for output in details["outputs"]:
            self.assertEqual(output["sourceSHA256"], expected[output["sourceDocumentID"]])
            self.assertTrue(any("12345" in page["text"].replace(" ", "") for page in output["pages"]))
        self.assertEqual(self.exchange.apply(result["id"], True, accept_partial=True)["imported"], 6)
        duplicate = export()
        self.assertTrue(self.exchange.apply(duplicate["id"], True, accept_partial=True)["duplicate"])
        self.assertEqual(len(self.store.documents_in(self.folder)), 8)
        for original in (photo, pdf):
            self.assertEqual(sha256_bytes(self.store._document_path(original).read_bytes()), expected[original["id"]])
        shutdown()


def finish_provider(process):
    if process.poll() is None:
        process.terminate()
        process.wait(15)
    process.stdout.close()
    process.stderr.close()


def synthetic_pdf():
    font = b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"
    catalog = b"<< /Type /Catalog /Pages 2 0 R >>"
    tree = b"<< /Type /Pages /Count 2 /Kids [4 0 R 6 0 R] >>"
    objects = [catalog, tree, font]
    for index, digits in zip((5, 7), (b"12345 67890", b"12345 09876")):
        objects.append(b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 300] /Resources << /Font << /F 3 0 R >> >> /Contents %d 0 R >>" % index)
        commands = b"BT /F 60 Tf 45 140 Td (%s) Tj ET" % digits
        objects.append(b"<< /Length %d >>\nstream\n%s\nendstream" % (len(commands), commands))
    data = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, item in enumerate(objects, 1):
        offsets.append(len(data))
        data.extend(b"%d 0 obj\n%s\nendobj\n" % (index, item))
    xref = len(data)
    data.extend(b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1))
    for offset in offsets:
        data.extend(b"%010d 00000 n \n" % offset)
    data.extend(b"trailer\n<< /Root 1 0 R /Size %d >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref))
    return bytes(data)
