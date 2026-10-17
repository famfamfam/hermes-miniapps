"""Deleting a published app (decided by the paired device, restorable from the trash) and the one-time
connection code that hands a phone its token. The phone is simulated with a real Ed25519 key."""
import base64
import json
import sqlite3
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from fastapi.testclient import TestClient

import ms_admin
from devserver import build_app
from mobile_surfaces_core import approval, bundle as B, pairing
from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.store import (
    ApprovalRefused, Conflict, NotFound, Store, StoreError, TooManyAttempts,
)

BASE = "/api/plugins/mobile-surfaces/v1"
TOKEN = "phone-token-for-tests-0123456789"
TEMPLATE = Path(__file__).resolve().parents[2] / "templates" / "starter-app"
DEFS = {"queries": {"items": {"sql": "SELECT id, title FROM items ORDER BY id", "shape": "rows"}}, "mutations": {}}


class Phone:
    def __init__(self) -> None:
        self.key = Ed25519PrivateKey.generate()
        raw = self.key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        self.public = base64.b64encode(raw).decode()

    def sign(self, message: str) -> str:
        return base64.b64encode(self.key.sign(message.encode())).decode()


def publish_items(store: Store, tmp_path: Path) -> None:
    store.create_app("items_app", "Список")
    store.agent_sql("items_app", "schema", "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL)")
    store.agent_sql("items_app", "write", "INSERT INTO items(title) VALUES (?)", params_list=[("Вода",), ("Газ",)])
    dist = tmp_path / f"dist-{uuid.uuid4().hex[:6]}"
    dist.mkdir()
    (dist / "index.html").write_text("<!doctype html><title>x</title>")
    built = B.build_bundle(dist, contract_hash=store.contract_hash(store.validate_definitions("items_app", DEFS)))
    store.publish("items_app", built, DEFS)


@pytest.fixture
def env(tmp_path):
    store = Store(tmp_path / "home")
    publish_items(store, tmp_path)
    phone = Phone()
    store.register_approver("phone1", phone.public)
    return store, Authoring(store, TEMPLATE), phone


def sign_delete(auth: Authoring, phone: Phone, app_id: str = "items_app") -> dict:
    ch = auth.delete_challenge(app_id)
    return {"nonce": ch["nonce"], "signature": phone.sign(ch["message"])}


# -- deleting -----------------------------------------------------------------


def test_a_signed_deletion_moves_the_app_to_the_trash(env):
    store, auth, phone = env
    etag = store.etag_for()
    assert auth.delete_app("items_app", **sign_delete(auth, phone)) == {"status": "deleted", "appId": "items_app"}

    assert store.list_apps() == [] and store.etag_for() != etag
    with pytest.raises(NotFound):
        store.get_manifest("items_app")
    [entry] = store.trash_list()
    assert entry["appId"] == "items_app" and entry["title"] == "Список"
    slot = store.root / "trash" / entry["name"]
    assert (slot / "app" / "data.db").is_file() and not (store.root / "apps" / "items_app").exists()
    types = [e["type"] for e in store.events_since(0, store.epoch())["events"]]
    assert "app.deleted" in types and types.count("registry.changed") >= 2  # publish announced it, so did the deletion


def test_the_trash_brings_the_app_back_with_its_data_and_revision(env):
    store, auth, phone = env
    revision = store._row("items_app")["revision"]
    auth.delete_app("items_app", **sign_delete(auth, phone))
    [entry] = store.trash_list()

    assert store.trash_restore(entry["name"]) == "items_app"

    assert [(a["appId"], a["revision"]) for a in store.list_apps()] == [("items_app", revision)]
    rows = store.agent_sql("items_app", "read", "SELECT title FROM items ORDER BY id")
    assert [r[0] for r in rows["rows"]] == ["Вода", "Газ"]
    assert store.trash_list() == []
    store.bundle_path("items_app", store._row("items_app")["bundle_id"])  # the bundle file is back too


def test_restoring_is_refused_when_the_id_is_taken_and_the_entry_survives(env, tmp_path):
    store, auth, phone = env
    auth.delete_app("items_app", **sign_delete(auth, phone))
    store.create_app("items_app", "Другой")
    [entry] = store.trash_list()
    with pytest.raises(Conflict):
        store.trash_restore(entry["name"])
    assert [e["name"] for e in store.trash_list()] == [entry["name"]]
    with pytest.raises(NotFound):
        store.trash_restore("items_app-20260101T000000Z-zzzz")
    with pytest.raises(NotFound):
        store.trash_restore("../../etc")


