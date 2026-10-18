"""Review and device approval (ADR-007 §5): publishing is decided by a signature only the phone can make.

No Node here: a successful build is written to disk directly, since review does not care how the
bundle input was produced, only that it is the build of exactly the current draft.
"""
import base64
import json
import shutil
import threading
import uuid
from pathlib import Path

import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from mobile_surfaces_core import approval, authoring as A, bundle
from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.builder import BuildResult
from mobile_surfaces_core.store import Conflict, ApprovalRefused, NotFound, Store, StoreError

TEMPLATE = Path(__file__).resolve().parents[2] / "templates" / "starter-app"
DEFS = {"queries": {"items": {"sql": "SELECT id, title, amount FROM items ORDER BY id", "shape": "rows"}},
        "mutations": {}}


class Phone:
    """What the Flutter host does: holds the private key, signs exactly what the server asked for."""

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
    store.agent_sql("items_app", "write", "INSERT INTO items(title, amount) VALUES (?,?)",
                    params_list=[("Вода", 119000), ("Газ", 79000)])
    return store, Authoring(store, TEMPLATE)


def fake_build(auth: Authoring, app_id: str = "items_app") -> str:
    """Leave the draft in the state a successful app_build would."""
    auth.write(app_id, "definitions.json", json.dumps(DEFS))
    rev = auth.status(app_id)["draftRev"]
    dist = auth._draft(app_id) / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    (dist / "index.html").write_text("<!doctype html><title>x</title>")
    build_id = "build_" + uuid.uuid4().hex[:10]
    (auth._draft(app_id) / "build.json").write_text(
        json.dumps({"ok": True, "draftRev": rev, "at": "2026-10-12T00:00:00Z", "size": 40, "buildId": build_id}))
    return build_id


def ask_and_sign(auth: Authoring, phone: Phone, app_id: str = "items_app") -> dict:
    ch = auth.challenge(app_id)
    return {"build_id": ch["buildId"], "nonce": ch["nonce"], "signature": phone.sign(ch["message"])}


def test_without_a_paired_device_publish_publishes(env):
    store, auth = env
    fake_build(auth)
    out = auth.publish("items_app")
    assert out["status"] == "published" and out["revision"] == 1
    assert [a["appId"] for a in store.list_apps()] == ["items_app"]


def test_with_a_paired_device_publish_only_submits(env):
    store, auth = env
    store.register_approver("phone1", Phone().public)
    build_id = fake_build(auth)

    out = auth.publish("items_app")

    assert out["status"] == "awaiting_review" and out["buildId"] == build_id
    assert store.list_apps() == []  # nothing changed for anyone
    [review] = auth.reviews()
    assert (review["appId"], review["buildId"], review["isNew"]) == ("items_app", build_id, True)
    assert auth.status("items_app")["review"]["status"] == "awaiting_review"


def test_preview_serves_the_draft_bundle_and_runs_its_queries(env):
    store, auth = env
    store.register_approver("phone1", Phone().public)
    fake_build(auth)
    auth.publish("items_app")

    manifest = auth.review_manifest("items_app")
    assert manifest["revision"] == auth.status("items_app")["draftRev"]
    assert manifest["queries"]["items"]["columns"] == ["id", "title", "amount"]
    assert manifest["preview"]["isNew"] is True and manifest["mutations"] == {}
    bundle = auth.review_bundle_path("items_app", manifest["bundle"]["bundleId"]).read_bytes()
    assert len(bundle) == manifest["bundle"]["size"]
    out = auth.review_query("items_app", manifest["revision"], [{"name": "items"}], device_id="t", tz_name=None)
    assert [r["title"] for r in out["results"]["items"]["data"]] == ["Вода", "Газ"]
    with pytest.raises(Conflict, match="stale"):
        auth.review_query("items_app", manifest["revision"] + 1, [{"name": "items"}], device_id="t", tz_name=None)
    with pytest.raises(NotFound):
        auth.review_bundle_path("items_app", "sha256:" + "0" * 64)


