"""Linked sources: an app over an SQLite database that another program owns, read-only (ADR-002 §13a).

The foreign database is built with plain `sqlite3`, the way an existing skill's script would, and
mimics the receipts schema of a real Hermes skill (money as REAL rubles, free-form status).
"""
import hashlib
import sqlite3
from pathlib import Path

import pytest

from mobile_surfaces_core import bundle as B
from mobile_surfaces_core.store import Conflict, Store, StoreError

SCHEMA = """
CREATE TABLE addresses (id INTEGER PRIMARY KEY AUTOINCREMENT, address TEXT UNIQUE NOT NULL, alias TEXT);
CREATE TABLE providers (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL);
CREATE TABLE receipts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, address_id INTEGER NOT NULL, provider_id INTEGER,
    period TEXT, amount REAL, status TEXT DEFAULT 'new', raw_text TEXT
);
"""

DEFINITIONS = {
    "queries": {
        # the source stores rubles as REAL; the interface contract is integer kopecks
        "unpaid_total": {
            "sql": "SELECT COALESCE(CAST(ROUND(SUM(amount) * 100) AS INTEGER), 0) FROM receipts WHERE status <> 'paid'",
            "shape": "value",
        },
        "receipts": {
            "sql": "SELECT r.id, a.alias AS address, p.name AS provider, r.period, "
                   "CAST(ROUND(r.amount * 100) AS INTEGER) AS amount, r.status "
                   "FROM receipts r JOIN addresses a ON a.id = r.address_id "
                   "LEFT JOIN providers p ON p.id = r.provider_id ORDER BY r.period DESC, r.id DESC",
            "shape": "rows",
            "maxRows": 100,
        },
    },
    "mutations": {},
}


def make_foreign(path: Path, *, wal: bool = False) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    if wal:
        conn.execute("PRAGMA journal_mode = WAL")
    conn.executescript(SCHEMA)
    conn.executemany("INSERT INTO addresses(address, alias) VALUES (?,?)",
                     [("г. Нижний Новгород, ул. Первая, 1", "Квартира"), ("рп. Красные Баки, ул. Вторая, 2", "Дача")])
    conn.executemany("INSERT INTO providers(name) VALUES (?)", [("ТСЖ Фрезия",), ("Газпром",)])
    conn.executemany(
        "INSERT INTO receipts(address_id, provider_id, period, amount, status, raw_text) VALUES (?,?,?,?,?,?)",
        [(1, 1, "2026-08", 4710.5, "paid", "raw pdf text"),
         (1, 2, "2026-09", 790.25, "new", "raw pdf text"),
         (2, 1, "2026-09", 1190.0, "new", "raw pdf text")],
    )
    conn.commit()
    conn.close()


def add_receipt(path: Path, amount: float) -> None:
    conn = sqlite3.connect(path)
    conn.execute("INSERT INTO receipts(address_id, provider_id, period, amount) VALUES (1, 1, '2026-10', ?)", (amount,))
    conn.commit()
    conn.close()


def fingerprint(directory: Path) -> dict[str, str]:
    """Every file next to the database, by content: a new -journal/-wal/-shm file shows up too."""
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(directory.iterdir())}


def publish(store: Store, app_id: str, tmp_path: Path) -> int:
    dist = tmp_path / "dist"
    dist.mkdir(exist_ok=True)
    (dist / "index.html").write_text("<!doctype html><title>x</title>")
    norm = store.validate_definitions(app_id, DEFINITIONS)
    built = B.build_bundle(dist, contract_hash=store.contract_hash(norm))
    return store.publish(app_id, built, DEFINITIONS)


def query(store: Store, app_id: str, rev: int, *names: str) -> dict:
    return store.run_queries(app_id, rev, [{"name": n} for n in names], device_id="t", tz_name=None)


@pytest.fixture
def linked(tmp_path):
    foreign = tmp_path / "foreign" / "zhkh.db"
    make_foreign(foreign)
    store = Store(tmp_path / "home")
    store.link_source("zhkh", "Квитанции ЖКХ", foreign, icon="receipt", brief="existing skill database")
    return store, foreign, tmp_path


def test_linked_app_reads_the_foreign_database_and_leaves_it_untouched(linked):
    store, foreign, tmp_path = linked
    before = fingerprint(foreign.parent)
    rev = publish(store, "zhkh", tmp_path)

    out = query(store, "zhkh", rev, "unpaid_total", "receipts")

    assert out["results"]["unpaid_total"]["data"] == 198025  # 790.25 + 1190.00 rubles, in kopecks
    rows = out["results"]["receipts"]["data"]
    assert [(r["address"], r["period"], r["amount"], r["status"]) for r in rows] == [
        ("Дача", "2026-09", 119000, "new"), ("Квартира", "2026-09", 79025, "new"), ("Квартира", "2026-08", 471050, "paid"),
    ]
    assert fingerprint(foreign.parent) == before  # not one byte, not one extra file


