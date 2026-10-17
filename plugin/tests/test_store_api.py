import json
import time

import pytest

from conftest import BASE, DEFINITIONS
from mobile_surfaces_core import bundle as B
from mobile_surfaces_core.store import Conflict, NotFound, StoreError


def test_health_and_hello(client):
    c, store, *_ = client
    h = c.get(f"{BASE}/health").json()
    assert h["apiVersion"] == "v1" and h["epoch"] == store.epoch() and h["sdkMajors"] == [1]
    ok = c.post(f"{BASE}/devices/hello", json={"hostVersion": "0", "sdkMajor": 1, "bundleFormat": 1}).json()
    assert ok["compatible"]
    bad = c.post(f"{BASE}/devices/hello", json={"hostVersion": "0", "sdkMajor": 9, "bundleFormat": 7}).json()
    assert not bad["compatible"] and len(bad["problems"]) == 2


def test_manifest_hides_sql_and_exposes_contract(client):
    c, _, built, rev = client
    m = c.get(f"{BASE}/apps/utilities").json()
    assert m["revision"] == rev == 1
    assert m["bundle"]["bundleId"] == built.bundle_id
    assert m["bundle"]["contractHash"].startswith("sha256:")
    assert set(m["queries"]) == {"bills", "month_total"}
    assert m["queries"]["bills"]["columns"] == ["id", "supplier", "period", "amount", "status"]
    assert m["queries"]["bills"]["completeness"] == "bounded"
    assert m["queries"]["month_total"]["completeness"] == "complete"
    assert m["mutations"]["delete_bill"]["destructive"] is True
    assert m["mutations"]["mark_paid"]["destructive"] is False
    assert "SELECT" not in str(m) and "UPDATE" not in str(m)


def test_etag_304_and_changes_after_republish(client, tmp_path):
    c, store, *_ = client
    first = c.get(f"{BASE}/apps")
    assert first.status_code == 200 and first.headers["etag"]
    again = c.get(f"{BASE}/apps", headers={"If-None-Match": first.headers["etag"]})
    assert again.status_code == 304
    one = c.get(f"{BASE}/apps/utilities")
    assert c.get(f"{BASE}/apps/utilities", headers={"If-None-Match": one.headers["etag"]}).status_code == 304
    dist = tmp_path / "dist2"
    dist.mkdir()
    (dist / "index.html").write_text("changed")
    norm = store.validate_definitions("utilities", DEFINITIONS)
    store.publish("utilities", B.build_bundle(dist, contract_hash=store.contract_hash(norm)), DEFINITIONS)
    assert c.get(f"{BASE}/apps/utilities", headers={"If-None-Match": one.headers["etag"]}).status_code == 200


def test_bundle_download_verifies_against_manifest(client):
    c, _, built, _ = client
    r = c.get(f"{BASE}/apps/utilities/bundles/{built.bundle_id}")
    assert r.status_code == 200 and "immutable" in r.headers["cache-control"]
    B.verify_bundle(r.content, expected_id=built.bundle_id)


@pytest.mark.parametrize("bid", ["sha256:" + "0" * 64, "../../registry.db", "x", "sha256:../../etc"])
def test_unknown_or_malicious_bundle_id_404(client, bid):
    c, *_ = client
    assert c.get(f"{BASE}/apps/utilities/bundles/{bid}").status_code == 404


@pytest.mark.parametrize("app_id", ["nope", "..", "UPPER", "a" * 60, "x;drop"])
def test_bad_app_ids_404(client, app_id):
    c, *_ = client
    assert c.get(f"{BASE}/apps/{app_id}").status_code == 404


def test_data_group_is_consistent_and_typed(client):
    c, _, _, rev = client
    body = {"revision": rev, "timezone": "Europe/Moscow",
            "queries": [{"name": "bills", "args": {"status": "unpaid"}}, {"name": "month_total"}]}
    r = c.post(f"{BASE}/apps/utilities/data", json=body, headers={"X-Device-Id": "d1"})
    assert r.status_code == 200
    out = r.json()
    assert [row["supplier"] for row in out["results"]["bills"]["data"]] == ["Gas", "Power"]
    assert out["results"]["bills"]["completeness"] == "bounded"
    assert isinstance(out["dataRev"], int) and out["revision"] == rev
    assert out["results"]["month_total"]["data"] in (540000, 0, 450000, 90000)


def test_data_rejects_stale_revision_unknown_query_and_bad_args(client):
    c, _, _, rev = client
    post = lambda body: c.post(f"{BASE}/apps/utilities/data", json=body)
    assert post({"revision": rev + 1, "queries": [{"name": "bills"}]}).status_code == 409
    assert post({"revision": rev, "queries": [{"name": "drop_all"}]}).status_code == 400
    assert post({"revision": rev, "queries": [{"name": "bills", "args": {"status": "other"}}]}).status_code == 400
    assert post({"revision": rev, "queries": [{"name": "bills", "args": {"x": 1}}]}).status_code == 400
    assert post({"revision": rev, "queries": [{"name": "bills", "args": {"status": "paid; DROP TABLE bills"}}]}).status_code == 400


