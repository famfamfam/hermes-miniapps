"""Buttons that write: a published app's reviewed mutations, run once per key (ADR-004 §2-3), in the app's own
database and, when the administrator allowed it, in the database of another program."""
import copy
import os
import sqlite3
import stat
import time

import pytest

from conftest import BASE, DEFINITIONS
from mobile_surfaces_core import appdb, linked, sandbox
from mobile_surfaces_core import bundle as B
from mobile_surfaces_core.store import Conflict, NotFound, OutcomeUnknown, RequestKeyReused, Store, StoreError

from test_linked_source import fingerprint, make_foreign

KEY = "k" * 16
OTHER = "o" * 16


def republish(store, tmp_path, app_id, definitions, label="x"):
    dist = tmp_path / f"dist-{label}"
    dist.mkdir(exist_ok=True)
    (dist / "index.html").write_text(f"<!doctype html><title>{label}</title>")
    norm = store.validate_definitions(app_id, definitions)
    return store.publish(app_id, B.build_bundle(dist, contract_hash=store.contract_hash(norm)), definitions)


def with_mutations(**extra):
    defs = copy.deepcopy(DEFINITIONS)
    defs["mutations"].update(extra)
    return defs


ADD_BILL = {
    "sql": "INSERT INTO bills(supplier, period, amount) VALUES (:supplier, :today, :amount)",
    "params": {"supplier": {"type": "string"}, "amount": {"type": "integer"}},
    "label": "Add a bill",
}


def post(client, app_id, name, *, revision, args=None, key=KEY):
    return client.post(
        f"{BASE}/apps/{app_id}/mutations/{name}",
        json={"revision": revision, "args": args, "idempotencyKey": key, "timezone": "UTC"},
    )


def bills(store, rev):
    out = store.run_queries("utilities", rev, [{"name": "bills"}], device_id="t", tz_name=None)
    return {r["id"]: r for r in out["results"]["bills"]["data"]}


# -- the app's own database ---------------------------------------------------------------------------------


def test_a_tap_changes_the_row_and_the_phone_is_told(client):
    c, store, _built, rev = client
    before = store.run_queries("utilities", rev, [{"name": "month_total"}], device_id="t", tz_name=None)["dataRev"]
    start = store.events_since(0, store.epoch())

    r = post(c, "utilities", "mark_paid", revision=rev, args={"id": 2})

    assert r.status_code == 200, r.text
    body = r.json()
    assert (body["rowsAffected"], body["replayed"], body["lastInsertId"]) == (1, False, None)
    assert body["dataRev"] == before + 1 and body["revision"] == rev
    assert bills(store, rev)[2]["status"] == "paid" and bills(store, rev)[3]["status"] == "unpaid"
    events = store.events_since(start["seq"], start["epoch"])["events"]
    assert [(e["type"], e["appId"], e["payload"]["dataRev"]) for e in events] == [("data.changed", "utilities", before + 1)]


def test_a_repeated_request_writes_once_and_gets_the_first_answer(client, tmp_path):
    c, store, _built, _ = client
    rev = republish(store, tmp_path, "utilities", with_mutations(add_bill=ADD_BILL))
    args = {"supplier": "Heat", "amount": 5000}

    first = post(c, "utilities", "add_bill", revision=rev, args=args).json()
    again = post(c, "utilities", "add_bill", revision=rev, args=args).json()
    other = post(c, "utilities", "add_bill", revision=rev, args=args, key=OTHER).json()

    assert first["rowsAffected"] == 1 and isinstance(first["lastInsertId"], int) and not first["replayed"]
    assert again == {**first, "replayed": True}
    assert other["replayed"] is False and other["lastInsertId"] == first["lastInsertId"] + 1
    assert sorted(r["supplier"] for r in bills(store, rev).values()).count("Heat") == 2  # two keys, two rows; one key, one