def test_garbage_and_foreign_signatures_delete_nothing(env):
    store, auth, phone = env
    other = Phone()
    for sign in (lambda m: "AAAA", lambda m: other.sign(m), lambda m: ""):
        ch = auth.delete_challenge("items_app")
        with pytest.raises(ApprovalRefused):
            auth.delete_app("items_app", nonce=ch["nonce"], signature=sign(ch["message"]))
    assert [a["appId"] for a in store.list_apps()] == ["items_app"] and store.trash_list() == []


def test_a_challenge_can_be_used_once(env):
    store, auth, phone = env
    ch = auth.delete_challenge("items_app")
    with pytest.raises(ApprovalRefused):
        auth.delete_app("items_app", nonce=ch["nonce"], signature="AAAA")
    with pytest.raises(Conflict, match="expired"):  # the failed try spent it
        auth.delete_app("items_app", nonce=ch["nonce"], signature=phone.sign(ch["message"]))
    assert [a["appId"] for a in store.list_apps()] == ["items_app"]


def test_a_publication_signature_cannot_delete_and_a_publication_nonce_is_not_accepted(env):
    store, auth, phone = env
    row = store._row("items_app")
    ch = auth.delete_challenge("items_app")
    # the same nonce, but the message a publication would sign
    publish_style = approval.canonical_message("items_app", "build_x", row["revision"], row["bundle_id"], 0, ch["nonce"])
    with pytest.raises(ApprovalRefused):
        auth.delete_app("items_app", nonce=ch["nonce"], signature=phone.sign(publish_style))
    # a nonce issued for a publication, with a correct deletion signature
    nonce = store.issue_nonce("items_app", "build_x", row["revision"])
    message = approval.canonical_delete_message("items_app", row["revision"], row["bundle_id"], nonce)
    with pytest.raises(Conflict, match="different build"):
        auth.delete_app("items_app", nonce=nonce, signature=phone.sign(message))
    assert approval.canonical_delete_message("a", 1, "b", "n").startswith("ms-delete-v1\n")
    assert [a["appId"] for a in store.list_apps()] == ["items_app"]


def test_a_signature_for_an_older_revision_does_not_delete_the_newer_one(env, tmp_path):
    store, auth, phone = env
    signed = sign_delete(auth, phone)
    dist = tmp_path / "dist2"
    dist.mkdir()
    (dist / "index.html").write_text("<!doctype html><title>y</title>")
    store.publish("items_app", B.build_bundle(dist, contract_hash=store.contract_hash(store.validate_definitions("items_app", DEFS))), DEFS)
    with pytest.raises(Conflict):
        auth.delete_app("items_app", **signed)
    assert [a["appId"] for a in store.list_apps()] == ["items_app"]


def test_without_a_paired_device_or_for_an_unpublished_app_there_is_no_challenge(tmp_path):
    store = Store(tmp_path / "home")
    publish_items(store, tmp_path)
    auth = Authoring(store, TEMPLATE)
    with pytest.raises(StoreError, match="paired"):
        auth.delete_challenge("items_app")
    store.register_approver("phone1", Phone().public)
    store.create_app("draft_only", "Черновик")
    with pytest.raises(NotFound, match="not published"):
        auth.delete_challenge("draft_only")
    with pytest.raises(NotFound):
        auth.delete_challenge("nothing_here")


def test_an_open_preview_blocks_deletion(env):
    store, auth, phone = env
    auth.write("items_app", "definitions.json", json.dumps(DEFS))
    rev = auth.status("items_app")["draftRev"]
    dist = auth._draft("items_app") / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    (dist / "index.html").write_text("<!doctype html><title>z</title>")
    (auth._draft("items_app") / "build.json").write_text(json.dumps(
        {"ok": True, "draftRev": rev, "at": "2026-10-12T00:00:00Z", "size": 40, "buildId": "build_abc123"}))
    assert auth.publish("items_app")["status"] == "awaiting_review"
    with pytest.raises(Conflict, match="preview"):
        auth.delete_challenge("items_app")


def test_a_linked_apps_source_file_is_never_touched(tmp_path):
    store = Store(tmp_path / "home")
    source = tmp_path / "foreign.db"
    conn = sqlite3.connect(source)
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)")
    conn.execute("INSERT INTO t(v) VALUES ('keep me')")
    conn.commit()
    conn.close()
    before = source.read_bytes()
    store.link_source("foreign", "Чужая база", source)

    name = store.delete_app("foreign")

    assert source.read_bytes() == before
    assert store.all_apps() == []
    store.trash_restore(name)
    assert store.all_apps()[0]["linked"] is True and source.read_bytes() == before


