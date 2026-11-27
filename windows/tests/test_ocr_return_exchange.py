import tempfile
import unittest
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

from gaoyanjiu import BUNDLE_ID
from gaoyanjiu.errors import AppError
from gaoyanjiu.exchange import CHOOSE, OCR, ResearchExchange, _package_write
from gaoyanjiu.fsutil import sha256_bytes
from gaoyanjiu.gaoaction import decode_json, encode_json, envelope
from gaoyanjiu.library import Library
from gaoyanjiu.ocr_returns import OcrReturns
from gaoyanjiu.store import ResearchStore

PROVIDER = "com.gaoseries.GaoCaoZuo"


class OcrReturnExchangeTest(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="research-ocr-return-")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.now = datetime(2026, 11, 27, 1, tzinfo=timezone.utc)
        self.returns = OcrReturns(self.root / "OcrReturns-v1")
        self.store = self.new_store("Research")
        self.exchange = ResearchExchange(self.store, ocr_returns=self.returns)
        self.folder = self.store.create_folder("importantLiterature", "Fixture")
        self.original = self.store.import_bytes(self.folder, b"synthetic source", "fixture.png")["document"]

    def new_store(self, name):
        library = Library(self.root / name).open()
        library.create_empty()
        return ResearchStore(library, clock=lambda: self.now)

    def prepare(self, *, auto_return=True):
        return self.exchange.prepare(OCR, [self.original["id"]], launch=False, auto_return=auto_return)

    def result(self, request):
        raw = (Path(request["path"]) / "manifest.json").read_bytes()
        original = decode_json(raw)
        item = original["items"][0]
        identity = {"sourceID": str(uuid.uuid4()), "sourceItemID": item["id"], "sourceSHA256": item["sha256"]}
        manifest = envelope("result", OCR, PROVIDER, BUNDLE_ID, self.now, original["parameters"])
        manifest.update(inReplyTo=request["requestID"], status="partial", provenance={
            "requestManifestSHA256": sha256_bytes(raw), "engine": "Fixture OCR",
            "sources": [{**identity, "outputItemIDs": ["json"], "pages": [
                {"pageNumber": 1, "status": "completed", "lineCount": 1},
                {"pageNumber": 2, "status": "failed", "lineCount": 0},
            ]}],
            "outputs": [{**identity, "resultItemID": "json", "format": "json"}],
            "exportFailures": ["The fixture has no searchable PDF for the failed page."],
        })
        payload = {"schemaVersion": 1, "sources": [{"sha256": item["sha256"], "byteCount": item["byteCount"],
                    "pages": [{"page": 1, "status": "completed", "lines": [{"text": "fixture text"}]},
                              {"page": 2, "status": "failed", "lines": []}]}]}
        return manifest, payload

    def publish(self, request, manifest, payload, *, automatic=True):
        content = encode_json(payload)
        manifest["items"] = [{"id": "json", "relativePath": "OCR-1.json", "uti": "public.json",
                              "byteCount": len(content), "sha256": sha256_bytes(content)}]
        target = (self.returns.root / request["requestID"] / "result.gaoaction" if automatic
                  else self.root / (manifest["requestID"] + ".gaoaction"))
        _package_write(target, manifest, [("OCR-1.json", content)])
        return target

    def test_only_successful_explicit_ocr_preparation_creates_bound_ticket(self):
        manual = self.prepare(auto_return=False)
        self.assertFalse(manual["autoReturn"])
        self.assertEqual(decode_json((Path(manual["path"]) / "manifest.json").read_bytes())["parameters"],
                         {"outputs": ["text", "json", "searchablePDF"]})
        self.assertIsNone(self.returns.ticket(manual["requestID"], self.now))
        chosen = self.exchange.prepare(CHOOSE, folder_id=self.folder, launch=False, auto_return=True)
        self.assertFalse(chosen["autoReturn"])
        with patch.object(self.exchange, "_stage", side_effect=OSError("disk failed")):
            with self.assertRaises(OSError):
                self.prepare()
        self.assertFalse(self.returns.root.exists())

        request = self.prepare()
        self.assertTrue(request["autoReturn"])
        raw = (Path(request["path"]) / "manifest.json").read_bytes()
        self.assertEqual(self.returns.ticket(request["requestID"], self.now), {
            "schemaVersion": 1, "requestID": request["requestID"], "action": OCR,
            "sourceBundleID": BUNDLE_ID, "targetBundleID": PROVIDER,
            "requestManifestSHA256": sha256_bytes(raw), "expiresAt": request["expiresAt"],
        })
        self.assertEqual(self.exchange.ocr_returns_state(), {"waiting": True, "pending": []})

    def test_auto_stage_is_idempotent_and_review_is_durable(self):
        request = self.prepare()
        manifest, payload = self.result(request)
        path = self.publish(request, manifest, payload)
        self.assertTrue(path.is_dir())
        other = ResearchExchange(self.new_store("Other"), ocr_returns=self.returns)
        with self.assertRaises(AppError) as denied:
            other.receive_ocr_return(request["requestID"])
        self.assertEqual(denied.exception.code, "not_found")

        state = self.exchange.poll_ocr_returns()
        self.assertFalse(state["waiting"])
        self.assertEqual(len(state["pending"]), 1)
        summary = state["pending"][0]
        self.assertEqual(summary["status"], "pending")
        self.assertTrue(summary["autoReturned"])
        self.assertEqual(summary["sourceDocumentIDs"], [self.original["id"]])
        self.assertEqual(summary["sourceNames"], [self.original["displayName"]])
        self.assertEqual(self.exchange.receive_ocr_return(request["requestID"])["id"], summary["id"])
        self.assertEqual(len(self.exchange.overview()["incoming"]), 1)
        self.assertEqual(len(self.store.documents_in(self.folder)), 1)
        detail = self.exchange.review(summary["id"])
        self.assertEqual(detail["sources"][0]["pages"][0]["text"], "fixture text")
        self.assertEqual(detail["sources"][0]["pages"][1]["status"], "failed")
        row, digest = self.exchange.ocr_source(summary["id"], detail["sources"][0]["sourceItemID"])
        self.assertEqual(row["id"], self.original["id"])
        self.assertEqual(digest, self.original["sha256"])
        with self.assertRaises(AppError):
            self.exchange.ocr_source(summary["id"], str(uuid.uuid4()))

        self.now += timedelta(seconds=121)
        self.assertIsNone(self.returns.ticket(request["requestID"], self.now))
        self.exchange = ResearchExchange(self.store, ocr_returns=self.returns)
        self.assertEqual(self.exchange.ocr_returns_state()["pending"][0]["status"], "pending")
        with self.assertRaises(AppError):
            self.exchange.apply(summary["id"], True)
        self.assertEqual(self.exchange.apply(summary["id"], True, accept_partial=True)["imported"], 1)
        self.assertEqual(self.exchange.ocr_returns_state()["pending"], [])
        self.assertEqual(self.store._document_path(row).read_bytes(), b"synthetic source")

    def test_manual_result_retains_existing_expiry_behavior(self):
        request = self.prepare(auto_return=False)
        manifest, payload = self.result(request)
        manifest["provenance"].pop("requestManifestSHA256")
        summary = self.exchange.receive(self.publish(request, manifest, payload, automatic=False))
        self.assertEqual(summary["status"], "pending")
        self.assertFalse(summary["autoReturned"])
        self.assertEqual([row["id"] for row in self.exchange.ocr_returns_state()["pending"]], [summary["id"]])
        self.exchange = ResearchExchange(self.store, ocr_returns=self.returns)
        self.assertEqual([row["id"] for row in self.exchange.ocr_returns_state()["pending"]], [summary["id"]])
        self.now += timedelta(seconds=121)
        self.assertEqual(self.exchange.review(summary["id"])["status"], "expired")
        self.assertEqual(self.exchange.ocr_returns_state()["pending"], [])
        with self.assertRaises(AppError) as expired:
            self.exchange.apply(summary["id"], True, accept_partial=True)
        self.assertEqual(expired.exception.code, "expired")

    def test_shared_ticket_alone_cannot_opt_in_a_manual_request(self):
        request = self.prepare(auto_return=False)
        raw = (Path(request["path"]) / "manifest.json").read_bytes()
        self.returns.prepare(request["requestID"], sha256_bytes(raw), request["expiresAt"], self.now)
        self.publish(request, *self.result(request))
        self.assertEqual(self.exchange.poll_ocr_returns(), {"waiting": False, "pending": []})
        with self.assertRaises(AppError) as err:
            self.exchange.receive_ocr_return(request["requestID"])
        self.assertEqual(err.exception.code, "request_conflict")

    def test_same_result_id_with_different_manifest_cannot_replace_review(self):
        request = self.prepare()
        manifest, payload = self.result(request)
        result = self.publish(request, manifest, payload)
        self.assertEqual(self.exchange.receive_ocr_return(request["requestID"])["status"], "pending")
        result.rename(result.with_name("prior.gaoaction"))
        payload["sources"][0]["pages"][0]["lines"][0]["text"] = "altered"
        self.publish(request, manifest, payload)
        with self.assertRaises(AppError) as err:
            self.exchange.receive_ocr_return(request["requestID"])
        self.assertEqual(err.exception.code, "request_conflict")
        saved = self.exchange.review(manifest["requestID"])
        self.assertEqual(saved["sources"][0]["pages"][0]["text"], "fixture text")

    def test_empty_failure_stays_out_of_automatic_review(self):
        request = self.prepare()
        manifest, _ = self.result(request)
        manifest["status"] = "failed"
        manifest["provenance"].update(sources=[], outputs=[])
        target = self.returns.root / request["requestID"] / "result.gaoaction"
        _package_write(target, manifest, [])
        self.assertEqual(self.exchange.poll_ocr_returns(), {"waiting": True, "pending": []})
        self.assertEqual(self.exchange.overview()["incoming"], [])

    def test_rejects_invalid_fixed_result_without_staging(self):
        def wrong_artifact_pages(_manifest, payload):
            payload["sources"][0]["pages"][1]["page"] = 3

        def wrong_binding(manifest, _payload):
            manifest["provenance"]["sources"][0]["sourceSHA256"] = "0" * 64

        def no_usable_page(manifest, payload):
            manifest["provenance"]["sources"][0]["pages"][0]["status"] = "failed"
            payload["sources"][0]["pages"][0].update(status="failed", lines=[])

        changes = {
            "missing raw hash": lambda result, _: result["provenance"].pop("requestManifestSHA256"),
            "wrong raw hash": lambda result, _: result["provenance"].update(requestManifestSHA256="0" * 64),
            "wrong request": lambda result, _: result.update(inReplyTo=str(uuid.uuid4())),
            "wrong provider": lambda result, _: result.update(sourceBundleID="com.example.Other"),
            "wrong target": lambda result, _: result.update(targetBundleID="com.gaoseries.GaoYanJiu"),
            "wrong parameters": lambda result, _: result.update(parameters={}),
            "wrong source binding": wrong_binding,
            "wrong artifact pages": wrong_artifact_pages,
            "only failed pages": no_usable_page,
            "invalid failure list": lambda result, _: result["provenance"].update(exportFailures=None),
        }
        for reason, modify in changes.items():
            with self.subTest(reason=reason):
                request = self.prepare()
                manifest, payload = self.result(request)
                modify(manifest, payload)
                self.publish(request, manifest, payload)
                with self.assertRaises(AppError):
                    self.exchange.receive_ocr_return(request["requestID"])
                self.assertEqual(self.exchange.overview()["incoming"], [])

    def test_local_raw_request_original_bytes_and_ttl_are_rechecked(self):
        cases = (
            ("request", "checksum_mismatch"),
            ("original", "checksum_mismatch"),
            ("expiry", "expired"),
        )
        for subject, code in cases:
            with self.subTest(subject=subject):
                request = self.prepare()
                self.publish(request, *self.result(request))
                if subject == "request":
                    file = Path(request["path"]) / "manifest.json"
                    file.write_bytes(file.read_bytes() + b"\n")
                elif subject == "original":
                    self.store._document_path(self.original).write_bytes(b"modified source")
                else:
                    self.now += timedelta(seconds=121)
                with self.assertRaises(AppError) as error:
                    self.exchange.receive_ocr_return(request["requestID"])
                self.assertEqual(error.exception.code, code)
                self.assertEqual(self.exchange.overview()["incoming"], [])
                self.store._document_path(self.original).write_bytes(b"synthetic source")

    def test_poll_rediscovers_eligible_request_past_batch_boundary(self):
        for _ in range(5):
            self.prepare(auto_return=False)
        request = self.prepare()
        manifest, payload = self.result(request)
        self.publish(request, manifest, payload)
        self.exchange = ResearchExchange(self.store, ocr_returns=self.returns)
        with patch("gaoyanjiu.exchange.OCR_DISCOVERY_BATCH", 1):
            self.assertTrue(self.exchange.ocr_returns_state()["waiting"])
            for _ in range(8):
                state = self.exchange.poll_ocr_returns()
                if not state["waiting"]:
                    break
        self.assertFalse(state["waiting"])
        self.assertEqual([row["id"] for row in state["pending"]], [manifest["requestID"]])

if __name__ == "__main__":
    unittest.main()