def test_data_rev_follows_commits_made_by_the_owner(linked):
    store, foreign, tmp_path = linked
    rev = publish(store, "zhkh", tmp_path)
    first = query(store, "zhkh", rev, "unpaid_total")
    assert query(store, "zhkh", rev, "unpaid_total")["dataRev"] == first["dataRev"]  # idle: stable

    start = store.events_since(0, store.epoch())
    add_receipt(foreign, 55.5)  # the owning skill's script commits
    ev = store.events_since(start["seq"], start["epoch"])  # the poll notices it first
    assert [(e["type"], e["appId"]) for e in ev["events"]] == [("data.changed", "zhkh")]
    assert ev["events"][0]["payload"]["dataRev"] == first["dataRev"] + 1

    after = query(store, "zhkh", rev, "unpaid_total")
    assert after["dataRev"] == first["dataRev"] + 1  # a read does not advance it a second time
    assert after["results"]["unpaid_total"]["data"] == 198025 + 5550
    assert store.events_since(ev["seq"], ev["epoch"])["events"] == []


def test_a_read_notices_a_change_and_journals_it_once(linked):
    store, foreign, tmp_path = linked
    rev = publish(store, "zhkh", tmp_path)
    base = query(store, "zhkh", rev, "unpaid_total")["dataRev"]
    start = store.events_since(0, store.epoch())

    add_receipt(foreign, 10.0)
    assert query(store, "zhkh", rev, "unpaid_total")["dataRev"] == base + 1  # the read saw it first
    assert query(store, "zhkh", rev, "unpaid_total")["dataRev"] == base + 1
    events = store.events_since(start["seq"], start["epoch"])["events"]
    assert [e["type"] for e in events] == ["data.changed"]


def test_wal_database_with_a_live_writer_is_read_and_detected(tmp_path):
    foreign = tmp_path / "foreign" / "zhkh.db"
    make_foreign(foreign, wal=True)
    owner = sqlite3.connect(foreign)  # the skill process keeps its connection open
    owner.execute("PRAGMA journal_mode = WAL")
    store = Store(tmp_path / "home")
    store.link_source("zhkh", "Квитанции ЖКХ", foreign)
    rev = publish(store, "zhkh", tmp_path)
    try:
        first = query(store, "zhkh", rev, "unpaid_total")
        owner.execute("INSERT INTO receipts(address_id, provider_id, period, amount) VALUES (1, 1, '2026-10', 100.0)")
        owner.commit()
        after = query(store, "zhkh", rev, "unpaid_total")
        assert after["dataRev"] == first["dataRev"] + 1
        assert after["results"]["unpaid_total"]["data"] == first["results"]["unpaid_total"]["data"] + 10000
    finally:
        owner.close()


def test_writes_schema_changes_and_mutations_are_refused(linked):
    store, foreign, tmp_path = linked
    before = fingerprint(foreign.parent)
    for mode, sql in (
        ("write", "UPDATE receipts SET status = 'paid'"),
        ("write", "DELETE FROM receipts"),
        ("schema", "CREATE TABLE extra (id INTEGER PRIMARY KEY)"),
        ("schema", "DROP TABLE receipts"),
    ):
        with pytest.raises(StoreError, match="read-only"):
            store.agent_sql("zhkh", mode, sql)
    mutation = {"mutations": {"mark_paid": {"sql": "UPDATE receipts SET status = 'paid' WHERE id = :id",
                                            "params": {"id": {"type": "integer"}}}}}
    with pytest.raises(StoreError, match="read-only"):
        store.validate_definitions("zhkh", mutation)
    assert fingerprint(foreign.parent) == before