def test_a_key_cannot_be_reused_for_another_request(client):
    c, store, _built, rev = client
    assert post(c, "utilities", "mark_paid", revision=rev, args={"id": 2}).status_code == 200
    r = post(c, "utilities", "mark_paid", revision=rev, args={"id": 3})
    assert r.status_code == 409 and r.json()["code"] == "request_key_reused"
    r = post(c, "utilities", "delete_bill", revision=rev, args={"id": 2})
    assert r.status_code == 409 and r.json()["code"] == "request_key_reused"
    assert bills(store, rev)[3]["status"] == "unpaid" and 2 in bills(store, rev)


def test_a_result_older_than_a_day_is_forgotten_and_the_request_runs_again(seeded):
    store, _built, _rev = seeded
    db = store.app_db("utilities")
    run = lambda at: db.write_many(  # noqa: E731
        ["UPDATE bills SET amount = amount + 1 WHERE id = 1"], {}, caller=sandbox.PHONE, key=KEY, body_hash="h", now=at
    )
    t0 = time.time()
    first, soon, late = run(t0), run(t0 + 60), run(t0 + appdb.IDEMPOTENCY_KEEP_S + 60)
    assert (first.replayed, soon.replayed, late.replayed) == (False, True, False)
    assert soon.data_rev == first.data_rev and late.data_rev == first.data_rev + 1
    conn = sqlite3.connect(store.app_dir("utilities") / "data.db")
    assert conn.execute("SELECT count(*) FROM _ms_idempotency").fetchone()[0] == 1  # the old row was dropped
    conn.close()


def test_stale_revision_unknown_name_and_bad_arguments_change_nothing(client):
    c, store, _built, rev = client
    snapshot = bills(store, rev)
    stale = post(c, "utilities", "mark_paid", revision=rev + 1, args={"id": 2})
    assert stale.status_code == 409 and "code" not in stale.json()  # the phone reads a plain 409 as a stale revision
    for name, args in (("nope", {"id": 2}), ("mark_paid", None), ("mark_paid", {"id": "two"}),
                       ("mark_paid", {"id": 2, "extra": 1}), ("mark_paid", {"id": 2**63})):
        r = post(c, "utilities", name, revision=rev, args=args)
        assert r.status_code == 400, (name, args, r.text)
    assert post(c, "utilities", "mark_paid", revision=rev, args={"id": 2}, key="short").status_code == 422
    assert post(c, "utilities", "mark_paid", revision=rev, args={"id": 2}, key="has space!!!!!!!!").status_code == 422
    assert bills(store, rev) == snapshot


def test_an_unpublished_app_and_a_preview_have_no_mutation_route(client):
    c, store, _built, rev = client
    store.create_app("draftapp", "Draft")
    r = post(c, "draftapp", "mark_paid", revision=1, args={"id": 1})
    assert r.status_code == 404
    for path in (f"{BASE}/previews/utilities/mutations/mark_paid", f"{BASE}/apps/utilities/previews/mutations/mark_paid"):
        assert c.post(path, json={"revision": rev, "idempotencyKey": KEY}).status_code in (404, 405)


def test_statements_run_together_or_not_at_all(client, tmp_path):
    c, store, _built, _ = client
    both = {
        "statements": [
            "UPDATE bills SET status = 'paid' WHERE id = :id",
            "INSERT INTO bills(supplier, period, amount, status) VALUES ('Receipt', :today, 0, 'paid')",
        ],
        "params": {"id": {"type": "integer"}},
        "label": "Pay and log",
    }
    clash = {  # the second statement fails (primary key taken): the first must be undone
        "statements": [
            "UPDATE bills SET status = 'paid' WHERE id = :id",
            "INSERT INTO bills(id, supplier, period, amount) VALUES (:id, 'x', :today, 1)",
        ],
        "params": {"id": {"type": "integer"}},
    }
    rev = republish(store, tmp_path, "utilities", with_mutations(pay_and_log=both, clash=clash))

    ok = post(c, "utilities", "pay_and_log", revision=rev, args={"id": 2})
    assert ok.status_code == 200 and ok.json()["rowsAffected"] == 2
    assert bills(store, rev)[2]["status"] == "paid" and any(r["supplier"] == "Receipt" for r in bills(store, rev).values())

    snapshot = bills(store, rev)
    r = post(c, "utilities", "clash", revision=rev, args={"id": 3}, key=OTHER)
    assert r.status_code == 400 and "UNIQUE" in r.json()["error"]
    assert bills(store, rev) == snapshot  # the UPDATE of id 3 went away with the failed INSERT
    assert post(c, "utilities", "clash", revision=rev, args={"id": 3}, key=OTHER).status_code == 400  # not remembered as done