def test_the_preview_tells_the_phone_which_buttons_write_without_the_sql(env, monkeypatch):
    store, auth = env
    monkeypatch.setitem(DEFS, "mutations", {
        "set_amount": {"sql": "UPDATE items SET amount = :amount WHERE id = :id", "label": "Change the amount",
                       "params": {"id": {"type": "integer"}, "amount": {"type": "integer"}}},
        "drop": {"sql": "DELETE FROM items WHERE id = :id", "params": {"id": {"type": "integer"}}, "confirm": True},
    })
    store.register_approver("phone1", Phone().public)
    fake_build(auth)
    auth.publish("items_app")

    manifest = auth.review_manifest("items_app")

    assert manifest["mutations"] == {
        "set_amount": {"params": {"id": {"type": "integer"}, "amount": {"type": "integer"}}, "destructive": False,
                       "label": "Change the amount"},
        "drop": {"params": {"id": {"type": "integer"}}, "destructive": True, "confirm": True},
    }
    assert "UPDATE" not in json.dumps(manifest) and "DELETE" not in json.dumps(manifest)


def test_an_app_with_buttons_that_write_can_be_approved_and_its_buttons_then_work(env, monkeypatch):
    # Approval publishes the saved review, whose contract is the NORMALISED one (it carries `destructive`, computed
    # from the SQL); publishing validates it again, so validation has to accept its own output.
    store, auth = env
    monkeypatch.setitem(DEFS, "mutations", {
        "set_amount": {"sql": "UPDATE items SET amount = :amount WHERE id = :id", "label": "Change the amount",
                       "params": {"id": {"type": "integer"}, "amount": {"type": "integer"}}},
        "drop": {"sql": "DELETE FROM items WHERE id = :id", "params": {"id": {"type": "integer"}}, "confirm": True},
        "bump_and_log": {"statements": ["UPDATE items SET amount = amount + 1 WHERE id = :id",
                                        "INSERT INTO items(title, amount) VALUES ('log', 1)"],
                         "params": {"id": {"type": "integer"}}, "label": "Bump and log"},
    })
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")

    out = auth.approve("items_app", **ask_and_sign(auth, phone))

    assert out["status"] == "published" and out["revision"] == 1
    published = json.loads(store._row("items_app")["definitions"])
    assert [published["mutations"][n]["destructive"] for n in ("set_amount", "drop", "bump_and_log")] == [False, True, False]
    assert store.validate_definitions("items_app", published) == published  # validation accepts its own output
    key = lambda n: f"approved-key-{n:08d}"
    assert store.run_mutation("items_app", 1, "set_amount", {"id": 1, "amount": 5}, key=key(1), device_id="t", tz_name=None)["rowsAffected"] == 1
    assert store.run_mutation("items_app", 1, "bump_and_log", {"id": 2}, key=key(2), device_id="t", tz_name=None)["rowsAffected"] == 2
    assert store.run_mutation("items_app", 1, "drop", {"id": 1}, key=key(3), device_id="t", tz_name=None)["rowsAffected"] == 1


def test_a_valid_signature_publishes_exactly_the_reviewed_build(env):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    build_id = fake_build(auth)
    auth.publish("items_app")
    reviewed = auth.review_manifest("items_app")
    reviewed_id = reviewed["bundle"]["bundleId"]
    reviewed_bytes = auth.review_bundle_path("items_app", reviewed_id).read_bytes()
    reviewed_defs = auth._require_review("items_app")["definitions"]

    out = auth.approve("items_app", **ask_and_sign(auth, phone))

    assert out["status"] == "published" and out["revision"] == 1
    assert store.get_manifest("items_app")["bundle"]["bundleId"] == out["bundleId"] == reviewed_id
    assert store.bundle_path("items_app", reviewed_id).read_bytes() == reviewed_bytes
    assert json.loads(store._row("items_app")["definitions"]) == reviewed_defs
    assert auth.reviews() == []
    with pytest.raises(NotFound):  # the review is consumed
        auth.approve("items_app", build_id=build_id, nonce="x", signature="y")


