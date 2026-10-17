"""Regressions for the Stage 0 code review (findings 1, 4, 5, 7, 9, 10, 11)."""
import hashlib
import io
import json
import sqlite3
import threading
import time
import zipfile

import pytest

from conftest import DEFINITIONS
from mobile_surfaces_core import bundle as B
from mobile_surfaces_core import sandbox
from mobile_surfaces_core.appdb import AppDb
from mobile_surfaces_core.store import Store, StoreError


def _publish_same_content(store, app_id, dist):
    store.create_app(app_id, app_id.upper())
    defs = {"queries": {}, "mutations": {}}
    built = B.build_bundle(dist, contract_hash=store.contract_hash(store.validate_definitions(app_id, defs)))
    store.publish(app_id, built, defs)
    return built


# -- 1. identical content in two apps -------------------------------------------------

def test_two_apps_with_identical_bundles_both_stay_downloadable(store, tmp_path):
    dist = tmp_path / "dist"
    dist.mkdir()
    (dist / "index.html").write_text("same template")
    a = _publish_same_content(store, "aa", dist)
    b = _publish_same_content(store, "bb", dist)
    assert a.bundle_id == b.bundle_id
    for app_id in ("aa", "bb"):
        assert store.bundle_path(app_id, a.bundle_id).is_file()
        assert store.get_manifest(app_id)["bundle"]["bundleId"] == a.bundle_id
        assert store.get_manifest(app_id)["bundle"]["size"] == len(a.data)


# -- 4. concurrent /events must not journal a row twice --------------------------------

def test_concurrent_pumps_journal_each_row_once(seeded, monkeypatch):
    store, *_ = seeded

    # Widen the window between "read what is pending" and "journal it", so a read taken outside
    # the write lock is exposed every time instead of once in a few runs. (`outbox_after` is the
    # name the reading method had before the fix; harmless when absent.)
    def widen(name):
        original = getattr(AppDb, name, None)
        if original is None:
            return

        def slow(self, *a, **k):
            result = original(self, *a, **k)
            time.sleep(0.03)
            return result

        monkeypatch.setattr(AppDb, name, slow)

    for name in ("outbox_snapshot", "outbox_after"):
        widen(name)
    for _ in range(30):
        store.agent_sql("utilities", "write", "UPDATE bills SET amount = amount + 1 WHERE id = 1")
    writes = store.app_db("utilities").data_rev()  # every write (including the fixture's) queued one event
    assert writes == 32
    threads = 8
    barrier = threading.Barrier(threads)
    errors = []

    def pump():
        try:
            barrier.wait()
            store.pump_outboxes()
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    workers = [threading.Thread(target=pump) for _ in range(threads)]
    for w in workers:
        w.start()
    for w in workers:
        w.join()
    assert not errors
    conn = sqlite3.connect(store.root / "registry.db")
    count = conn.execute("SELECT COUNT(*) FROM events WHERE type = 'data.changed'").fetchone()[0]
    assert count == writes


# -- 5. reads must not take the write lock ---------------------------------------------

def test_phone_queries_do_not_wait_for_a_writer(seeded):
    store, _, rev = seeded[0], None, seeded[2]
    holder = sqlite3.connect(store.root / "apps" / "utilities" / "data.db", isolation_level=None)
    holder.execute("BEGIN IMMEDIATE")  # an agent write in progress
    try:
        started = time.monotonic()
        out = store.run_queries("utilities", rev, [{"name": "month_total"}], device_id="d", tz_name=None)
        assert out["results"]["month_total"]["data"] is not None
        store.pump_outboxes()
        assert time.monotonic() - started < 1.0
    finally:
        holder.execute("ROLLBACK")
        holder.close()


# -- 7. definitions are validated under the phone's limits -----------------------------

def test_query_reading_sqlite_master_is_rejected_at_definition_time(store):
    store.create_app("valid1", "V")
    with pytest.raises(StoreError):
        store.validate_definitions("valid1", {"queries": {"peek": {"sql": "SELECT name FROM sqlite_master", "shape": "rows"}}})


def test_query_too_slow_for_the_phone_is_rejected_at_definition_time(store, monkeypatch):
    store.create_app("valid2", "V")
    monkeypatch.setattr(sandbox, "PHONE_TIMEOUT_S", 0.05)
    monkeypatch.setattr(sandbox, "AGENT_TIMEOUT_S", 30.0)
    slow = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c WHERE x < 3000000) SELECT MAX(x) FROM c"
    with pytest.raises(StoreError, match="time limit"):
        store.validate_definitions("valid2", {"queries": {"slowq": {"sql": slow, "shape": "value"}}})


# -- 9. malformed bundle.json is a BundleError, never an AttributeError -----------------