def test_the_trash_is_purged_by_age_and_foreign_names_are_left_alone(env):
    store, auth, phone = env
    auth.delete_app("items_app", **sign_delete(auth, phone))
    (store.root / "trash" / "keep-this-folder").mkdir()
    assert store.trash_purge(30) == 0 and len(store.trash_list()) == 1
    later = datetime.now(timezone.utc) + timedelta(days=31)
    assert store.trash_purge(30, now=later) == 1
    assert store.trash_list() == [] and (store.root / "trash" / "keep-this-folder").is_dir()


def test_the_event_poll_survives_an_app_that_vanished_mid_sweep(env):
    store, auth, phone = env
    auth.delete_app("items_app", **sign_delete(auth, phone))
    assert store.events_since(0, store.epoch())["reset"] is False


# -- connection codes ---------------------------------------------------------


def test_a_code_works_once_and_only_its_digest_is_stored(tmp_path):
    store = Store(tmp_path / "home")
    code = store.issue_pair_code()
    conn = sqlite3.connect(store.root / "registry.db")
    stored = [r[0] for r in conn.execute("SELECT code_hash FROM pair_codes")]
    conn.close()
    assert code not in stored and len(stored) == 1 and len(code) >= 22
    store.consume_pair_code(code)
    with pytest.raises(StoreError, match="wrong or has expired"):
        store.consume_pair_code(code)


def test_an_expired_unknown_or_malformed_code_all_read_the_same(tmp_path):
    store = Store(tmp_path / "home")
    expired = store.issue_pair_code(ttl_s=-1)
    messages = set()
    for bad in (expired, "no-such-code", "", None, "x" * 500):
        with pytest.raises(StoreError) as caught:
            store.consume_pair_code(bad)
        messages.add(str(caught.value))
    assert messages == {"the connection code is wrong or has expired"}


def test_repeated_misses_lock_every_attempt_for_a_while(tmp_path):
    store = Store(tmp_path / "home")
    good = store.issue_pair_code()
    for _ in range(5):
        with pytest.raises(StoreError):
            store.consume_pair_code("nope")
    with pytest.raises(TooManyAttempts):
        store.consume_pair_code(good)  # even the right code waits
    store._claim_locked_until = 0.0
    store.consume_pair_code(good)


@pytest.fixture
def served(tmp_path):
    home = tmp_path / "home"
    app = build_app(home, TOKEN, serve_mcp=False, make_authoring=lambda s: Authoring(s, TEMPLATE))
    client = TestClient(app)
    return client, Store(home)


AUTH = {"Authorization": f"Bearer {TOKEN}"}


def mint(client) -> str:
    out = client.post(f"{BASE}/admin/pair-code", headers=AUTH)
    assert out.status_code == 200 and out.json()["expiresIn"] == 900
    return out.json()["code"]


def test_minting_needs_the_token_but_claiming_does_not(served):
    client, store = served
    assert client.post(f"{BASE}/admin/pair-code").status_code == 401
    assert client.get(f"{BASE}/health").status_code == 401
    code = mint(client)
    phone = Phone()

    out = client.post(f"{BASE}/devices/claim", json={"code": code, "deviceId": "phone-ab12", "publicKey": phone.public})

    assert out.status_code == 200 and out.json() == {"token": TOKEN, "approverPaired": True}
    assert store.approver_count() == 1 and store.approver_keys() == [phone.public]
    assert client.get(f"{BASE}/health", headers=AUTH).json()["approverPaired"] is True
    again = client.post(f"{BASE}/devices/claim", json={"code": code, "deviceId": "phone-ab12", "publicKey": phone.public})
    assert again.status_code == 400  # spent


def test_a_second_phone_gets_the_token_but_cannot_replace_the_approver(served):
    client, store = served
    first, second = Phone(), Phone()
    client.post(f"{BASE}/devices/claim", json={"code": mint(client), "deviceId": "one", "publicKey": first.public})
    out = client.post(f"{BASE}/devices/claim", json={"code": mint(client), "deviceId": "two", "publicKey": second.public})
    assert out.json() == {"token": TOKEN, "approverPaired": False}
    assert store.approver_keys() == [first.public]
    same = client.post(f"{BASE}/devices/claim", json={"code": mint(client), "deviceId": "one", "publicKey": first.public})
    assert same.json()["approverPaired"] is True  # the same phone pairing again is fine


