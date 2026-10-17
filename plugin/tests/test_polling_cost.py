"""Review finding 13: the shared journal is trimmed (ADR-002 §5) and a poll does not fan out per app."""
import contextlib
import json
import sqlite3
from datetime import datetime, timedelta, timezone

import pytest

from mobile_surfaces_core import authoring as authoring_module
from mobile_surfaces_core import bundle as B
from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.store import Conflict, Store


def stamp(hours_ago):
    moment = datetime.now(timezone.utc) - timedelta(hours=hours_ago)
    return moment.isoformat(timespec="seconds").replace("+00:00", "Z")


def registry(store):
    return sqlite3.connect(store.root / "registry.db")


def seqs(store):
    conn = registry(store)
    try:
        return [r[0] for r in conn.execute("SELECT seq FROM events ORDER BY seq")]
    finally:
        conn.close()


def set_age(store, hours_ago, where="1 = 1"):
    conn = registry(store)
    try:
        conn.execute(f"UPDATE events SET ts = ? WHERE {where}", (stamp(hours_ago),))
        conn.commit()
    finally:
        conn.close()


@pytest.fixture
def journal(store):
    store.create_app("alpha", "Alpha")
    for n in range(6):
        store.emit("review.changed", "alpha", {"n": n})
    return store


# -- the journal is trimmed ----------------------------------------------------------------------

def test_old_events_are_deleted_but_the_newest_row_survives(journal):
    store = journal
    first = store.events_since(0, store.epoch())
    assert first["reset"] is False and len(first["events"]) == 6
    set_age(store, 48)
    store.events_since(first["seq"], first["epoch"])
    assert seqs(store) == [first["seq"]]  # everything is older than 24 h; the newest row stays
    assert store.events_since(first["seq"], first["epoch"]) == {
        "epoch": first["epoch"], "seq": first["seq"], "reset": False, "events": [],
    }


def test_a_cursor_older_than_the_journal_gets_reset_and_a_current_one_does_not(journal):
    store = journal
    cursor = store.events_since(0, store.epoch())
    stale = cursor["seq"] - 3
    set_age(store, 48)
    store.emit("review.changed", "alpha", {"n": "fresh"})
    after = store.events_since(cursor["seq"], cursor["epoch"])  # the device that is up to date
    assert after["reset"] is False and [e["payload"] for e in after["events"]] == [{"n": "fresh"}]
    behind = store.events_since(stale, cursor["epoch"])  # the device that missed rows that are now gone
    assert behind["reset"] is True and behind["events"] == []
    assert behind["epoch"] == cursor["epoch"] and behind["seq"] == after["seq"]


def test_recent_events_are_kept(journal):
    store = journal
    store.events_since(0, store.epoch())
    before = seqs(store)
    set_age(store, 23)
    store.events_since(0, store.epoch())
    assert seqs(store) == before


def test_the_sweep_waits_an_hour_past_the_limit_so_polls_do_not_write_every_time(journal):
    store = journal
    store.events_since(0, store.epoch())
    before = seqs(store)
    set_age(store, 24.5)  # past 24 h but inside the one-hour slack
    store.events_since(0, store.epoch())
    assert seqs(store) == before
    set_age(store, 25.5)
    store.events_since(0, store.epoch())
    assert seqs(store) == [before[-1]]


def test_only_the_old_rows_go_and_order_is_kept(journal):
    store = journal
    store.events_since(0, store.epoch())
    before = seqs(store)
    set_age(store, 30, where=f"seq <= {before[2]}")
    set_age(store, 1, where=f"seq > {before[2]}")
    store.events_since(0, store.epoch())
    assert seqs(store) == before[3:]


def test_a_busy_registry_does_not_fail_the_poll_and_the_sweep_is_retried(journal, monkeypatch):
    store = journal
    cursor = store.events_since(0, store.epoch())
    set_age(store, 48)
    original = Store._registry

    def impatient(self):
        conn = original(self)
        conn.execute("PRAGMA busy_timeout = 0")
        return conn

    holder = registry(store)
    holder.isolation_level = None
    holder.execute("BEGIN IMMEDIATE")  # another writer holds the registry
    monkeypatch.setattr(Store, "_registry", impatient)
    try:
        answer = store.events_since(cursor["seq"], cursor["epoch"])
    finally:
        holder.execute("ROLLBACK")
        holder.close()
    assert answer["reset"] is False and len(seqs(store)) == 6  # answered, nothing swept yet
    monkeypatch.setattr(Store, "_registry", original)
    store.events_since(cursor["seq"], cursor["epoch"])
    assert seqs(store) == [cursor["seq"]]

# -- one poll does not cost several connections per app --------------------------------------------