def _zip_with_manifest(manifest_bytes, files=None):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("bundle.json", manifest_bytes)
        for name, data in (files or {}).items():
            zf.writestr(name, data)
    return buf.getvalue(), B.digest_bytes(manifest_bytes)


def _entry(path="index.html", data=b"x"):
    return {"path": path, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}


GOOD = {"format": 1, "entrypoint": "index.html", "sdkMajor": 1, "capabilities": [], "files": [_entry()]}


@pytest.mark.parametrize(
    "mutate",
    [
        lambda m: ["not", "an", "object"],
        lambda m: {**m, "files": ["x"]},
        lambda m: {**m, "files": [None]},
        lambda m: {**m, "files": [{"path": 5, "sha256": "0", "size": 1}]},
        lambda m: {**m, "files": [{**_entry(), "size": "1"}]},
        lambda m: {**m, "files": [{**_entry(), "sha256": 7}]},
        lambda m: {**m, "files": "index.html"},
        lambda m: {**m, "sdkMajor": "1"},
        lambda m: {k: v for k, v in m.items() if k != "sdkMajor"},
        lambda m: {**m, "capabilities": "camera"},
        lambda m: {**m, "capabilities": [1]},
        lambda m: {**m, "entrypoint": 3},
        lambda m: {**m, "entrypoint": ["index.html"]},
    ],
)
def test_malformed_manifest_is_a_bundle_error(mutate):
    data, bid = _zip_with_manifest(json.dumps(mutate(GOOD)).encode(), {"index.html": b"x"})
    with pytest.raises(B.BundleError):
        B.verify_bundle(data, expected_id=bid)


# -- 10. restoring an older database must force a resync --------------------------------

def test_restoring_an_older_database_rotates_the_epoch(seeded, tmp_path):
    store, *_ = seeded
    db_path = store.root / "apps" / "utilities" / "data.db"
    backup = tmp_path / "backup.db"
    src = sqlite3.connect(db_path)
    dst = sqlite3.connect(backup)
    src.backup(dst)
    src.close()
    dst.close()

    for _ in range(5):
        store.agent_sql("utilities", "write", "UPDATE bills SET amount = amount + 1 WHERE id = 1")
    start = store.events_since(0, None)  # pumps the five writes
    epoch_before = start["epoch"]

    # Restore the older file over the live one, as an operator would.
    live = sqlite3.connect(db_path)
    old = sqlite3.connect(backup)
    old.backup(live)
    old.close()
    live.close()

    after = store.events_since(start["seq"], epoch_before)
    assert after["reset"] is True and after["epoch"] != epoch_before
    # and it keeps working: new writes after the restore are journalled normally
    store.agent_sql("utilities", "write", "UPDATE bills SET amount = amount + 1 WHERE id = 2")
    again = store.events_since(after["seq"], after["epoch"])
    assert [e["type"] for e in again["events"]] == ["data.changed"]


# -- 11. reserved names in ALTER / INDEX statements -------------------------------------

@pytest.mark.parametrize(
    "sql",
    [
        "ALTER TABLE _ms_meta ADD COLUMN z TEXT",
        "ALTER TABLE _ms_outbox RENAME TO other",
        "ALTER TABLE bills RENAME TO _ms_stolen",
        "CREATE INDEX i_evil ON _ms_outbox(ts)",
        "CREATE INDEX _ms_evil ON bills(id)",
    ],
)
def test_schema_mode_cannot_touch_reserved_objects(tmp_path, sql):
    db = AppDb.create(tmp_path / "d.db")
    db.write("CREATE TABLE bills (id INTEGER PRIMARY KEY, amount INTEGER)", mode=sandbox.SCHEMA, caller=sandbox.AGENT)
    rev = db.data_rev()
    with pytest.raises(sandbox.SandboxError):
        db.write(sql, mode=sandbox.SCHEMA, caller=sandbox.AGENT)
    assert db.data_rev() == rev
    conn = sqlite3.connect(db.path)
    cols = [r[1] for r in conn.execute("PRAGMA table_info(_ms_meta)")]
    assert cols == ["key", "value"]


def test_schema_mode_still_allows_normal_alters_and_indexes(tmp_path):
    db = AppDb.create(tmp_path / "d.db")
    db.write("CREATE TABLE bills (id INTEGER PRIMARY KEY, amount INTEGER)", mode=sandbox.SCHEMA, caller=sandbox.AGENT)
    _, res = db.write("ALTER TABLE bills ADD COLUMN note TEXT", mode=sandbox.SCHEMA, caller=sandbox.AGENT)
    assert res.tables == ["bills"]
    _, res = db.write("CREATE INDEX bills_amount ON bills(amount)", mode=sandbox.SCHEMA, caller=sandbox.AGENT)
    assert res.tables == ["bills"]
    db.write("DROP INDEX bills_amount", mode=sandbox.SCHEMA, caller=sandbox.AGENT)
