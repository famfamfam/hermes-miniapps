"""The zhkh-app template's queries against the receipts schema of an existing receipts skill.

The template is the interface that runs over the author's own receipts skill (utility bills, with the PDFs kept on
disk); it is published as an example of "an interface over somebody else's database". The schema below is the one the
skill's own script creates. The template must work over it as it is: REAL money, nullable amounts and statuses, a
status the template does not know, an address without receipts, a duplicate address that points at its canonical one,
and a raw text that is JSON for some receipts and plain text for others. The linked database is never written.
"""
import json
import sqlite3
from pathlib import Path

import pytest

from mobile_surfaces_core import bundle as B
from mobile_surfaces_core.store import NotFound, Store, StoreError

TEMPLATE = Path(__file__).resolve().parents[2] / "templates" / "zhkh-app"

SKILL_SCHEMA = """
CREATE TABLE addresses (
    id INTEGER PRIMARY KEY AUTOINCREMENT, address TEXT UNIQUE NOT NULL, alias TEXT,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP, canonical_id INTEGER
);
CREATE TABLE providers (
    id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL, created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE service_types (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT UNIQUE NOT NULL);
CREATE TABLE receipts (
    id INTEGER PRIMARY KEY AUTOINCREMENT, address_id INTEGER NOT NULL, provider_id INTEGER,
    service_type_id INTEGER, period TEXT, receipt_date TEXT, amount REAL, amount_paid REAL,
    account_number TEXT, file_path TEXT, raw_text TEXT, status TEXT DEFAULT 'new',
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (address_id) REFERENCES addresses(id),
    FOREIGN KEY (provider_id) REFERENCES providers(id),
    FOREIGN KEY (service_type_id) REFERENCES service_types(id)
);
"""

PARSED = json.dumps({
    "payer_name": "Ivan I.",
    "services": [
        {"name": "Water", "amount": 100.5, "unit": "m3", "volume": 3, "tariff": 33.5},
        {"name": "Waste", "amount": 12.0, "unit": None, "volume": None, "tariff": None},
    ],
})


@pytest.fixture
def zhkh(tmp_path):
    db = tmp_path / "skill" / "zhkh.db"
    db.parent.mkdir()
    conn = sqlite3.connect(db)
    conn.executescript(SKILL_SCHEMA)
    conn.executemany(
        "INSERT INTO addresses(address, alias, canonical_id) VALUES (?,?,?)",
        [("addr one", "Квартира", None), ("addr two", "Дача", None),
         ("603145, ул. Тестовая, 5", None, None),    # a postal code in front: the screens show the rest
         ("addr one (spelled again)", None, 1)],      # the same place written differently: counted under address 1
    )
    conn.executemany("INSERT INTO providers(name) VALUES (?)", [("ТСЖ",), ("Газпром",)])
    conn.executemany("INSERT INTO service_types(name) VALUES (?)", [("Электричество",), ("Газ",)])
    conn.executemany(
        "INSERT INTO receipts(address_id, provider_id, service_type_id, period, receipt_date, account_number, amount, "
        "amount_paid, status, raw_text, file_path) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
        [(1, 1, 1, "2026-08", "2026-08-05", "A-1", 4710.5, 4710.5, "paid", "RAW PDF TEXT", "/data/a.pdf"),
         (1, 2, 2, "2026-09", "2026-09-05", "A-2", 790.25, None, "new", PARSED, "/data/b.pdf"),
         (2, 1, None, "2026-09", None, None, 1190.0, None, "overdue", "RAW PDF TEXT", "/data/c.pdf"),
         (2, None, None, "2026-07", None, None, None, None, None, None, None),
         (4, 1, None, "2026-09", None, None, 100.0, None, "new", None, None)],
    )
    conn.commit()
    conn.close()
    store = Store(tmp_path / "home")
    store.link_source("zhkh", "Receipts", db)
    # The skill keeps the PDFs on disk; the service sees that folder somewhere else (a read-only mount).
    folder = tmp_path / "mounted_receipts"
    folder.mkdir()
    (folder / "a.pdf").write_bytes(b"%PDF-1.4 a")
    (folder / "b.pdf").write_bytes(b"%PDF-1.4 b")
    store.files.link_root("zhkh", "receipts", folder, strip_prefix="/data")
    definitions = json.loads((TEMPLATE / "definitions.json").read_text(encoding="utf-8"))
    dist = tmp_path / "dist"
    dist.mkdir()
    (dist / "index.html").write_text("<!doctype html><title>x</title>")
    norm = store.validate_definitions("zhkh", definitions)
    rev = store.publish("zhkh", B.build_bundle(dist, contract_hash=store.contract_hash(norm)), definitions)
    return store, rev, db


def run(store, rev, *calls):
    names = [c if isinstance(c, dict) else {"name": c} for c in calls]
    return store.run_queries("zhkh", rev, names, device_id="t", tz_name=None)["results"]


def test_template_definitions_validate_and_publish_over_the_skill_schema(zhkh):
    store, rev, _ = zhkh
    assert rev == 1
    assert store.get_manifest("zhkh")["mutations"] == {}  # a linked app declares none


def test_overview_numbers_are_integer_kopecks(zhkh):
    store, rev, _ = zhkh
    out = run(store, rev, "due_total", "due_count", "overdue_count", "latest_period", "latest_total")
    assert out["due_total"]["data"] == 208025      # 790.25 + 1190.00 + 100.00; the NULL amount adds nothing
    assert out["due_count"]["data"] == 4           # new, overdue, the receipt with a NULL status, the new one
    assert out["overdue_count"]["data"] == 1
    assert out["latest_period"]["data"] == "2026-09"
    assert out["latest_total"]["data"] == 208025
    assert all(isinstance(out[k]["data"], int) for k in ("due_total", "due_count", "latest_total"))