def publish_trivial(store, app_id, tmp_path):
    store.create_app(app_id, app_id.upper())
    dist = tmp_path / f"dist-{app_id}"
    dist.mkdir()
    (dist / "index.html").write_text(app_id)
    defs = {"queries": {}, "mutations": {}}
    built = B.build_bundle(dist, contract_hash=store.contract_hash(store.validate_definitions(app_id, defs)))
    store.publish(app_id, built, defs)


def count_registry_connections(store, monkeypatch, action):
    calls = []
    original = Store._registry

    def counting(self):
        calls.append(1)
        return original(self)

    monkeypatch.setattr(Store, "_registry", counting)
    try:
        action()
    finally:
        monkeypatch.setattr(Store, "_registry", original)
    return len(calls)


def test_an_idle_poll_opens_the_same_few_registry_connections_whatever_the_app_count(store, tmp_path, monkeypatch):
    publish_trivial(store, "app_one", tmp_path)
    store.pump_outboxes()  # settle: the first sweep journals the publish bookkeeping
    one = count_registry_connections(store, monkeypatch, lambda: store.events_since(0, store.epoch()))
    for name in ("app_two", "app_three", "app_four", "app_five"):
        publish_trivial(store, name, tmp_path)
    store.pump_outboxes()
    five = count_registry_connections(store, monkeypatch, lambda: store.events_since(0, store.epoch()))
    assert one == five <= 4
    assert count_registry_connections(store, monkeypatch, store.pump_outboxes) == 1


def test_the_single_connection_sweep_still_journals_every_apps_writes_once(store, tmp_path):
    for name in ("app_one", "app_two", "app_three"):
        publish_trivial(store, name, tmp_path)
        store.agent_sql(name, "schema", "CREATE TABLE t (id INTEGER PRIMARY KEY)")
        store.agent_sql(name, "write", "INSERT INTO t DEFAULT VALUES")
    assert store.pump_outboxes() == 6
    assert store.pump_outboxes() == 0
    store.agent_sql("app_two", "write", "INSERT INTO t DEFAULT VALUES")
    assert store.pump_outboxes() == 1


# -- the phone's /previews poll does not lock every app ----------------------------------------------

@pytest.fixture
def lock_counter(monkeypatch):
    taken = []
    original = authoring_module._file_lock

    @contextlib.contextmanager
    def counting(path):
        taken.append(path.parent.name)
        with original(path):
            yield

    monkeypatch.setattr(authoring_module, "_file_lock", counting)
    return taken


def make_authoring(store, tmp_path, names):
    for name in names:
        publish_trivial(store, name, tmp_path)
    return Authoring(store, tmp_path / "template")


def write_review(store, app_id):
    draft = store.root / "apps" / app_id / "draft"
    draft.mkdir(parents=True, exist_ok=True)
    (draft / "draft.json").write_text(json.dumps({"draftRev": 2, "baseRevision": 1}))
    (draft / "review.json").write_text(json.dumps({
        "buildId": "build_abc", "draftRev": 2, "baseRevision": 1, "bundleId": "sha256:" + "0" * 64,
        "bundleBytes": 10, "title": app_id.upper(), "icon": None, "isNew": False,
        "submittedAt": "2026-10-15T00:00:00Z",
    }))


def test_reviews_takes_no_lock_for_apps_with_nothing_to_review(store, tmp_path, lock_counter):
    auth = make_authoring(store, tmp_path, ["app_one", "app_two", "app_three"])
    assert auth.reviews() == []
    assert lock_counter == []


def test_reviews_still_locks_and_reports_an_app_with_a_submitted_build(store, tmp_path, lock_counter):
    auth = make_authoring(store, tmp_path, ["app_one", "app_two", "app_three"])
    write_review(store, "app_two")
    found = auth.reviews()
    assert [(r["appId"], r["buildId"]) for r in found] == [("app_two", "build_abc")]
    assert lock_counter == ["app_two"]


def test_reviews_still_runs_recovery_for_an_unfinished_publication(store, tmp_path, lock_counter):
    auth = make_authoring(store, tmp_path, ["app_one", "app_two"])
    (store.root / "apps" / "app_one" / "pending-publication.json").write_text("{ not json")
    with pytest.raises(Conflict, match="cannot be reconciled"):
        auth.reviews()
    assert lock_counter == ["app_one"]


def test_reviews_still_clears_an_interrupted_source_preparation(store, tmp_path, lock_counter):
    auth = make_authoring(store, tmp_path, ["app_one"])
    leftover = store.root / "apps" / "app_one" / "source.pending"
    leftover.mkdir()
    (leftover / "partial.ts").write_text("x")
    assert auth.reviews() == []
    assert lock_counter == ["app_one"] and not leftover.exists()