def test_agent_write_shows_up_in_phone_query(client):
    c, store, _, rev = client
    before = c.post(f"{BASE}/apps/utilities/data", json={"revision": rev, "queries": [{"name": "month_total"}]}).json()
    store.agent_sql("utilities", "write",
                    "INSERT INTO bills(supplier, period, amount) VALUES (:s, date('now'), :a)", {"s": "Internet", "a": 77})
    after = c.post(f"{BASE}/apps/utilities/data", json={"revision": rev, "queries": [{"name": "month_total"}]}).json()
    assert after["dataRev"] == before["dataRev"] + 1


def test_definitions_validated_against_database(store):
    store.create_app("valapp", "valapp")
    store.agent_sql("valapp", "schema", "CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT)")
    good = {"queries": {"all_t": {"sql": "SELECT id, x FROM t", "shape": "rows"}}}
    assert store.validate_definitions("valapp", good)["queries"]["all_t"]["columns"] == ["id", "x"]
    bad_cases = [
        {"queries": {"q": {"sql": "SELECT nope FROM t", "shape": "rows"}}},
        {"queries": {"q": {"sql": "SELECT * FROM missing", "shape": "rows"}}},
        {"queries": {"q": {"sql": "SELECT x FROM t WHERE id = :undeclared", "shape": "rows"}}},
        {"queries": {"q": {"sql": "SELECT x FROM t", "params": {"unused": {"type": "integer"}}, "shape": "rows"}}},
        {"queries": {"q": {"sql": "SELECT * FROM _ms_meta", "shape": "rows"}}},
        {"queries": {"q": {"sql": "DELETE FROM t", "shape": "rows"}}},
        {"queries": {"q": {"sql": "SELECT 1", "shape": "rows", "maxRows": 5000}}},
        {"queries": {"BAD NAME": {"sql": "SELECT 1", "shape": "rows"}}},
        {"queries": {"q": {"sql": "SELECT :now", "params": {"now": {"type": "string"}}, "shape": "value"}}},
        {"mutations": {"m": {"sql": "SELECT 1"}}},
        {"mutations": {"m": {"sql": "UPDATE _ms_meta SET value = 1"}}},
        {"mutations": {"m": {"sql": "DROP TABLE t"}}},
        {"extra": {}},
    ]
    for case in bad_cases:
        with pytest.raises(StoreError):
            store.validate_definitions("valapp", case)


def test_definition_probe_does_not_change_data(store):
    store.create_app("probeapp", "probeapp")
    store.agent_sql("probeapp", "schema", "CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT)")
    store.agent_sql("probeapp", "write", "INSERT INTO t(x) VALUES ('keep')")
    rev = store.app_db("probeapp").data_rev()
    store.validate_definitions("probeapp", {"mutations": {
        "wipe": {"sql": "DELETE FROM t WHERE id = :id", "params": {"id": {"type": "integer"}}}}})
    assert store.app_db("probeapp").data_rev() == rev
    assert store.agent_sql("probeapp", "read", "SELECT x FROM t")["rows"] == [["keep"]]


def test_publish_rejects_bundle_built_for_other_contract(seeded, tmp_path):
    store, *_ = seeded
    dist = tmp_path / "d3"
    dist.mkdir()
    (dist / "index.html").write_text("x")
    with pytest.raises(StoreError, match="contract"):
        store.publish("utilities", B.build_bundle(dist, contract_hash="sha256:" + "1" * 64), DEFINITIONS)


def test_failed_publish_keeps_previous_version(seeded, tmp_path):
    store, built, rev = seeded
    bad = {"queries": {"broken": {"sql": "SELECT * FROM gone", "shape": "rows"}}}
    dist = tmp_path / "d4"
    dist.mkdir()
    (dist / "index.html").write_text("new")
    with pytest.raises(StoreError):
        store.publish("utilities", B.build_bundle(dist), bad)
    assert store.get_manifest("utilities")["bundle"]["bundleId"] == built.bundle_id
    assert store.get_manifest("utilities")["revision"] == rev


def _types(payload):
    return [(e["type"], e["appId"]) for e in payload["events"]]