def test_a_mistyped_key_does_not_burn_the_code(served):
    client, store = served
    code = mint(client)
    bad = client.post(f"{BASE}/devices/claim", json={"code": code, "deviceId": "ph", "publicKey": "not-base64!"})
    assert bad.status_code == 400
    good = client.post(f"{BASE}/devices/claim", json={"code": code, "deviceId": "ph", "publicKey": Phone().public})
    assert good.status_code == 200


def test_the_claim_route_locks_after_repeated_misses(served):
    client, store = served
    code = mint(client)
    body = {"deviceId": "ph", "publicKey": Phone().public}
    for _ in range(5):
        assert client.post(f"{BASE}/devices/claim", json={**body, "code": "wrong"}).status_code == 400
    assert client.post(f"{BASE}/devices/claim", json={**body, "code": code}).status_code == 429


def test_health_announces_deletion_and_codes(served):
    client, _ = served
    health = client.get(f"{BASE}/health", headers=AUTH).json()
    assert health["appDelete"] is True and health["pairCode"] is True


def test_deleting_over_http(served, tmp_path):
    client, store = served
    publish_items(store, tmp_path)
    phone = Phone()
    client.post(f"{BASE}/devices/claim", json={"code": mint(client), "deviceId": "ph", "publicKey": phone.public})
    ch = client.post(f"{BASE}/apps/items_app/delete/challenge", headers=AUTH).json()
    assert ch["message"] == approval.canonical_delete_message("items_app", ch["revision"], ch["bundleId"], ch["nonce"])
    refused = client.post(f"{BASE}/apps/items_app/delete", headers=AUTH, json={"nonce": ch["nonce"], "signature": "AAAA"})
    assert refused.status_code == 422
    ch = client.post(f"{BASE}/apps/items_app/delete/challenge", headers=AUTH).json()
    done = client.post(f"{BASE}/apps/items_app/delete", headers=AUTH,
                       json={"nonce": ch["nonce"], "signature": phone.sign(ch["message"])})
    assert done.status_code == 200 and done.json()["status"] == "deleted"
    assert client.get(f"{BASE}/apps", headers=AUTH).json()["apps"] == []
    assert client.post(f"{BASE}/apps/items_app/delete/challenge", headers=AUTH).status_code == 404


# -- the string and the admin commands ------------------------------------------


def test_the_line_is_not_taken_for_a_jwt_by_the_agents_output_masking():
    # Hermes masks anything containing `eyJ` (a JWT) in terminal output; the first agent run on a real host spent
    # 267 s and 350k tokens working around that. Whatever the address and code, the line must not contain it.
    import random

    rng = random.Random(7)
    alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"
    for _ in range(2000):
        url = "https://" + "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789.-") for _ in range(rng.randint(3, 30))) + "/" + \
            "".join(rng.choice(alphabet) for _ in range(rng.randint(0, 40))) + "/ms"
        code = "".join(rng.choice(alphabet) for _ in range(22))
        text = pairing.encode(url, code)
        assert "eyJ" not in text, text
        assert pairing.decode(text) == (url, code)
    assert pairing.encode("https://h.example/ms", "A" * 22).startswith("HAP1.eyAi")
    # lines made before this change (no space after the brace) are still read
    old = "HAP1." + base64.urlsafe_b64encode(json.dumps({"u": "https://h.example/ms", "c": "A" * 22}, separators=(",", ":")).encode()).decode().rstrip("=")
    assert old.startswith("HAP1.eyJ") and pairing.decode(old) == ("https://h.example/ms", "A" * 22)


def test_the_connection_string_round_trips_and_rejects_damage():
    text = pairing.encode("https://host.example:8443/secretpath/ms/", "A" * 22)
    assert text.startswith("HAP1.") and "=" not in text and " " not in text
    assert pairing.decode(f"  {text}\n") == ("https://host.example:8443/secretpath/ms", "A" * 22)
    for bad in ("", "hello", "HAP1.", "HAP1.@@@", "HAP2." + text[5:], "HAP1." + base64.urlsafe_b64encode(b"[]").decode()):
        with pytest.raises(pairing.ConnectionStringError):
            pairing.decode(bad)
    for url in ("ftp://h/ms", "https://u:p@h/ms", "https://h/ms?x=1", "https://h/ms#f", "not a url"):
        with pytest.raises(pairing.ConnectionStringError):
            pairing.encode(url, "A" * 22)
    with pytest.raises(pairing.ConnectionStringError):
        pairing.encode("https://h/ms", "short")