@pytest.mark.parametrize("rebuild", ["changed", "removed", "successful", "failed"])
def test_approval_uses_the_saved_review_not_a_later_unsent_build(env, rebuild):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    reviewed_id = auth.review_manifest("items_app")["bundle"]["bundleId"]
    reviewed_bytes = auth.review_bundle_path("items_app", reviewed_id).read_bytes()
    signed = ask_and_sign(auth, phone)
    dist = auth._draft("items_app") / "dist"
    if rebuild == "removed":
        shutil.rmtree(dist)
    else:
        (dist / "index.html").write_text("<!doctype html><title>unsent replacement</title>")
        if rebuild in ("successful", "failed"):
            record = auth._build_record("items_app")
            record.update(ok=rebuild == "successful", buildId="build_unsent")
            (auth._draft("items_app") / "build.json").write_text(json.dumps(record))

    out = auth.approve("items_app", **signed)

    assert out["bundleId"] == reviewed_id
    assert store.bundle_path("items_app", reviewed_id).read_bytes() == reviewed_bytes


@pytest.mark.parametrize("damage", ["missing", "corrupt", "other_bundle", "contract"])
def test_damaged_review_fails_closed_without_publishing(env, damage):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    path = auth._draft("items_app") / "review-bundle.zip"
    if damage == "missing":
        path.unlink()
    elif damage == "corrupt":
        path.write_bytes(b"not a zip")
    elif damage == "other_bundle":
        dist = auth._draft("items_app") / "dist"
        (dist / "index.html").write_text("<!doctype html><title>other bundle</title>")
        path.write_bytes(bundle.build_bundle(dist).data)
    else:
        info = auth._require_review("items_app")
        info["definitions"]["queries"]["items"]["sql"] = "SELECT id FROM items"
        (auth._draft("items_app") / "review.json").write_text(json.dumps(info))

    with pytest.raises(StoreError, match="review|contract"):
        auth.approve("items_app", **ask_and_sign(auth, phone))
    assert store.list_apps() == []
    assert store._row("items_app")["revision"] == 0


def test_schema_drift_cannot_change_the_signed_query_contract(env):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.write("items_app", "definitions.json", json.dumps({
        "queries": {"items": {"sql": "SELECT * FROM items", "shape": "rows"}}, "mutations": {},
    }))
    record = auth._build_record("items_app")
    record["draftRev"] = auth.status("items_app")["draftRev"]
    (auth._draft("items_app") / "build.json").write_text(json.dumps(record))
    auth.publish("items_app")
    signed = ask_and_sign(auth, phone)
    store.agent_sql("items_app", "schema", "ALTER TABLE items ADD COLUMN note TEXT")

    with pytest.raises(StoreError, match="contract"):
        auth.approve("items_app", **signed)
    assert store.list_apps() == []


def test_data_only_changes_do_not_invalidate_the_review(env):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    reviewed_id = auth.review_manifest("items_app")["bundle"]["bundleId"]
    signed = ask_and_sign(auth, phone)
    store.agent_sql("items_app", "write", "UPDATE items SET amount = amount + 1")
    assert auth.approve("items_app", **signed)["bundleId"] == reviewed_id


def test_inflight_build_cannot_replace_the_artifact_being_approved(env):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    reviewed_id = auth.review_manifest("items_app")["bundle"]["bundleId"]
    signed = ask_and_sign(auth, phone)
    output_written, finish = threading.Event(), threading.Event()
    errors = []

    class PausedBuilder:
        def build(self, files, definitions, out_dir):
            (out_dir / "index.html").write_text("<!doctype html><title>inflight replacement</title>")
            output_written.set()
            assert finish.wait(10), "test did not release the builder"
            return BuildResult(True, "done", dist_dir=out_dir, size=60)

    auth.builder = PausedBuilder()

    def build():
        try:
            auth.build("items_app")
        except BaseException as exc:
            errors.append(exc)

    worker = threading.Thread(target=build)
    worker.start()
    try:
        assert output_written.wait(10), "builder did not reach the output switch"
        assert auth.approve("items_app", **signed)["bundleId"] == reviewed_id
    finally:
        finish.set()
        worker.join(10)
    assert not worker.is_alive() and errors == []