def test_events_start_with_reset_then_deliver_publish_and_data_changes(client):
    c, store, *_ = client
    first = c.get(f"{BASE}/events").json()
    assert first["reset"] is True and first["events"] == []
    cursor, epoch = first["seq"], first["epoch"]
    assert cursor >= 3  # registry.changed, app.changed, bundle.changed from the initial publish

    store.agent_sql("utilities", "write", "UPDATE bills SET status = 'paid' WHERE id = 2")
    got = c.get(f"{BASE}/events", params={"since": cursor, "epoch": epoch}).json()
    assert got["reset"] is False
    assert _types(got) == [("data.changed", "utilities")]
    assert got["events"][0]["payload"]["tables"] == ["bills"]
    assert c.get(f"{BASE}/events", params={"since": got["seq"], "epoch": epoch}).json()["events"] == []


def test_outbox_pump_never_journals_a_row_twice_even_if_trim_is_lost(client, monkeypatch):
    c, store, *_ = client
    start = c.get(f"{BASE}/events").json()
    db = store.app_db("utilities")
    monkeypatch.setattr(type(db), "outbox_trim", lambda self, upto: None)  # crash after the registry commit
    store.agent_sql("utilities", "write", "UPDATE bills SET amount = amount + 1 WHERE id = 1")
    assert store.pump_outboxes() == 1
    assert store.pump_outboxes() == 0  # position stored in the registry stops a second journal entry
    got = c.get(f"{BASE}/events", params={"since": start["seq"], "epoch": start["epoch"]}).json()
    assert _types(got) == [("data.changed", "utilities")]


def test_events_reset_on_foreign_epoch_or_future_cursor(client):
    c, *_ = client
    cur = c.get(f"{BASE}/events").json()
    assert c.get(f"{BASE}/events", params={"since": 0, "epoch": "other"}).json()["reset"] is True
    assert c.get(f"{BASE}/events", params={"since": cur["seq"] + 99, "epoch": cur["epoch"]}).json()["reset"] is True


def test_republish_emits_bundle_and_app_events(client, tmp_path):
    c, store, *_ = client
    cur = c.get(f"{BASE}/events").json()
    dist = tmp_path / "dist5"
    dist.mkdir()
    (dist / "index.html").write_text("v2")
    norm = store.validate_definitions("utilities", DEFINITIONS)
    store.publish("utilities", B.build_bundle(dist, contract_hash=store.contract_hash(norm)), DEFINITIONS)
    got = c.get(f"{BASE}/events", params={"since": cur["seq"], "epoch": cur["epoch"]}).json()
    assert [e["type"] for e in got["events"]] == ["app.changed", "bundle.changed"]


def test_relative_home_path_works(tmp_path, monkeypatch):
    """Regression: the CLI runs with a relative --home; sqlite file URIs need absolute paths."""
    from mobile_surfaces_core.store import Store

    monkeypatch.chdir(tmp_path)
    s = Store(__import__("pathlib").Path("rel-home"))
    s.create_app("relapp", "Rel")
    s.agent_sql("relapp", "schema", "CREATE TABLE t (id INTEGER PRIMARY KEY)")
    assert s.agent_sql("relapp", "read", "SELECT COUNT(*) FROM t")["rows"] == [[0]]


def test_unpublished_app_is_hidden(store):
    store.create_app("draftapp", "Draft")
    assert store.list_apps() == []
    with pytest.raises(NotFound):
        store.get_manifest("draftapp")
    with pytest.raises(Conflict):
        store.create_app("draftapp", "Again")


def test_agent_tool_cannot_touch_reserved_tables(seeded):
    store, *_ = seeded
    for mode, sql in (("read", "SELECT * FROM _ms_meta"), ("write", "DELETE FROM _ms_outbox"),
                      ("schema", "DROP TABLE _ms_meta")):
        with pytest.raises(StoreError):
            store.agent_sql("utilities", mode, sql)


# -- review findings: limits, REPLACE, unbindable values at the HTTP and Store boundary ----------

def publish_definitions(store, tmp_path, definitions):
    dist = tmp_path / "dist-review"
    dist.mkdir(exist_ok=True)
    (dist / "index.html").write_text(f"review {len(definitions['queries'])}")
    norm = store.validate_definitions("utilities", definitions)
    return store.publish("utilities", B.build_bundle(dist, contract_hash=store.contract_hash(norm)), definitions)


TYPED_QUERIES = {"queries": {
    "by_id": {"sql": "SELECT id, supplier FROM bills WHERE id = :id", "params": {"id": {"type": "integer"}}, "shape": "rows"},
    "by_amount": {"sql": "SELECT id FROM bills WHERE amount = :n", "params": {"n": {"type": "number"}}, "shape": "rows"},
    "by_supplier": {"sql": "SELECT id FROM bills WHERE supplier = :s", "params": {"s": {"type": "string"}}, "shape": "rows"},
    "fill": {"sql": "SELECT length(replace(printf('%.*c', :n, 'x'), 'x', 'xxxxxxxxxxxx')) AS n",
             "params": {"n": {"type": "integer"}}, "shape": "value"},
}, "mutations": {}}