# -- what a definition may say ------------------------------------------------------------------------------


def test_definitions_without_the_new_keys_keep_their_exact_shape(seeded):
    store, *_ = seeded
    norm = store.validate_definitions("utilities", DEFINITIONS)["mutations"]
    assert norm["mark_paid"] == {
        "sql": "UPDATE bills SET status = 'paid' WHERE id = :id", "params": {"id": {"type": "integer"}}, "destructive": False,
    }
    assert norm["delete_bill"]["destructive"] is True


@pytest.mark.parametrize(
    "mutation, message",
    [
        ({"sql": "UPDATE bills SET status = 'paid'", "statements": ["UPDATE bills SET status = 'paid'"] * 2}, "not both or neither"),
        ({"params": {}}, "not both or neither"),
        ({"statements": ["UPDATE bills SET status = 'paid'"]}, "2-5"),
        ({"statements": ["UPDATE bills SET status = 'paid'"] * 6}, "2-5"),
        ({"statements": ["UPDATE bills SET status = 'paid'", 7]}, "2-5"),
        ({"sql": "UPDATE bills SET status = 'paid'", "label": ""}, "label"),
        ({"sql": "UPDATE bills SET status = 'paid'", "label": "x" * 61}, "label"),
        ({"sql": "UPDATE bills SET status = 'paid'", "label": "two\nlines"}, "label"),
        ({"sql": "UPDATE bills SET status = 'paid'", "confirm": "yes"}, "confirm"),
        ({"sql": "UPDATE bills SET status = 'paid'", "description": "x"}, "expected an object"),
        ("UPDATE bills SET status = 'paid'", "expected an object"),
        ({"sql": "SELECT 1"}, "does not write"),
        ({"statements": ["UPDATE bills SET status = 'paid'", "SELECT 1"]}, "statement 2: statement does not write"),
        ({"sql": "UPDATE bills SET status = :x", "params": {}}, "binding"),
        ({"sql": "UPDATE _ms_meta SET value = 1"}, "not authorized"),  # the service tables are out of reach
    ],
)
def test_a_bad_mutation_definition_is_refused(seeded, mutation, message):
    store, *_ = seeded
    with pytest.raises(StoreError, match=message):
        store.validate_definitions("utilities", {"queries": {}, "mutations": {"mut": mutation}})


def test_one_delete_anywhere_among_the_statements_makes_the_button_destructive(seeded):
    store, *_ = seeded
    first = {"statements": ["DELETE FROM bills WHERE amount = 0", "UPDATE bills SET status = 'paid'"]}
    last = {"statements": ["UPDATE bills SET status = 'paid'", "DELETE FROM bills WHERE amount = 0"]}
    plain = {"statements": ["UPDATE bills SET status = 'paid'", "UPDATE bills SET amount = amount + 1"]}
    out = store.validate_definitions("utilities", {"queries": {}, "mutations": {"first": first, "last": last, "plain": plain}})
    assert [out["mutations"][n]["destructive"] for n in ("first", "last", "plain")] == [True, True, False]


