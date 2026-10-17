"""Review over the phone API: pair, preview, approve. The phone is simulated with a real Ed25519 key."""
import base64
import json
import uuid
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi import FastAPI
from fastapi.testclient import TestClient

from mobile_surfaces.api import mount
from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.store import Store

BASE = "/api/plugins/mobile-surfaces/v1"
TEMPLATE = Path(__file__).resolve().parents[2] / "templates" / "starter-app"
DEFS = {"queries": {"items": {"sql": "SELECT id, title, amount FROM items ORDER BY id", "shape": "rows"}},
        "mutations": {}}


class Phone:
    def __init__(self) -> None:
        self.key = Ed25519PrivateKey.generate()
        raw = self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.public = base64.b64encode(raw).decode()

    def sign(self, message: str) -> str:
        return base64.b64encode(self.key.sign(message.encode())).decode()


@pytest.fixture
def env(tmp_path):
    store = Store(tmp_path / "home")
    store.create_app("items_app", "Список")
    store.agent_sql("items_app", "schema", "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, amount INTEGER NOT NULL)")
    store.agent_sql("items_app", "write", "INSERT INTO items(title, amount) VALUES (?,?)", params_list=[("Вода", 119000)])
    auth = Authoring(store, TEMPLATE)
    app = FastAPI()
    mount(app, store, authoring=auth)
    return TestClient(app), store, auth


def build_and_submit(auth: Authoring) -> str:
    auth.write("items_app", "definitions.json", json.dumps(DEFS))
    rev = auth.status("items_app")["draftRev"]
    dist = auth._draft("items_app") / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    (dist / "index.html").write_text("<!doctype html><title>x</title>")
    build_id = "build_" + uuid.uuid4().hex[:10]
    (auth._draft("items_app") / "build.json").write_text(
        json.dumps({"ok": True, "draftRev": rev, "at": "2026-10-12T00:00:00Z", "size": 40, "buildId": build_id}))
    assert auth.publish("items_app")["status"] == "awaiting_review"
    return build_id


def test_health_tells_whether_a_device_is_paired(env):
    client, store, _ = env
    assert client.get(f"{BASE}/health").json()["approverPaired"] is False
    phone = Phone()
    assert client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": phone.public}).json() == {"paired": True}
    assert client.get(f"{BASE}/health").json()["approverPaired"] is True
    # a second phone (or a script holding the token) cannot take the place of the first
    other = client.post(f"{BASE}/devices/pair", json={"deviceId": "ph2", "publicKey": Phone().public})
    assert other.status_code == 409


def test_full_flow_over_http(env):
    client, store, auth = env
    phone = Phone()
    client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": phone.public})
    build_id = build_and_submit(auth)

    listed = client.get(f"{BASE}/previews").json()
    assert [p["appId"] for p in listed["previews"]] == ["items_app"] and listed["approverPaired"] is True
    assert client.get(f"{BASE}/apps").json()["apps"] == []  # the published list is unchanged

    manifest = client.get(f"{BASE}/previews/items_app").json()
    assert manifest["preview"]["buildId"] == build_id and manifest["epoch"] == store.epoch()
    zipped = client.get(f"{BASE}/previews/items_app/bundles/{manifest['bundle']['bundleId']}")
    assert zipped.status_code == 200 and len(zipped.content) == manifest["bundle"]["size"]
    data = client.post(f"{BASE}/previews/items_app/data",
                       json={"revision": manifest["revision"], "queries": [{"name": "items"}]}).json()
    assert data["results"]["items"]["data"] == [{"id": 1, "title": "Вода", "amount": 119000}]

    ch = client.post(f"{BASE}/previews/items_app/challenge").json()
    body = {"buildId": ch["buildId"], "nonce": ch["nonce"], "signature": phone.sign(ch["message"])}
    done = client.post(f"{BASE}/previews/items_app/approve", json=body)
    assert done.status_code == 200 and done.json()["status"] == "published" and done.json()["revision"] == 1
    assert [a["appId"] for a in client.get(f"{BASE}/apps").json()["apps"]] == ["items_app"]
    assert client.get(f"{BASE}/previews").json()["previews"] == []


def test_a_request_with_the_token_but_without_a_valid_signature_is_refused(env):
    client, store, auth = env
    client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": Phone().public})
    build_and_submit(auth)
    ch = client.post(f"{BASE}/previews/items_app/challenge").json()
    forged = {"buildId": ch["buildId"], "nonce": ch["nonce"], "signature": Phone().sign(ch["message"])}
    r = client.post(f"{BASE}/previews/items_app/approve", json=forged)
    assert r.status_code == 422 and "not signed" in r.json()["error"]  # not 401/403: the token is fine
    r = client.post(f"{BASE}/previews/items_app/approve",
                    json={"buildId": ch["buildId"], "nonce": "0" * 32, "signature": "AAAA"})
    assert r.status_code == 409
    assert store.list_apps() == [] and len(client.get(f"{BASE}/previews").json()["previews"]) == 1


def test_reject_and_unknown_apps(env):
    client, store, auth = env
    client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": Phone().public})
    build_id = build_and_submit(auth)
    assert client.post(f"{BASE}/previews/items_app/reject", json={"buildId": build_id}).json() == {"status": "rejected"}
    assert client.get(f"{BASE}/previews/items_app").status_code == 404
    assert client.post(f"{BASE}/previews/items_app/reject", json={"buildId": build_id}).status_code == 404
    assert client.get(f"{BASE}/previews/ghost").status_code == 404
    assert client.post(f"{BASE}/previews/ghost/challenge").status_code == 404
    assert client.post(f"{BASE}/previews/ghost/reject", json={"buildId": build_id}).status_code == 404