def test_author_can_explore_the_schema_before_any_interface_exists(linked):
    store, _, _ = linked  # not published
    tables = store.agent_sql("zhkh", "read", "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    assert [r[0] for r in tables["rows"]] == ["addresses", "providers", "receipts", "sqlite_sequence"]
    sample = store.agent_sql("zhkh", "read", "SELECT id, period, amount FROM receipts ORDER BY id LIMIT 2")
    assert sample["rows"] == [[1, "2026-08", 4710.5], [2, "2026-09", 790.25]]
    listed = {a["appId"]: a for a in store.all_apps()}
    assert listed["zhkh"]["linked"] is True and listed["zhkh"]["published"] is False
    assert store.list_apps() == []  # never shown to phones until an interface is published


def test_phone_queries_cannot_read_sqlite_internals(linked):
    store, _, _ = linked
    with pytest.raises(StoreError):
        store.validate_definitions("zhkh", {"queries": {"peek": {"sql": "SELECT name FROM sqlite_master", "shape": "rows"}}})


def test_source_validation(linked, tmp_path):
    store, foreign, _ = linked
    text = tmp_path / "notes.txt"
    text.write_text("not a database")
    with pytest.raises(StoreError, match="absolute"):
        store.link_source("rel", "Rel", "zhkh.db")
    with pytest.raises(StoreError, match="does not exist"):
        store.link_source("gone", "Gone", tmp_path / "missing.db")
    with pytest.raises(StoreError, match="not an SQLite"):
        store.link_source("txt", "Txt", text)
    with pytest.raises(StoreError, match="own storage"):
        store.link_source("own", "Own", store.root / "registry.db")
    with pytest.raises(Conflict):
        store.link_source("zhkh", "Again", foreign)
    with pytest.raises(StoreError, match="appId"):
        store.link_source("../x", "Bad", foreign)
    with pytest.raises(StoreError, match="title"):
        store.link_source("blank", "  ", foreign)
    assert {a["appId"] for a in store.all_apps()} == {"zhkh"}  # failed links left nothing behind


def test_two_apps_may_read_the_same_file(linked):
    store, foreign, _ = linked
    store.link_source("zhkh_copy", "Second view", foreign)
    one = store.agent_sql("zhkh", "read", "SELECT COUNT(*) FROM receipts")["rows"]
    two = store.agent_sql("zhkh_copy", "read", "SELECT COUNT(*) FROM receipts")["rows"]
    assert one == two == [[3]]
    add_receipt(foreign, 1.0)
    start = store.events_since(0, store.epoch())
    assert store.agent_sql("zhkh", "read", "SELECT COUNT(*) FROM receipts")["dataRev"] == \
        store.agent_sql("zhkh_copy", "read", "SELECT COUNT(*) FROM receipts")["dataRev"]
    assert start["reset"] is False


# -- review: the owner moves, deletes or damages the file after linking ------------------------

def moved_away(linked_fixture):
    store, foreign, tmp_path = linked_fixture
    rev = publish(store, "zhkh", tmp_path)
    hidden = tmp_path / "hidden.db"
    foreign.replace(hidden)
    return store, foreign, hidden, rev, tmp_path


def assert_reported_not_raised(store, rev, tmp_path):
    """Every entry point answers with a StoreError (HTTP 4xx), never a raw sqlite3 exception."""
    with pytest.raises(StoreError, match="not available") as phone:
        query(store, "zhkh", rev, "unpaid_total")
    with pytest.raises(StoreError, match="not available"):
        store.validate_definitions("zhkh", DEFINITIONS)
    with pytest.raises(StoreError, match="not available"):
        store.agent_sql("zhkh", "read", "SELECT COUNT(*) FROM receipts")
    assert str(tmp_path) not in str(phone.value)  # SQLite's message does not leak the server path
    assert phone.value.status == 400


def test_a_source_the_owner_moved_is_reported_not_raised(linked):
    store, foreign, hidden, rev, tmp_path = moved_away(linked)
    assert_reported_not_raised(store, rev, tmp_path)
    store.events_since(0, store.epoch())  # the event poll keeps working meanwhile
    hidden.replace(foreign)  # the owner puts it back
    assert query(store, "zhkh", rev, "unpaid_total")["results"]["unpaid_total"]["data"] == 198025


def test_a_source_replaced_by_garbage_is_reported_not_raised(linked):
    store, foreign, tmp_path = linked
    rev = publish(store, "zhkh", tmp_path)
    foreign.write_bytes(b"this is not a database" * 100)
    with pytest.raises(StoreError):
        query(store, "zhkh", rev, "unpaid_total")
    with pytest.raises(StoreError):
        store.validate_definitions("zhkh", DEFINITIONS)
    store.events_since(0, store.epoch())


def test_an_unavailable_source_is_a_400_over_http_and_in_authoring_checks(linked):
    from fastapi import FastAPI
    from fastapi.testclient import TestClient

    from mobile_surfaces.api import mount

    store, foreign, hidden, rev, tmp_path = moved_away(linked)
    app = FastAPI()
    mount(app, store)
    c = TestClient(app)
    base = "/api/plugins/mobile-surfaces/v1"
    r = c.post(f"{base}/apps/zhkh/data", json={"revision": rev, "queries": [{"name": "unpaid_total"}]})
    assert r.status_code == 400 and "not available" in r.json()["error"] and str(tmp_path) not in r.text
    assert c.get(f"{base}/events").status_code == 200
    hidden.replace(foreign)
    ok = c.post(f"{base}/apps/zhkh/data", json={"revision": rev, "queries": [{"name": "unpaid_total"}]})
    assert ok.status_code == 200