def test_validation_accepts_its_own_output_and_the_author_cannot_hide_a_delete(seeded):
    store, *_ = seeded
    defs = {"queries": {}, "mutations": {
        "mark_paid": {"sql": "UPDATE bills SET status = 'paid' WHERE id = :id", "params": {"id": {"type": "integer"}}},
        "wipe": {"statements": ["UPDATE bills SET status = 'paid'", "DELETE FROM bills WHERE amount = 0"],
                 "label": "  Wipe  ", "confirm": True},
    }}
    once = store.validate_definitions("utilities", defs)
    assert store.validate_definitions("utilities", once) == once  # the approved contract is validated again on publish
    lying = {"queries": {}, "mutations": {"drop": {"sql": "DELETE FROM bills WHERE id = :id", "params": {"id": {"type": "integer"}},
                                                    "destructive": False}}}
    assert store.validate_definitions("utilities", lying)["mutations"]["drop"]["destructive"] is True


def test_label_confirm_and_deletes_reach_the_manifest_but_not_the_sql(client, tmp_path):
    c, store, _built, _ = client
    defs = with_mutations(
        add_bill=ADD_BILL,
        wipe={"statements": ["UPDATE bills SET status = 'paid'", "DELETE FROM bills WHERE amount = 0"], "label": "Wipe", "confirm": True},
    )
    rev = republish(store, tmp_path, "utilities", defs)
    manifest = c.get(f"{BASE}/apps/utilities").json()
    assert manifest["revision"] == rev
    assert manifest["mutations"]["add_bill"] == {
        "params": ADD_BILL["params"], "destructive": False, "label": "Add a bill",
    }
    assert manifest["mutations"]["wipe"] == {"params": {}, "destructive": True, "label": "Wipe", "confirm": True}
    assert manifest["mutations"]["mark_paid"] == {"params": {"id": {"type": "integer"}}, "destructive": False}
    assert "UPDATE" not in c.get(f"{BASE}/apps/utilities").text and "INSERT" not in c.get(f"{BASE}/apps/utilities").text


def test_health_says_the_server_can_run_mutations(client):
    c, *_ = client
    assert c.get(f"{BASE}/health").json()["mutations"] is True


# -- a database that another program owns --------------------------------------------------------------------

LINKED_DEFS = {
    "queries": {"total": {"sql": "SELECT COALESCE(SUM(amount), 0) FROM receipts", "shape": "value"}},
    "mutations": {
        "bump": {"sql": "UPDATE receipts SET amount = amount + 1 WHERE id = :id", "params": {"id": {"type": "integer"}}},
        "add": {"sql": "INSERT INTO receipts(address_id, period, amount) VALUES (1, :period, :amount)",
                "params": {"period": {"type": "string"}, "amount": {"type": "number"}}},
        "boom": {"sql": "UPDATE receipts SET address_id = NULL WHERE id = :id", "params": {"id": {"type": "integer"}}},
    },
}


@pytest.fixture
def zhkh(tmp_path):
    foreign = tmp_path / "foreign" / "zhkh.db"
    make_foreign(foreign)
    store = Store(tmp_path / "home")
    store.link_source("zhkh", "Квитанции ЖКХ", foreign)
    return store, foreign, tmp_path


def amount(foreign, row=1):
    conn = sqlite3.connect(foreign)
    try:
        return conn.execute("SELECT amount FROM receipts WHERE id = ?", (row,)).fetchone()[0]
    finally:
        conn.close()


def run(store, rev, name, args, key=KEY):
    return store.run_mutation("zhkh", rev, name, args, key=key, device_id="t", tz_name=None)


def test_a_linked_app_cannot_write_until_the_administrator_allows_it(zhkh):
    store, foreign, tmp_path = zhkh
    assert {a["appId"]: a for a in store.all_apps()}["zhkh"]["writable"] is False
    with pytest.raises(StoreError, match="read-only"):
        store.validate_definitions("zhkh", LINKED_DEFS)
    store.set_source_writable("zhkh", True)
    assert {a["appId"]: a for a in store.all_apps()}["zhkh"]["writable"] is True
    rev = republish(store, tmp_path, "zhkh", LINKED_DEFS)
    before = fingerprint(foreign.parent)

    store.set_source_writable("zhkh", False)  # taken back after publishing
    with pytest.raises(StoreError, match="read-only"):
        run(store, rev, "bump", {"id": 1})
    assert fingerprint(foreign.parent) == before