def test_http_reject_is_bound_to_the_displayed_build_not_a_replacement(env, review_decision_snapshot):
    client, store, auth = env
    client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": Phone().public})
    build_and_submit(auth)
    displayed_id = client.get(f"{BASE}/previews/items_app").json()["preview"]["buildId"]
    replacement_id = build_and_submit(auth)
    before = review_decision_snapshot(auth)

    response = client.post(f"{BASE}/previews/items_app/reject", json={"buildId": displayed_id})

    assert response.status_code == 409 and "build under review changed" in response.json()["error"]
    assert review_decision_snapshot(auth) == before
    assert client.get(f"{BASE}/previews/items_app").json()["preview"]["buildId"] == replacement_id
    assert client.post(f"{BASE}/previews/items_app/reject", json={"buildId": replacement_id}).json() == {"status": "rejected"}
    assert client.get(f"{BASE}/previews").json()["previews"] == []


@pytest.mark.parametrize("body", [
    {}, {"buildId": None}, {"buildId": 123}, {"buildId": True}, {"buildId": []},
    {"buildId": {}}, {"buildId": ""}, {"buildId": " "}, {"buildId": "not-a-build"},
    {"buildId": "build_" + "a" * 59},
])
def test_http_rejection_requires_a_well_formed_build_target(env, review_decision_snapshot, body):
    client, _, auth = env
    client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": Phone().public})
    build_and_submit(auth)
    before = review_decision_snapshot(auth)

    assert client.post(f"{BASE}/previews/items_app/reject", json=body).status_code == 422
    assert review_decision_snapshot(auth) == before


def test_http_rejection_without_a_body_cannot_withdraw_the_current_review(env, review_decision_snapshot):
    client, _, auth = env
    client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": Phone().public})
    build_and_submit(auth)
    before = review_decision_snapshot(auth)
    assert client.post(f"{BASE}/previews/items_app/reject").status_code == 422
    assert review_decision_snapshot(auth) == before


def test_without_authoring_the_preview_routes_do_not_exist(tmp_path):
    app = FastAPI()
    mount(app, Store(tmp_path / "home"))
    client = TestClient(app)
    assert client.get(f"{BASE}/previews").status_code == 404
    assert client.get(f"{BASE}/health").json()["reviews"] is False


@pytest.mark.parametrize("member", ["bundle.json", "index.html"])
@pytest.mark.parametrize("damage", ["crc", "deflate", "lzma", "bzip2"])
def test_http_approval_rejects_damaged_archive_members_without_publishing(env, damage_bundle_member, member, damage):
    client, store, auth = env
    phone = Phone()
    client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": phone.public})
    build_and_submit(auth)
    path = auth._draft("items_app") / "review-bundle.zip"
    good = path.read_bytes()
    path.write_bytes(damage_bundle_member(good, member, damage))
    ch = client.post(f"{BASE}/previews/items_app/challenge").json()
    body = {"buildId": ch["buildId"], "nonce": ch["nonce"], "signature": phone.sign(ch["message"])}

    response = client.post(f"{BASE}/previews/items_app/approve", json=body)

    assert response.status_code == 400 and "review bundle rejected" in response.json()["error"]
    assert store._row("items_app")["revision"] == 0 and store.list_apps() == []
    assert len(client.get(f"{BASE}/previews").json()["previews"]) == 1
    path.write_bytes(good)
    assert client.post(f"{BASE}/previews/items_app/approve", json=body).status_code == 409  # nonce was consumed
    fresh = client.post(f"{BASE}/previews/items_app/challenge").json()
    approved = client.post(f"{BASE}/previews/items_app/approve", json={
        "buildId": fresh["buildId"], "nonce": fresh["nonce"], "signature": phone.sign(fresh["message"]),
    })
    assert approved.status_code == 200 and approved.json()["revision"] == 1


def test_http_approval_reports_published_when_metadata_finalization_is_pending(env, monkeypatch):
    client, store, auth = env
    phone = Phone()
    client.post(f"{BASE}/devices/pair", json={"deviceId": "ph1", "publicKey": phone.public})
    build_and_submit(auth)
    ch = client.post(f"{BASE}/previews/items_app/challenge").json()
    real_save = auth._save_state

    def fail_save(*args, **kwargs):
        raise OSError("synthetic metadata save failure")

    monkeypatch.setattr(auth, "_save_state", fail_save)
    response = client.post(f"{BASE}/previews/items_app/approve", json={
        "buildId": ch["buildId"], "nonce": ch["nonce"], "signature": phone.sign(ch["message"]),
    })
    assert response.status_code == 200
    assert response.json()["status"] == "published" and response.json()["finalizationPending"] is True
    manifest = client.get(f"{BASE}/apps/items_app").json()
    assert manifest["revision"] == 1 and manifest["bundle"]["bundleId"] == ch["bundleId"]
    assert client.get(f"{BASE}/previews").status_code == 409  # Authoring waits for repair; serving does not.
    monkeypatch.setattr(auth, "_save_state", real_save)
    assert client.get(f"{BASE}/previews").json()["previews"] == []
    assert auth.status("items_app")["baseRevision"] == 1 and store.get_manifest("items_app")["revision"] == 1