@pytest.mark.parametrize(
    "name, args",
    [
        ("by_id", {"id": 10**30}),
        ("by_id", {"id": 2**63}),
        ("by_id", {"id": -(2**63) - 1}),
        ("by_amount", {"n": 10**30}),
        ("by_supplier", {"s": "\ud800"}),
    ],
)
def test_values_sqlite_cannot_bind_are_a_400_not_a_500(client, tmp_path, name, args):
    c, store, *_ = client
    rev = publish_definitions(store, tmp_path, TYPED_QUERIES)
    # Sent the way a phone sends it: ASCII-escaped JSON ("\\ud800" is a lone surrogate once parsed).
    body = json.dumps({"revision": rev, "queries": [{"name": name, "args": args}]})
    r = c.post(f"{BASE}/apps/utilities/data", content=body.encode("ascii"), headers={"Content-Type": "application/json"})
    assert r.status_code == 400 and r.json()["error"]


def test_values_at_the_edge_of_the_range_still_work(client, tmp_path):
    c, store, *_ = client
    rev = publish_definitions(store, tmp_path, TYPED_QUERIES)
    for name, args in (("by_id", {"id": 2**63 - 1}), ("by_id", {"id": -(2**63)}), ("by_amount", {"n": 1e300}),
                       ("by_supplier", {"s": "Водоканал 😀"})):
        r = c.post(f"{BASE}/apps/utilities/data", json={"revision": rev, "queries": [{"name": name, "args": args}]})
        assert r.status_code == 200 and r.json()["results"][name]["data"] == []


def test_a_query_that_would_build_a_huge_value_is_refused_and_stays_fast(client, tmp_path):
    c, store, *_ = client
    rev = publish_definitions(store, tmp_path, TYPED_QUERIES)
    started = time.monotonic()
    # replace() grows 9 MB to ~108 MB: SQLite refuses it ("string or blob too big") -> 400.
    r = c.post(f"{BASE}/apps/utilities/data", json={"revision": rev, "queries": [{"name": "fill", "args": {"n": 9000000}}]})
    assert r.status_code == 400 and "too big" in r.json()["error"]
    # printf itself gives up with NULL instead of allocating ~900 MB: an answer, quickly, with no big value.
    bomb = c.post(f"{BASE}/apps/utilities/data", json={"revision": rev, "queries": [{"name": "fill", "args": {"n": 900000000}}]})
    assert bomb.status_code == 200 and bomb.json()["results"]["fill"]["data"] is None
    assert time.monotonic() - started < 5
    ok = c.post(f"{BASE}/apps/utilities/data", json={"revision": rev, "queries": [{"name": "fill", "args": {"n": 1000}}]})
    assert ok.status_code == 200 and ok.json()["results"]["fill"]["data"] == 12000


def test_authoring_check_of_a_value_bomb_is_a_diagnostic_not_a_crash(store):
    store.create_app("bomb", "Bomb")
    store.agent_sql("bomb", "schema", "CREATE TABLE t (id INTEGER PRIMARY KEY)")
    with pytest.raises(StoreError, match="too big"):
        store.validate_definitions("bomb", {"queries": {"bomb_q": {
            "sql": "SELECT replace(printf('%.*c', 9000000, 'x'), 'x', 'xxxxxxxxxxxx') AS v", "shape": "value"}}})
    with pytest.raises(StoreError):
        store.agent_sql("bomb", "read", "SELECT replace(printf('%.*c', 9000000, 'x'), 'x', 'xxxxxxxxxxxx')")


@pytest.mark.parametrize(
    "sql",
    [
        "INSERT OR REPLACE INTO bills(id, supplier, period, amount) VALUES (:id, 's', 'p', 1)",
        "REPLACE INTO bills(id, supplier, period, amount) VALUES (:id, 's', 'p', 1)",
        "UPDATE OR REPLACE bills SET id = :id WHERE supplier = 'Gas'",
    ],
)
def test_replace_mutations_are_published_as_destructive(client, tmp_path, sql):
    c, store, *_ = client
    definitions = {**DEFINITIONS, "mutations": {
        **DEFINITIONS["mutations"], "upsert_bill": {"sql": sql, "params": {"id": {"type": "integer"}}}}}
    assert store.validate_definitions("utilities", definitions)["mutations"]["upsert_bill"]["destructive"] is True
    publish_definitions(store, tmp_path, definitions)
    manifest = c.get(f"{BASE}/apps/utilities").json()
    assert manifest["mutations"]["upsert_bill"]["destructive"] is True
    assert manifest["mutations"]["mark_paid"]["destructive"] is False