def test_a_signature_from_another_key_or_garbage_is_refused_and_nothing_is_published(env):
    store, auth = env
    store.register_approver("phone1", Phone().public)
    fake_build(auth)
    auth.publish("items_app")
    stranger = Phone()  # e.g. a key a process on the server generated for itself

    with pytest.raises(ApprovalRefused):
        auth.approve("items_app", **ask_and_sign(auth, stranger))
    ch = auth.challenge("items_app")
    with pytest.raises(ApprovalRefused):
        auth.approve("items_app", build_id=ch["buildId"], nonce=ch["nonce"], signature="not-a-signature")
    assert store.list_apps() == []
    assert len(auth.reviews()) == 1  # still waiting for the real approval


def test_the_phone_api_token_alone_cannot_approve(env):
    """Everything the server holds (tokens, files) is useless: only a signature publishes."""
    store, auth = env
    store.register_approver("phone1", Phone().public)
    fake_build(auth)
    auth.publish("items_app")
    ch = auth.challenge("items_app")
    for signature in ("", "AAAA", base64.b64encode(b"x" * 64).decode()):
        with pytest.raises(ApprovalRefused):
            auth.approve("items_app", build_id=ch["buildId"], nonce=auth.challenge("items_app")["nonce"], signature=signature)
    assert store.list_apps() == []


def test_a_signature_cannot_be_replayed(env):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    ask = ask_and_sign(auth, phone)
    auth.approve("items_app", **ask)
    # A new draft for the same app, then the old (valid) approval is presented again.
    fake_build(auth)
    auth.publish("items_app")
    with pytest.raises(Conflict, match="changed|expired|different build"):
        auth.approve("items_app", **ask)
    assert store.get_manifest("items_app")["revision"] == 1  # still only the first publication


def test_an_approval_signed_for_one_build_does_not_publish_another(env):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    old = ask_and_sign(auth, phone)
    # The author rebuilds and resubmits while the user is looking at the first one.
    new_build = fake_build(auth)
    auth.publish("items_app")
    with pytest.raises(Conflict):
        auth.approve("items_app", **old)
    assert auth.reviews()[0]["buildId"] == new_build
    assert store.list_apps() == []


def test_the_challenge_expires(env):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    ch = auth.challenge("items_app")
    store.issue_nonce  # (api exists)
    import sqlite3
    conn = sqlite3.connect(store.root / "registry.db")
    conn.execute("UPDATE approval_nonces SET expires_at = 0")
    conn.commit()
    conn.close()
    with pytest.raises(Conflict, match="expired"):
        auth.approve("items_app", build_id=ch["buildId"], nonce=ch["nonce"], signature=phone.sign(ch["message"]))


def test_editing_after_submission_withdraws_the_review(env):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    ask = ask_and_sign(auth, phone)
    auth.write("items_app", "src/styles.css", ".a { color: red; }\n")
    assert auth.reviews() == [] and auth.status("items_app")["review"] is None
    with pytest.raises(NotFound):
        auth.approve("items_app", **ask)


def test_reject_removes_the_review_and_keeps_the_draft(env):
    store, auth = env
    store.register_approver("phone1", Phone().public)
    fake_build(auth)
    auth.publish("items_app")
    assert auth.reject("items_app") == {"status": "rejected"}
    assert auth.reviews() == []
    assert auth.status("items_app")["files"]  # the draft is still there to be fixed
    with pytest.raises(NotFound):
        auth.reject("items_app")


def test_rejection_of_a_displayed_build_cannot_withdraw_its_replacement(env, review_decision_snapshot):
    store, auth = env
    store.register_approver("phone1", Phone().public)
    fake_build(auth)
    auth.publish("items_app")
    displayed = auth.review_manifest("items_app")
    fake_build(auth)
    auth.publish("items_app")
    replacement = auth.review_manifest("items_app")
    # Even identical bundle bytes do not make two different submitted builds the same decision.
    assert displayed["bundle"] == replacement["bundle"]
    assert displayed["preview"]["buildId"] != replacement["preview"]["buildId"]
    before = review_decision_snapshot(auth)

    with pytest.raises(Conflict, match="build under review changed"):
        auth.reject("items_app", expected_build_id=displayed["preview"]["buildId"])

    assert review_decision_snapshot(auth) == before
    assert auth.reviews()[0]["buildId"] == replacement["preview"]["buildId"]
    assert auth.reject("items_app", expected_build_id=replacement["preview"]["buildId"]) == {"status": "rejected"}
    assert auth.reviews() == []
    with pytest.raises(NotFound):
        auth.reject("items_app", expected_build_id=replacement["preview"]["buildId"])


