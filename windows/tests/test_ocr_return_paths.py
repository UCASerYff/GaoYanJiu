import json
import os
import subprocess
import uuid
from datetime import datetime, timedelta, timezone

import pytest

from gaoyanjiu import BUNDLE_ID
from gaoyanjiu.errors import AppError
from gaoyanjiu.gaoaction import encode_json, envelope
from gaoyanjiu.ocr_returns import ACTION, PROVIDER, OcrReturns
from gaoyanjiu.timeutil import format_iso

NOW = datetime(2026, 11, 27, 8, 30, tzinfo=timezone.utc)
ID = "27c14873-8218-4f06-9df3-062a0d73df33"
DIGEST = "a" * 64
EXPIRY = format_iso(NOW + timedelta(seconds=120))


def test_ticket_is_atomic_exact_and_limited_to_canonical_request(tmp_path):
    relay = OcrReturns(tmp_path / "returns")
    assert relay.ticket(ID, NOW) is None
    with pytest.raises(AppError, match="invalid_manifest"):
        relay.prepare(ID.upper(), DIGEST, EXPIRY, NOW)
    relay.prepare(ID, DIGEST, EXPIRY, NOW)
    ticket = tmp_path / "returns" / ID / "request.json"
    first = ticket.read_bytes()
    assert first.startswith(b"{") and set(ticket.parent.iterdir()) == {ticket}
    assert json.loads(first) == {
        "schemaVersion": 1, "requestID": ID, "action": ACTION,
        "sourceBundleID": BUNDLE_ID, "targetBundleID": PROVIDER,
        "requestManifestSHA256": DIGEST, "expiresAt": EXPIRY,
    }
    relay.prepare(ID, DIGEST, EXPIRY, NOW)
    with pytest.raises(AppError) as conflict:
        relay.prepare(ID, "b" * 64, EXPIRY, NOW)
    assert conflict.value.code == "request_conflict"
    assert ticket.read_bytes() == first
    assert relay.ticket(ID, NOW + timedelta(seconds=120)) is None
    with relay.open_result(ID, NOW) as opened:
        assert opened is None


def _result(relay, *, referenced=True):
    package = relay.root / ID / "result.gaoaction"
    package.mkdir()
    manifest = envelope("result", ACTION, PROVIDER, BUNDLE_ID, NOW, {})
    manifest.update(inReplyTo=ID, status="completed", provenance={"requestManifestSHA256": DIGEST})
    if referenced:
        manifest["items"] = [{"id": str(uuid.uuid4()), "relativePath": "one/output.json", "uti": "public.json",
                              "byteCount": 2, "sha256": "b" * 64}]
    (package / "manifest.json").write_bytes(encode_json(manifest))
    return package


def test_uses_fixed_directory_and_pins_referenced_content(tmp_path):
    relay = OcrReturns(tmp_path / "returns")
    relay.prepare(ID, DIGEST, EXPIRY, NOW)
    session = relay.root / ID
    staging = session / "provider-stage.tmp"
    staging.mkdir()
    with relay.open_result(ID, NOW) as discovered:
        assert discovered is None
        staging.rename(session / "result.gaoaction")
    (session / "result.gaoaction").rmdir()
    package = _result(relay)
    payload = package / "payload" / "one" / "output.json"
    payload.parent.mkdir(parents=True)
    payload.write_bytes(b"{}")
    with relay.open_result(ID, NOW) as discovered:
        ticket, fixed = discovered
        assert ticket["requestManifestSHA256"] == DIGEST and fixed == package
        if os.name == "nt":
            with pytest.raises(OSError):
                payload.rename(payload.with_suffix(".other"))
            with pytest.raises(OSError):
                package.rename(package.with_name("unexpected.gaoaction"))
    payload.rename(payload.with_suffix(".other"))
    with relay.open_result(ID, NOW) as discovered:
        assert discovered is None


def test_rejects_hard_linked_referenced_payload(tmp_path):
    relay = OcrReturns(tmp_path / "returns")
    relay.prepare(ID, DIGEST, EXPIRY, NOW)
    package = _result(relay)
    payload = package / "payload" / "one" / "output.json"
    payload.parent.mkdir(parents=True)
    external = tmp_path / "external.json"
    external.write_bytes(b"{}")
    try:
        os.link(external, payload)
    except PermissionError:
        pytest.skip("This Windows process cannot create fixture hard links")
    with pytest.raises(AppError, match="unsafe_file"), relay.open_result(ID, NOW):
        pytest.fail("A hard-linked payload was accepted")


@pytest.mark.skipif(os.name != "nt", reason="Windows directory junction test")
def test_windows_default_root_rejects_directory_junction(tmp_path, monkeypatch):
    local = tmp_path / "isolated Local AppData"
    local.mkdir()
    monkeypatch.setenv("LOCALAPPDATA", str(local))
    relay = OcrReturns()
    relay.prepare(ID, DIGEST, EXPIRY, NOW)
    fixed = local / "GaoSeries" / "GaoAction" / "OcrReturns-v1" / ID
    assert (fixed / "request.json").is_file()

    external = tmp_path / "unrelated"
    external.mkdir()
    result = fixed / "result.gaoaction"
    linked = subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(result), str(external)],
                            stdin=subprocess.DEVNULL, capture_output=True, check=False)
    if linked.returncode:
        pytest.skip("This Windows process cannot create fixture junctions")
    try:
        with pytest.raises(AppError, match="unsafe_file"), relay.open_result(ID, NOW):
            pytest.fail("A directory junction was accepted")
        assert not list(external.iterdir())
    finally:
        result.rmdir()


@pytest.mark.skipif(os.name != "nt", reason="Windows directory junction test")
def test_windows_ticket_does_not_follow_redirected_fixed_ancestor(tmp_path, monkeypatch):
    local = tmp_path / "isolated child"
    external = tmp_path / "unrelated"
    local.mkdir()
    external.mkdir()
    redirected = local / "GaoSeries"
    monkeypatch.setenv("LOCALAPPDATA", str(local))
    linked = subprocess.run(["cmd.exe", "/d", "/c", "mklink", "/J", str(redirected), str(external)],
                            stdin=subprocess.DEVNULL, capture_output=True, check=False)
    if linked.returncode:
        pytest.skip("This Windows process cannot create fixture junctions")
    try:
        with pytest.raises(AppError, match="unsafe_file"):
            OcrReturns().prepare(ID, DIGEST, EXPIRY, NOW)
        assert not list(external.iterdir())
    finally:
        redirected.rmdir()