def test_a_linked_write_changes_the_foreign_file_and_nothing_else(zhkh):
    store, foreign, tmp_path = zhkh
    store.set_source_writable("zhkh", True)
    rev = republish(store, tmp_path, "zhkh", LINKED_DEFS)
    base = store.run_queries("zhkh", rev, [{"name": "total"}], device_id="t", tz_name=None)["dataRev"]
    start = store.events_since(0, store.epoch())
    names = set(os.listdir(foreign.parent))

    out = run(store, rev, "bump", {"id": 1})

    assert (out["rowsAffected"], out["replayed"], out["dataRev"]) == (1, False, base + 1)
    assert amount(foreign) == 4711.5
    assert set(os.listdir(foreign.parent)) == names  # no journal left behind, no helper file
    conn = sqlite3.connect(foreign)
    assert not [n for (n,) in conn.execute("SELECT name FROM sqlite_master") if n.startswith("_ms_")]
    conn.close()
    events = store.events_since(start["seq"], start["epoch"])["events"]
    assert [(e["type"], e["payload"]["dataRev"]) for e in events] == [("data.changed", base + 1)]
    added = run(store, rev, "add", {"period": "2026-10", "amount": 12.5}, key=OTHER)
    assert added["lastInsertId"] == 4 and added["dataRev"] == base + 2


def test_a_repeated_linked_request_writes_once(zhkh):
    store, foreign, tmp_path = zhkh
    store.set_source_writable("zhkh", True)
    rev = republish(store, tmp_path, "zhkh", LINKED_DEFS)
    first = run(store, rev, "bump", {"id": 1})
    again = run(store, rev, "bump", {"id": 1})
    assert again == {**first, "replayed": True} and amount(foreign) == 4711.5
    with pytest.raises(RequestKeyReused):
        run(store, rev, "bump", {"id": 2})
    assert amount(foreign, 2) == 790.25


def test_a_linked_request_that_may_have_written_is_not_repeated(zhkh):
    store, foreign, tmp_path = zhkh
    store.set_source_writable("zhkh", True)
    rev = republish(store, tmp_path, "zhkh", LINKED_DEFS)
    import hashlib, json  # noqa: E401

    body = hashlib.sha256(json.dumps({"name": "bump", "args": {"id": 1}}, sort_keys=True).encode()).hexdigest()
    conn = store._registry()  # what a crash after "pending" and before "done" leaves
    conn.execute("INSERT INTO mutation_log(app_id, key, body_hash, state, created_at) VALUES ('zhkh', ?, ?, 'pending', ?)",
                 (KEY, body, time.time()))
    conn.close()
    with pytest.raises(OutcomeUnknown):
        run(store, rev, "bump", {"id": 1})
    assert amount(foreign) == 4710.5  # not written a second time, and not written at all by this call


def test_a_failed_linked_write_leaves_no_trace_and_may_be_retried(zhkh):
    store, foreign, tmp_path = zhkh
    store.set_source_writable("zhkh", True)
    rev = republish(store, tmp_path, "zhkh", LINKED_DEFS)
    before = fingerprint(foreign.parent)
    with pytest.raises(StoreError, match="NOT NULL"):
        run(store, rev, "boom", {"id": 1})
    assert fingerprint(foreign.parent) == before
    conn = store._registry()
    assert conn.execute("SELECT count(*) FROM mutation_log").fetchone()[0] == 0  # a retry is allowed to run
    conn.close()