class _FakeResponse:
    def __init__(self, body):
        self._body = json.dumps(body).encode()

    def read(self, *args):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@pytest.fixture
def service_stub(monkeypatch):
    """Stands in for the running service: records the request, answers like /admin/pair-code."""
    seen = []

    def fake_urlopen(request, timeout=0):
        seen.append(request)
        return _FakeResponse({"code": "Q" * 22, "expiresIn": 900})

    monkeypatch.setattr(ms_admin.urllib.request, "urlopen", fake_urlopen)
    monkeypatch.delenv("MOBILE_SURFACES_PUBLIC_URL", raising=False)
    return seen


def _line_url(capsys) -> str:
    return pairing.decode(capsys.readouterr().out.strip())[0]


def test_the_address_comes_from_the_option_then_the_environment_then_the_file_beside_the_token(tmp_path, capsys, monkeypatch, service_stub):
    tokens = tmp_path / "etc"
    tokens.mkdir()
    token_file = tokens / "api-token"
    token_file.write_text("t" * 32)
    (tokens / "public-url").write_text("https://from-file.example/pfx/ms\n")
    args = ["pair-code", "--token-file", str(token_file), "--api-url", "http://127.0.0.1:18787"]

    assert ms_admin.main(args) == 0
    assert _line_url(capsys) == "https://from-file.example/pfx/ms"
    monkeypatch.setenv("MOBILE_SURFACES_PUBLIC_URL", "https://from-env.example/ms")
    assert ms_admin.main(args) == 0
    assert _line_url(capsys) == "https://from-env.example/ms"
    assert ms_admin.main([*args, "--public-url", "https://given.example/ms"]) == 0
    assert _line_url(capsys) == "https://given.example/ms"
    # every request went to the port named, with the token as bearer
    assert {r.full_url for r in service_stub} == {"http://127.0.0.1:18787/api/plugins/mobile-surfaces/v1/admin/pair-code"}
    assert {r.get_header("Authorization") for r in service_stub} == {"Bearer " + "t" * 32}


def test_without_any_address_nothing_is_asked_of_the_service_and_the_reason_is_clear(tmp_path, capsys, service_stub):
    token_file = tmp_path / "api-token"
    token_file.write_text("t" * 32)
    assert ms_admin.main(["pair-code", "--token-file", str(token_file)]) == 2
    captured = capsys.readouterr()
    assert captured.out == "" and "public-url" in captured.err
    assert service_stub == [], "a code must not be issued (and spent from the budget of attempts) for a line that cannot be built"
    (tmp_path / "public-url").write_text("   \n")  # an empty file is no address either
    assert ms_admin.main(["pair-code", "--token-file", str(token_file)]) == 2
    assert service_stub == []


def test_a_bad_address_in_the_file_is_reported_without_printing_a_line(tmp_path, capsys, service_stub):
    token_file = tmp_path / "api-token"
    token_file.write_text("t" * 32)
    (tmp_path / "public-url").write_text("ftp://not-usable/ms\n")
    assert ms_admin.main(["pair-code", "--token-file", str(token_file)]) == 1
    captured = capsys.readouterr()
    assert captured.out == "" and "http(s) URL" in captured.err


def test_the_admin_commands_issue_a_code_and_manage_the_trash(env, tmp_path, capsys):
    store, auth, phone = env
    home = str(store.root.parent)
    assert ms_admin.main(["--home", home, "pair-code", "--public-url", "https://h.example/ms"]) == 0
    text = capsys.readouterr().out.strip()
    url, code = pairing.decode(text)
    assert url == "https://h.example/ms"
    store.consume_pair_code(code)

    assert ms_admin.main(["--home", home, "delete-app", "items_app"]) == 0
    capsys.readouterr()
    [entry] = store.trash_list()
    assert ms_admin.main(["--home", home, "trash"]) == 0
    assert entry["name"] in capsys.readouterr().out
    assert ms_admin.main(["--home", home, "restore-app", entry["name"]]) == 0
    assert [a["appId"] for a in store.list_apps()] == ["items_app"]
    assert ms_admin.main(["--home", home, "purge-trash", "--days", "30"]) == 0
    assert ms_admin.main(["--home", home, "restore-app", "items_app-20260101T000000Z-aaaa"]) == 1