def test_exact_target_rejection_preserves_draft_and_emits_one_decision(env, review_decision_snapshot):
    store, auth = env
    store.register_approver("phone1", Phone().public)
    build_id = fake_build(auth)
    auth.publish("items_app")
    before = review_decision_snapshot(auth)

    assert auth.reject("items_app", expected_build_id=build_id) == {"status": "rejected"}

    after = review_decision_snapshot(auth)
    assert after["revision"] == before["revision"] == 0
    assert after["files"]["draft.json"] == before["files"]["draft.json"]
    assert after["files"]["build.json"] == before["files"]["build.json"]
    assert after["files"]["review.json"] is None and after["files"]["review-bundle.zip"] is None
    assert after["events"][:-1] == before["events"]
    event = after["events"][-1]
    assert event[2:4] == ("review.changed", "items_app") and json.loads(event[5]) == {"status": "rejected"}


def test_only_one_device_can_be_paired_and_keys_are_validated(env):
    store, _ = env
    first = Phone()
    store.register_approver("phone1", first.public)
    store.register_approver("phone1", first.public)  # idempotent
    with pytest.raises(Conflict):
        store.register_approver("phone2", Phone().public)
    with pytest.raises(Conflict):
        store.register_approver("phone1", Phone().public)
    with pytest.raises(StoreError, match="32-byte"):
        Store(store.root.parent / "other").register_approver("p", base64.b64encode(b"short").decode())
    with pytest.raises(StoreError, match="base64"):
        Store(store.root.parent / "other2").register_approver("p", "***")
    assert store.clear_approvers() == 1 and store.approver_count() == 0


def test_the_signed_message_names_everything_it_approves():
    message = approval.canonical_message("zhkh", "build_1", 7, "sha256:" + "a" * 64, 3, "n0nce")
    assert message.split("\n") == [
        "ms-approve-v1", "app:zhkh", "build:build_1", "draftRev:7", "bundle:sha256:" + "a" * 64, "base:3", "nonce:n0nce",
    ]
    assert not message.endswith("\n")


def test_review_survives_a_restart_of_the_process(env, tmp_path):
    store, auth = env
    phone = Phone()
    store.register_approver("phone1", phone.public)
    fake_build(auth)
    auth.publish("items_app")
    again = Authoring(Store(tmp_path / "home"), TEMPLATE)  # another process, same disk
    assert [r["appId"] for r in again.reviews()] == ["items_app"]
    out = again.approve("items_app", **ask_and_sign(again, phone))
    assert out["revision"] == 1


# -- publication finalization (synthetic builds, no Node) ----------------------------


def _source_files(store):
    root = store.app_dir("items_app") / "source"
    return {p.relative_to(root).as_posix(): p.read_bytes() for p in root.rglob("*") if p.is_file()}


def _prepare_update(store, auth, *, reviewed=True):
    fake_build(auth)
    previous = auth.publish("items_app")
    phone = Phone()
    if reviewed:
        store.register_approver("phone1", phone.public)
    auth.write("items_app", "src/screens.tsx", "export const published = 'frozen update';\n")
    fake_build(auth)
    (auth._draft("items_app") / "dist" / "index.html").write_text("<!doctype html><title>frozen update</title>")
    if reviewed:
        auth.publish("items_app")
    return previous, phone