@pytest.mark.skipif(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0), reason="needs file modes that bind")
def test_a_file_the_service_may_not_write_gives_a_message_the_administrator_can_act_on(zhkh):
    store, foreign, tmp_path = zhkh
    store.set_source_writable("zhkh", True)
    foreign.chmod(stat.S_IRUSR | stat.S_IRGRP)
    try:
        with pytest.raises(StoreError, match="not allowed to write"):
            store.validate_definitions("zhkh", LINKED_DEFS)
    finally:
        foreign.chmod(stat.S_IRUSR | stat.S_IWUSR)


@pytest.mark.skipif(os.name == "nt" or (hasattr(os, "geteuid") and os.geteuid() == 0), reason="needs file modes that bind")
def test_a_folder_the_service_may_not_write_is_found_when_the_app_is_checked(zhkh):
    # SQLite creates its journal next to the file, so a writable file in a folder that is not writable is no use.
    store, foreign, tmp_path = zhkh
    store.set_source_writable("zhkh", True)
    folder = foreign.parent
    mode = folder.stat().st_mode
    folder.chmod(stat.S_IRUSR | stat.S_IXUSR)
    try:
        with pytest.raises(StoreError, match="not allowed to write"):
            store.validate_definitions("zhkh", LINKED_DEFS)
    finally:
        folder.chmod(mode)
    store.validate_definitions("zhkh", LINKED_DEFS)  # and once the folder is writable again it is accepted


@pytest.mark.parametrize(
    "text, expected",
    [("attempt to write a readonly database", True), ("unable to open database file", True),
     ("database is locked", False), ("disk I/O error", False)],
)
def test_only_permission_problems_are_reported_as_not_writable(text, expected):
    assert linked._not_writable(sqlite3.OperationalError(text)) is expected


def test_writing_is_not_brought_back_by_restoring_a_deleted_app(zhkh):
    store, foreign, tmp_path = zhkh
    store.set_source_writable("zhkh", True)
    republish(store, tmp_path, "zhkh", LINKED_DEFS)
    name = store.delete_app("zhkh")
    assert store.trash_restore(name) == "zhkh"
    assert {a["appId"]: a for a in store.all_apps()}["zhkh"]["writable"] is False


def test_only_a_linked_app_can_be_switched(seeded):
    store, *_ = seeded
    with pytest.raises(StoreError, match="linked database"):
        store.set_source_writable("utilities", True)
    with pytest.raises(StoreError, match="linked database"):
        store.set_source_writable("nope", True)


def test_a_registry_from_before_writing_existed_is_upgraded(tmp_path):
    home = tmp_path / "home"
    foreign = tmp_path / "foreign" / "zhkh.db"
    make_foreign(foreign)
    store = Store(home)
    store.link_source("zhkh", "Квитанции ЖКХ", foreign)
    conn = store._registry()
    conn.execute("ALTER TABLE app_sources DROP COLUMN writable")
    conn.execute("DROP TABLE mutation_log")
    conn.close()

    again = Store(home)
    assert again.source_path("zhkh") == foreign.resolve()
    again.set_source_writable("zhkh", True)
    assert {a["appId"]: a for a in again.all_apps()}["zhkh"]["writable"] is True
    Store(home)  # a second start finds the column already there


def test_ms_admin_allow_writes_explains_what_the_host_must_do(zhkh, capsys):
    import ms_admin

    store, foreign, _tmp = zhkh
    home = str(store.root.parent)
    assert ms_admin.main(["--home", home, "allow-writes", "zhkh"]) == 0
    out = capsys.readouterr().out
    assert "BindPaths=" in out and "SupplementaryGroups=" in out and "chmod g+w" in out and "chmod o+w" in out and "--revoke" in out and str(foreign.resolve()) in out
    assert Store(store.root.parent).all_apps()[0]["writable"] is True
    assert ms_admin.main(["--home", home, "allow-writes", "zhkh", "--revoke"]) == 0
    assert "read-only again" in capsys.readouterr().out
    assert Store(store.root.parent).all_apps()[0]["writable"] is False
    assert ms_admin.main(["--home", home, "allow-writes", "nope"]) == 1
    assert "linked database" in capsys.readouterr().err