def test_monthly_totals_have_no_nulls_and_addresses_merge_into_their_canonical_one(zhkh):
    store, rev, _ = zhkh
    out = run(store, rev, "monthly_totals", "by_address")
    assert out["monthly_totals"]["data"] == [
        {"month": "2026-09", "total": 208025}, {"month": "2026-08", "total": 471050}, {"month": "2026-07", "total": 0},
    ]
    assert out["by_address"]["data"] == [
        {"id": 2, "name": "addr two", "alias": "Дача", "receipts": 2, "due": 119000},
        {"id": 1, "name": "addr one", "alias": "Квартира", "receipts": 3, "due": 89025},  # 2 of its own + 1 respelled
        {"id": 3, "name": "ул. Тестовая, 5", "alias": None, "receipts": 0, "due": 0},   # postal code left off
    ]


def test_receipts_list_filters_by_status_and_does_not_expose_raw_text_or_paths(zhkh):
    store, rev, _ = zhkh
    everything = run(store, rev, {"name": "receipts", "args": {"status": None}})["receipts"]["data"]
    assert [r["id"] for r in everything] == [5, 3, 2, 1, 4]
    assert set(everything[0]) == {"id", "address", "provider", "service", "period", "amount", "status"}
    text = json.dumps(everything, ensure_ascii=False)
    assert "RAW PDF TEXT" not in text and "Ivan" not in text and "/data/" not in text and ".pdf" not in text
    assert everything[-1]["amount"] is None and everything[-1]["status"] == "new"  # NULL status reads as new
    assert everything[0]["address"] == "addr one"  # the respelled address is shown as its canonical one

    new = run(store, rev, {"name": "receipts", "args": {"status": "new"}})["receipts"]["data"]
    assert [r["id"] for r in new] == [5, 2, 4]
    paid = run(store, rev, {"name": "receipts", "args": {"status": "paid"}})["receipts"]["data"]
    assert [r["id"] for r in paid] == [1]


def test_the_detail_reads_the_parsed_receipt_and_says_whether_there_is_a_file_but_never_where(zhkh):
    store, rev, _ = zhkh
    out = run(store, rev, {"name": "receipt", "args": {"id": 2}}, {"name": "receipt_services", "args": {"id": 2}})
    detail = out["receipt"]["data"]
    assert detail["payer"] == "Ivan I." and detail["amount"] == 79025 and detail["amount_paid"] is None
    assert (detail["status"], detail["account_number"], detail["receipt_date"], detail["has_file"]) == ("new", "A-2", "2026-09-05", 1)
    assert out["receipt_services"]["data"] == [
        {"name": "Water", "amount": 10050, "unit": "m3", "volume": 3, "tariff": 33.5},
        {"name": "Waste", "amount": 1200, "unit": None, "volume": None, "tariff": None},
    ]
    plain = run(store, rev, {"name": "receipt", "args": {"id": 1}}, {"name": "receipt_services", "args": {"id": 1}})
    assert plain["receipt"]["data"]["payer"] is None and plain["receipt"]["data"]["amount_paid"] == 471050
    assert plain["receipt_services"]["data"] == []  # a raw text that is not JSON yields no lines, not an error
    without_file = run(store, rev, {"name": "receipt", "args": {"id": 4}})["receipt"]["data"]
    assert without_file["has_file"] == 0
    everything = json.dumps([out, plain, without_file], ensure_ascii=False)
    assert "/data/" not in everything and "RAW PDF TEXT" not in everything
    assert store.get_manifest("zhkh")["files"] == {"receipt_file": {"params": {"id": {"type": "integer"}}}}


def test_a_receipt_downloads_as_its_pdf_and_only_that(zhkh):
    store, rev, _ = zhkh
    path, name, mime, size = store.locate_download("zhkh", rev, "receipt_file", {"id": 2}, device_id="t", tz_name=None)
    assert (name, mime, size) == ("b.pdf", "application/pdf", len(b"%PDF-1.4 b"))
    assert path.read_bytes() == b"%PDF-1.4 b"

    with pytest.raises(NotFound):  # the receipt without a file path
        store.locate_download("zhkh", rev, "receipt_file", {"id": 4}, device_id="t", tz_name=None)
    with pytest.raises(NotFound):  # the path names a file that is not in the mounted folder (c.pdf)
        store.locate_download("zhkh", rev, "receipt_file", {"id": 3}, device_id="t", tz_name=None)
    with pytest.raises(StoreError):  # an argument the locator does not declare
        store.locate_download("zhkh", rev, "receipt_file", {"id": 1, "path": "/etc/passwd"}, device_id="t", tz_name=None)


def test_the_skill_writing_a_new_receipt_shows_up_without_any_action(zhkh):
    store, rev, db = zhkh
    before = store.run_queries("zhkh", rev, [{"name": "due_count"}], device_id="t", tz_name=None)
    conn = sqlite3.connect(db)  # what the skill's own script does
    conn.execute("INSERT INTO receipts(address_id, provider_id, period, amount) VALUES (1, 1, '2026-10', 55.5)")
    conn.commit()
    conn.close()
    after = store.run_queries("zhkh", rev, [{"name": "due_count"}, {"name": "due_total"}], device_id="t", tz_name=None)
    assert after["dataRev"] == before["dataRev"] + 1
    assert after["results"]["due_count"]["data"] == 5
    assert after["results"]["due_total"]["data"] == 208025 + 5550