@pytest.mark.parametrize("reviewed", [False, True])
def test_source_copy_failure_is_before_the_registry_commit_and_retry_keeps_the_review(env, monkeypatch, reviewed):
    store, auth = env
    previous, phone = _prepare_update(store, auth, reviewed=reviewed)
    old_sources = _source_files(store)
    real_copy = A.shutil.copytree
    copying = threading.Event()
    copying.set()

    def fail_copy(src, dst, *args, **kwargs):
        if Path(src) == auth._draft("items_app") / "files" and copying.is_set():
            Path(dst).mkdir(parents=True, exist_ok=True)
            (Path(dst) / "partial").write_text("unfinished copy")
            raise OSError("synthetic source copy failure")
        return real_copy(src, dst, *args, **kwargs)

    monkeypatch.setattr(A.shutil, "copytree", fail_copy)
    signed = ask_and_sign(auth, phone) if reviewed else None
    with pytest.raises(StoreError, match="prepare.*sources"):
        auth.approve("items_app", **signed) if reviewed else auth.publish("items_app")

    assert store.get_manifest("items_app")["revision"] == previous["revision"] == 1
    assert store.bundle_path("items_app", previous["bundleId"]).is_file()
    assert _source_files(store) == old_sources
    assert auth.status("items_app")["baseRevision"] == 1
    assert not (store.app_dir("items_app") / "pending-publication.json").exists()
    if reviewed:
        assert auth.reviews()[0]["buildId"] == signed["build_id"]
        with pytest.raises(Conflict, match="expired"):
            auth.approve("items_app", **signed)
    copying.clear()
    out = auth.approve("items_app", **ask_and_sign(auth, phone)) if reviewed else auth.publish("items_app")
    assert out["revision"] == 2 and auth.status("items_app")["baseRevision"] == 2


@pytest.mark.parametrize("failure", ["old_source_move", "new_source_move", "new_source_moved", "save", "review_cleanup", "emit", "journal_cleanup"])
def test_a_committed_approval_returns_published_and_restarts_finish_idempotently(env, monkeypatch, tmp_path, failure):
    store, auth = env
    previous, phone = _prepare_update(store, auth)
    reviewed = auth.review_manifest("items_app")
    reviewed_id = reviewed["bundle"]["bundleId"]
    reviewed_bytes = auth.review_bundle_path("items_app", reviewed_id).read_bytes()
    signed = ask_and_sign(auth, phone)
    blocked = threading.Event()
    blocked.set()
    root = store.app_dir("items_app")
    pending_path = root / "pending-publication.json"

    if failure in ("old_source_move", "new_source_move", "new_source_moved"):
        real_replace = A.os.replace

        def fail_move(src, dst):
            selected = Path(src) == root / ("source" if failure == "old_source_move" else "source.pending")
            if selected and blocked.is_set():
                if failure == "new_source_moved":
                    real_replace(src, dst)  # Crash/error just after the atomic directory move.
                raise OSError("synthetic directory move failure")
            return real_replace(src, dst)

        monkeypatch.setattr(A.os, "replace", fail_move)
    elif failure == "save":
        real_save = auth._save_state

        def fail_save(app_id, state):
            if blocked.is_set():
                raise OSError("synthetic metadata save failure")
            return real_save(app_id, state)

        monkeypatch.setattr(auth, "_save_state", fail_save)
    elif failure == "review_cleanup":
        real_withdraw = auth._withdraw_review

        def fail_cleanup(app_id, announce=True):
            if blocked.is_set():
                (auth._draft(app_id) / "review.json").unlink(missing_ok=True)
                raise OSError("synthetic partial review cleanup failure")
            return real_withdraw(app_id, announce)

        monkeypatch.setattr(auth, "_withdraw_review", fail_cleanup)
    elif failure == "emit":
        real_emit = store.emit

        def fail_emit(*args, **kwargs):
            if blocked.is_set():
                raise OSError("synthetic event append failure")
            return real_emit(*args, **kwargs)

        monkeypatch.setattr(store, "emit", fail_emit)
    else:
        real_unlink = Path.unlink

        def fail_unlink(path, *args, **kwargs):
            if path == pending_path and blocked.is_set():
                raise OSError("synthetic journal cleanup failure")
            return real_unlink(path, *args, **kwargs)

        monkeypatch.setattr(Path, "unlink", fail_unlink)

    out = auth.approve("items_app", **signed)

    assert out["status"] == "published" and out["revision"] == 2 and out["finalizationPending"] is True
    assert pending_path.is_file()
    assert store.get_manifest("items_app")["bundle"]["bundleId"] == out["bundleId"] == reviewed_id
    assert store.bundle_path("items_app", reviewed_id).read_bytes() == reviewed_bytes
    assert store.bundle_path("items_app", previous["bundleId"]).is_file()
    assert store.run_queries("items_app", 2, [{"name": "items"}], device_id="t", tz_name=None)["results"]["items"]["data"]
    # While repairs still fail, editing cannot work on a stale base or discard the journal.
    if failure != "new_source_moved":  # The first move already completed; retry needs no second move.
        with pytest.raises(Conflict, match="committed.*finalization"):
            auth.write("items_app", "src/screens.tsx", "must not enter the frozen publication")
    blocked.clear()

    again = Authoring(Store(tmp_path / "home"), TEMPLATE)
    assert again.reviews() == []  # Also recovers when review.json was already removed.
    assert again.status("items_app")["baseRevision"] == 2
    assert not pending_path.exists()
    assert not (root / "source.pending").exists() and not (root / "source.previous").exists()
    assert again.status("items_app")["baseRevision"] == 2 and store.get_manifest("items_app")["revision"] == 2
    with pytest.raises(NotFound):
        again.approve("items_app", **signed)
    again.reset("items_app")
    assert again.read("items_app", "src/screens.tsx")["content"] == "export const published = 'frozen update';\n"