# -- what the author is told, and the template that shows it ------------------------------------------------------

from pathlib import Path  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]


def test_what_the_author_is_told_about_buttons_exists_in_the_kit_and_the_sdk():
    from mobile_surfaces.mcp_server import AUTHORING_REFERENCE, REFERENCE

    skill = (ROOT / "plugin" / "skills" / "surfaces-author" / "SKILL.md").read_text(encoding="utf-8")
    sdk = "".join(p.read_text(encoding="utf-8") for p in (ROOT / "packages" / "mobile-sdk" / "src").glob("*.ts"))
    for template in ("starter-app", "react-app"):
        components = (ROOT / "templates" / template / "src" / "components.tsx").read_text(encoding="utf-8")
        assert "export function ActionButton" in components and "useMutation" in components, template
        assert "toMinor" in (ROOT / "templates" / template / "src" / "format.ts").read_text(encoding="utf-8")
    for name in ("ActionButton", "useMutation", "toMinor", "askHermes", "statements", "label"):
        assert name in AUTHORING_REFERENCE + REFERENCE, name
    assert "mutation" in skill and "ActionButton" in skill and "allow-writes" in skill
    for name in ("mutate", "useMutation", "MutationResult"):  # what the promises are built on
        assert name in sdk, name
    # nothing still tells the author that the phone cannot save
    for text in (REFERENCE, AUTHORING_REFERENCE, skill):
        assert "cannot write yet" not in text and "read-only**: the phone" not in text
    # the promise that no script runs behind a button is in both places an author reads
    assert "does not exist yet" in AUTHORING_REFERENCE and "script" in skill


def test_the_react_template_definitions_check_out_and_run_against_a_real_table(tmp_path):
    import json

    import ms_admin

    store = Store(tmp_path / "home")
    store.create_app("utilities", "Utilities")
    store.agent_sql("utilities", "schema", ms_admin.DEMO_SCHEMA)
    defs = json.loads((ROOT / "templates" / "react-app" / "definitions.json").read_text(encoding="utf-8"))
    rev = republish(store, tmp_path, "utilities", defs)
    assert {"add_bill", "mark_paid", "delete_bill"} <= set(store.get_manifest("utilities")["mutations"])
    manifest = store.get_manifest("utilities")["mutations"]
    assert manifest["delete_bill"]["destructive"] is True and manifest["add_bill"]["destructive"] is False
    assert all(m.get("label") for m in manifest.values())

    def go(name, args, key):
        return store.run_mutation("utilities", rev, name, args, key=key, device_id="t", tz_name=None)

    added = go("add_bill", {"supplier": "Water", "period": "2026-10-01", "amount": 4710, "status": "unpaid"}, "a" * 16)
    assert added["rowsAffected"] == 1 and added["lastInsertId"] == 1
    with pytest.raises(StoreError, match="status"):
        go("add_bill", {"supplier": "Water", "period": "2026-10-01", "amount": 4710, "status": "late"}, "b" * 16)
    with pytest.raises(StoreError, match="YYYY-MM-DD"):
        go("add_bill", {"supplier": "Water", "period": "soon", "amount": 4710, "status": "paid"}, "c" * 16)
    go("mark_paid", {"id": 1}, "d" * 16)
    rows = store.run_queries("utilities", rev, [{"name": "bills"}], device_id="t", tz_name=None)["results"]["bills"]["data"]
    assert [(r["supplier"], r["amount"], r["status"]) for r in rows] == [("Water", 4710, "paid")]
    assert go("delete_bill", {"id": 1}, "e" * 16)["rowsAffected"] == 1
    assert store.run_queries("utilities", rev, [{"name": "bills"}], device_id="t", tz_name=None)["results"]["bills"]["data"] == []