@pytest.mark.parametrize("committed", [False, True])
def test_restart_reconciles_a_crash_at_store_publish_without_republishing(env, monkeypatch, tmp_path, committed):
    store, auth = env
    previous, phone = _prepare_update(store, auth)
    frozen_sources = auth._files("items_app")
    signed = ask_and_sign(auth, phone)
    real_publish = store.publish

    def crash(*args, **kwargs):
        if committed:
            real_publish(*args, **kwargs)
        raise SystemExit("synthetic process exit at registry boundary")

    monkeypatch.setattr(store, "publish", crash)
    with pytest.raises(SystemExit):
        auth.approve("items_app", **signed)
    root = store.app_dir("items_app")
    assert (root / "pending-publication.json").is_file() and (root / "source.pending").is_dir()
    if committed:
        # Recovery must use the already prepared snapshot, not copy the draft again.
        (auth._draft("items_app") / "files" / "src" / "screens.tsx").write_text("changed after the interruption")
    again = Authoring(Store(tmp_path / "home"), TEMPLATE)
    expected_revision = 2 if committed else 1
    assert again.status("items_app")["baseRevision"] == expected_revision
    assert store.get_manifest("items_app")["revision"] == expected_revision
    assert not (root / "pending-publication.json").exists() and not (root / "source.pending").exists()
    if committed:
        assert _source_files(store) == {name: text.encode() for name, text in frozen_sources.items()}
        assert again.reviews() == []
    else:
        assert store.get_manifest("items_app")["bundle"]["bundleId"] == previous["bundleId"]
        assert again.reviews()[0]["buildId"] == signed["build_id"]
        assert again.approve("items_app", **ask_and_sign(again, phone))["revision"] == 2


def test_an_exception_after_store_commit_is_reconciled_as_success(env, monkeypatch):
    store, auth = env
    _, phone = _prepare_update(store, auth)
    real_publish = store.publish

    def committed_then_error(*args, **kwargs):
        real_publish(*args, **kwargs)
        raise OSError("synthetic failure after the registry commit")

    monkeypatch.setattr(store, "publish", committed_then_error)
    out = auth.approve("items_app", **ask_and_sign(auth, phone))
    assert out["status"] == "published" and out["revision"] == 2
    assert auth.status("items_app")["baseRevision"] == 2 and auth.reviews() == []


@pytest.mark.parametrize("interrupted", [False, True])
def test_retrying_direct_publish_returns_the_saved_build_receipt_without_republishing(env, monkeypatch, tmp_path, interrupted):
    store, auth = env
    _prepare_update(store, auth, reviewed=False)
    if interrupted:
        def fail_save(*args, **kwargs):
            raise OSError("synthetic post-commit save failure")

        monkeypatch.setattr(auth, "_save_state", fail_save)
    first = auth.publish("items_app")
    assert first["revision"] == 2
    again = Authoring(Store(tmp_path / "home"), TEMPLATE)
    retry = again.publish("items_app")  # Recover first, then return this build's committed result.
    assert retry == {k: v for k, v in first.items() if k != "finalizationPending"}
    assert again.publish("items_app") == retry and store.get_manifest("items_app")["revision"] == 2
    fake_build(again)  # A genuinely new build is still publishable, even with identical content.
    assert again.publish("items_app")["revision"] == 3


@pytest.mark.parametrize("drift", ["revision", "bundle", "contract", "epoch"])
def test_pending_publication_refuses_unrelated_registry_identity(env, monkeypatch, tmp_path, drift):
    store, auth = env
    _, phone = _prepare_update(store, auth)

    def fail_save(*args, **kwargs):
        raise OSError("synthetic post-commit save failure")

    monkeypatch.setattr(auth, "_save_state", fail_save)
    assert auth.approve("items_app", **ask_and_sign(auth, phone))["finalizationPending"] is True
    root = store.app_dir("items_app")
    original_sources = _source_files(store)
    conn = store._registry()
    try:
        if drift == "epoch":
            conn.execute("UPDATE meta SET value = 'other_epoch' WHERE key = 'epoch'")
        elif drift == "revision":
            conn.execute("UPDATE apps SET revision = revision + 1 WHERE app_id = 'items_app'")
        elif drift == "bundle":
            conn.execute("UPDATE apps SET bundle_id = ? WHERE app_id = 'items_app'", ("sha256:" + "0" * 64,))
        else:
            conn.execute("UPDATE apps SET definitions = ? WHERE app_id = 'items_app'", (json.dumps({"queries": {}, "mutations": {}}),))
    finally:
        conn.close()
    again = Authoring(Store(tmp_path / "home"), TEMPLATE)
    with pytest.raises(Conflict, match="identity|registry changed"):
        again.reset("items_app")
    assert (root / "pending-publication.json").is_file()
    assert (auth._draft("items_app") / "review.json").is_file()
    assert _source_files(store) == original_sources


def test_failure_to_prepare_the_journal_is_before_publication(env, monkeypatch):
    store, auth = env
    _, phone = _prepare_update(store, auth)
    real_write = A._atomic_write

    def fail_journal(path, text):
        if path.name == "pending-publication.json":
            raise OSError("synthetic journal write failure")
        return real_write(path, text)

    monkeypatch.setattr(A, "_atomic_write", fail_journal)
    with pytest.raises(StoreError, match="prepare.*sources"):
        auth.approve("items_app", **ask_and_sign(auth, phone))
    assert store.get_manifest("items_app")["revision"] == 1
    assert len(auth.reviews()) == 1 and auth.status("items_app")["baseRevision"] == 1
    root = store.app_dir("items_app")
    assert not (root / "pending-publication.json").exists() and not (root / "source.pending").exists()


@pytest.mark.parametrize("unavailable", ["pending-publication.json", "source.pending"])
def test_transient_metadata_stat_failure_does_not_discard_a_committed_snapshot(env, monkeypatch, unavailable):
    store, auth = env
    _, phone = _prepare_update(store, auth)
    real_finish = auth._finish_publication

    def fail_finish(*args, **kwargs):
        raise OSError("synthetic interrupted finalization")

    monkeypatch.setattr(auth, "_finish_publication", fail_finish)
    assert auth.approve("items_app", **ask_and_sign(auth, phone))["finalizationPending"] is True
    monkeypatch.setattr(auth, "_finish_publication", real_finish)
    root = store.app_dir("items_app")
    real_stat = Path.stat
    blocked = threading.Event()
    blocked.set()

    def fail_stat(path, *args, **kwargs):
        if path == root / unavailable and blocked.is_set():
            raise OSError("synthetic temporary metadata read failure")
        return real_stat(path, *args, **kwargs)

    monkeypatch.setattr(Path, "stat", fail_stat)
    with pytest.raises(Conflict, match="unavailable|committed.*finalization"):
        auth.status("items_app")
    with pytest.raises(Conflict, match="unavailable|committed.*finalization"):
        auth.reviews()
    blocked.clear()
    assert (root / "source.pending").is_dir() and (root / "pending-publication.json").is_file()
    assert auth.status("items_app")["baseRevision"] == 2 and auth.reviews() == []
