"""S0-8: SQLite sandbox must refuse everything outside the caller's mode."""
import sqlite3
import time

import pytest

from mobile_surfaces_core import sandbox
from mobile_surfaces_core.appdb import AppDb
from mobile_surfaces_core.sandbox import AGENT, PHONE, READ, SCHEMA, WRITE, SandboxError


@pytest.fixture
def db(tmp_path):
    d = AppDb.create(tmp_path / "data.db")
    d.write("CREATE TABLE bills (id INTEGER PRIMARY KEY, amount INTEGER NOT NULL, note TEXT)", mode=SCHEMA, caller=AGENT)
    d.write(
        "INSERT INTO bills(amount, note) VALUES (?, ?)", [(100, "a"), (250, "b"), (50, None)],
        mode=WRITE, caller=AGENT, many=True,
    )
    return d


def read(db, sql, bindings=(), caller=PHONE, **kw):
    return db.read_group([(sql, bindings, 1000)], caller=caller, **kw)[1][0]


def test_read_select_and_window_and_json(db):
    res = read(db, "SELECT id, SUM(amount) OVER (ORDER BY id) AS run, json_object('n', note) AS j FROM bills ORDER BY id")
    assert res.columns == ["id", "run", "j"]
    assert [r[1] for r in res.rows] == [100, 350, 400]
    assert res.rows[0][2] == '{"n":"a"}'


def test_pure_string_and_math_functions_an_author_needs_are_allowed(db):
    """Found in a real authoring run: the author wanted replace() to normalise text."""
    res = read(
        db,
        "SELECT replace('a-b-c', '-', '_'), char(72, 105), lower('ABC'), trim('  x '), instr('abc', 'c'), "
        "CAST(floor(2.7) AS INTEGER), CAST(ceil(2.1) AS INTEGER), CAST(pow(2, 3) AS INTEGER) FROM bills LIMIT 1",
    )
    assert res.rows[0] == ["a_b_c", "Hi", "abc", "x", 3, 2, 3, 8]


def test_sqlite_lower_and_upper_only_fold_ascii(db):
    """Documented in the author reference: Cyrillic is not case-folded by SQLite's lower()/upper()."""
    res = read(db, "SELECT lower('ГОРОД'), upper('город'), lower('ABC') FROM bills LIMIT 1")
    assert res.rows[0] == ["ГОРОД", "город", "abc"]


@pytest.mark.parametrize(
    "sql",
    [
        "ATTACH DATABASE ':memory:' AS x",
        "PRAGMA table_info(bills)",
        "PRAGMA writable_schema = ON",
        "SELECT * FROM _ms_meta",
        "SELECT * FROM _ms_outbox",
        "SELECT * FROM sqlite_master",
        "INSERT INTO bills(amount) VALUES (1)",
        "UPDATE bills SET amount = 0",
        "DELETE FROM bills",
        "DROP TABLE bills",
        "CREATE TABLE t(x)",
        "CREATE TRIGGER tr AFTER INSERT ON bills BEGIN SELECT 1; END",
        "SELECT load_extension('x')",
        "SELECT randomblob(1000000000)",
        "SELECT zeroblob(1000000000)",
        "VACUUM",
        "BEGIN",
        "COMMIT",
        "SAVEPOINT s",
    ],
)
def test_phone_read_refuses(db, sql):
    with pytest.raises(SandboxError):
        read(db, sql)


def test_read_connection_is_actually_read_only(db):
    """Even if the authorizer were bypassed, the connection itself is query_only / mode=ro."""
    conn = sandbox.connect(db.path, readonly=True)
    with pytest.raises(sqlite3.OperationalError):
        conn.execute("INSERT INTO bills(amount) VALUES (1)")
    conn.close()


def test_two_statements_in_one_call_refused(db):
    with pytest.raises(Exception):
        read(db, "SELECT 1; SELECT 2")


def test_reserved_tables_denied_in_every_write_mode(db):
    for mode in (WRITE, SCHEMA):
        for sql in (
            "UPDATE _ms_meta SET value = '0'",
            "INSERT INTO _ms_outbox(ts, type, payload) VALUES ('', '', '')",
            "DELETE FROM _ms_outbox",
        ):
            with pytest.raises(SandboxError):
                db.write(sql, mode=mode, caller=AGENT)
    with pytest.raises(SandboxError):
        db.write("DROP TABLE _ms_meta", mode=SCHEMA, caller=AGENT)
    with pytest.raises(SandboxError):
        db.write("CREATE TABLE _ms_evil (x)", mode=SCHEMA, caller=AGENT)
    assert db.data_rev() >= 1


def test_write_mode_cannot_change_schema_or_pragma(db):
    for sql in ("CREATE TABLE t(x)", "DROP TABLE bills", "ALTER TABLE bills ADD COLUMN z", "PRAGMA user_version = 5"):
        with pytest.raises(SandboxError):
            db.write(sql, mode=WRITE, caller=AGENT)


def test_schema_mode_still_blocks_attach_pragma_triggers(db):
    for sql in (
        "INSERT INTO sqlite_master(type, name, tbl_name, rootpage, sql) VALUES ('table', 'x', 'x', 0, '')",
        "DELETE FROM sqlite_master",
        "UPDATE sqlite_master SET sql = ''",
        "ATTACH DATABASE ':memory:' AS x",
        "PRAGMA writable_schema = ON",
        "CREATE TRIGGER tr AFTER INSERT ON bills BEGIN SELECT 1; END",
        "CREATE VIRTUAL TABLE v USING fts5(a)",
    ):
        with pytest.raises(SandboxError):
            db.write(sql, mode=SCHEMA, caller=AGENT)


def test_write_bumps_data_rev_and_queues_event(db):
    before = db.data_rev()
    rev, res = db.write("UPDATE bills SET amount = amount + 1 WHERE id = :id", {"id": 1}, mode=WRITE, caller=AGENT)
    assert rev == before + 1 and res.tables == ["bills"] and res.rowcount == 1
    conn = sqlite3.connect(db.path)
    last = conn.execute("SELECT type, payload FROM _ms_outbox ORDER BY id DESC LIMIT 1").fetchone()
    assert last[0] == "data.changed" and f'"dataRev": {rev}' in last[1] and '"bills"' in last[1]


def test_failed_write_leaves_no_trace(db):
    before = db.data_rev()
    with pytest.raises(SandboxError):
        db.write("INSERT INTO bills(amount) VALUES (NULL)", mode=WRITE, caller=AGENT)
    assert db.data_rev() == before


def test_timeout_interrupts_runaway_query(db):
    runaway = "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM c) SELECT COUNT(*) FROM c"
    with pytest.raises(sandbox.QueryTimeout):
        read(db, runaway, timeout_s=0.2)


def test_row_cap_marks_result_bounded(db):
    res = db.read_group([("SELECT id FROM bills", (), 2)], caller=PHONE)[1][0]
    assert len(res.rows) == 2 and res.truncated


def test_byte_cap_marks_result_bounded(db):
    big = "SELECT printf('%0*d', 1000, id) AS pad FROM (WITH RECURSIVE c(id) AS (SELECT 1 UNION ALL SELECT id+1 FROM c WHERE id < 900) SELECT id FROM c)"
    res = read(db, big, caller=AGENT)
    assert res.truncated and len(res.rows) < 900


def test_database_size_is_capped(tmp_path):
    d = AppDb.create(tmp_path / "small.db", max_bytes=256 * 1024)
    d.write("CREATE TABLE t (b TEXT)", mode=SCHEMA, caller=AGENT)
    with pytest.raises(SandboxError):
        d.write(
            "WITH RECURSIVE c(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM c WHERE i < 5000) INSERT INTO t SELECT printf('%0*d', 400, i) FROM c",
            mode=WRITE, caller=AGENT,
        )


def test_group_read_is_one_snapshot(db):
    rev, (a, b) = db.read_group(
        [("SELECT SUM(amount) FROM bills", (), 10), ("SELECT COUNT(*) FROM bills", (), 10)], caller=PHONE
    )
    assert a.rows == [[400]] and b.rows == [[3]] and rev == db.data_rev()


def test_blob_values_are_not_leaked_as_bytes(db):
    db.write("CREATE TABLE f (b BLOB)", mode=SCHEMA, caller=AGENT)
    db.write("INSERT INTO f VALUES (x'00ff')", mode=WRITE, caller=AGENT)
    assert read(db, "SELECT b FROM f").rows == [["<blob 2 bytes>"]]


# -- review: SQLITE_LIMIT_LENGTH (a single function call must not allocate a huge value) ---------

def test_value_length_limit_is_set_on_every_connection(db):
    for readonly in (True, False):
        conn = sandbox.connect(db.path, readonly=readonly)
        try:
            assert conn.getlimit(sqlite3.SQLITE_LIMIT_LENGTH) == sandbox.MAX_VALUE_BYTES
        finally:
            conn.close()
    assert sandbox.MAX_VALUE_BYTES <= 32 * 1024 * 1024  # stays far below the service's memory ceiling


@pytest.mark.parametrize("caller", [PHONE, AGENT])
@pytest.mark.parametrize(
    "sql, bindings",
    [
        ("SELECT printf('%.*c', 900000000, 'x')", ()),
        ("SELECT length(printf('%.*c', :n, 'x'))", {"n": 900000000}),
        ("SELECT replace(printf('%.*c', 9000000, 'x'), 'x', 'xxxxxxxxxxxx')", ()),
        ("SELECT hex(printf('%.*c', 9000000, 'x'))", ()),
    ],
)
def test_one_function_call_cannot_build_a_huge_value(db, caller, sql, bindings):
    """SQLite either raises "string or blob too big" or (printf) returns NULL; never the huge value."""
    started = time.monotonic()
    try:
        res = read(db, sql, bindings, caller=caller)
    except SandboxError as exc:
        assert "too big" in str(exc)
    else:
        assert res.rows == [[None]]
    assert time.monotonic() - started < 5


def test_ordinary_large_values_still_work(db):
    assert read(db, "SELECT length(printf('%.*c', 5000000, 'x'))").rows == [[5000000]]


def test_write_cannot_store_a_huge_value_and_leaves_no_trace(db):
    before = db.data_rev()
    with pytest.raises(SandboxError):
        db.write(
            "INSERT INTO bills(amount, note) VALUES (1, replace(printf('%.*c', :n, 'x'), 'x', 'xxxxxxxxxxxx'))",
            {"n": 9000000}, mode=WRITE, caller=AGENT,
        )
    assert db.data_rev() == before
    assert read(db, "SELECT COUNT(*) FROM bills").rows == [[3]]


# -- review: REPLACE deletes rows, so it is destructive like DELETE ---------------------------

@pytest.fixture
def upserts(db):
    db.write("CREATE TABLE u (id INTEGER PRIMARY KEY, v TEXT)", mode=SCHEMA, caller=AGENT)
    # Schema mode refuses UNIQUE (the auto-index is internal); such tables come from elsewhere.
    raw = sqlite3.connect(db.path)
    raw.execute("CREATE TABLE r (k TEXT UNIQUE ON CONFLICT REPLACE, v TEXT)")
    raw.execute("CREATE TABLE plain (k TEXT UNIQUE, v TEXT)")
    raw.commit()
    raw.close()
    return db


def destructive(db, sql):
    res = db.probe_statement(sql, {"id": None, "v": None}, mode=WRITE)
    assert res.tables  # the statement does write somewhere
    return bool(res.deletes)


@pytest.mark.parametrize(
    "sql",
    [
        "DELETE FROM u WHERE id = :id",
        "INSERT OR REPLACE INTO u(id, v) VALUES (:id, :v)",
        "REPLACE INTO u(id, v) VALUES (:id, :v)",
        "replace into u(id, v) values (:id, :v)",
        "INSERT /* keep */ OR\n   REPLACE INTO u(id, v) VALUES (:id, :v)",
        "INSERT -- keep\n OR REPLACE INTO u(id, v) VALUES (:id, :v)",
        "WITH s(a) AS (SELECT 1) REPLACE INTO u(id, v) SELECT a, :v FROM s",
        "UPDATE OR REPLACE u SET id = :id WHERE v = :v",
        "INSERT INTO r(k, v) VALUES (:v, :v)",  # the table itself says ON CONFLICT REPLACE
        "UPDATE r SET k = :v",
    ],
)
def test_statements_that_delete_rows_are_destructive(upserts, sql):
    assert destructive(upserts, sql) is True


@pytest.mark.parametrize(
    "sql",
    [
        "INSERT INTO u(id, v) VALUES (:id, :v)",
        "INSERT INTO u(id, v) VALUES (:id, :v) ON CONFLICT(id) DO UPDATE SET v = excluded.v",
        "UPDATE u SET v = :v WHERE id = :id",
        "UPDATE u SET v = replace(v, 'a', :v) WHERE id = :id",
        "UPDATE u SET v = :v WHERE id = :id OR replace(v, 'a', 'b') = ''",
        "UPDATE u SET v = 'REPLACE INTO' WHERE id = :id",
        "UPDATE u SET v = :v WHERE id = :id -- INSERT OR REPLACE",
        "INSERT INTO plain(k, v) VALUES (:v, :v)",
    ],
)
def test_ordinary_writes_stay_non_destructive(upserts, sql):
    assert destructive(upserts, sql) is False


def test_executed_replace_reports_the_table_it_may_have_emptied(upserts):
    upserts.write("INSERT INTO u VALUES (1, 'old')", mode=WRITE, caller=AGENT)
    rev, res = upserts.write("REPLACE INTO u VALUES (1, 'new')", mode=WRITE, caller=AGENT)
    assert res.deletes == ["u"] and res.tables == ["u"]
    assert read(upserts, "SELECT v FROM u").rows == [["new"]]


# -- review: values SQLite cannot bind must be a sandbox error, not a raw Python exception --------

@pytest.mark.parametrize("bad", [10**30, 2**63, -(2**63) - 1, "\ud800"])
def test_unbindable_values_are_sandbox_errors(db, bad):
    with pytest.raises(SandboxError):
        read(db, "SELECT :x", {"x": bad})
    with pytest.raises(SandboxError):
        db.write("INSERT INTO bills(amount, note) VALUES (1, :x)", {"x": bad}, mode=WRITE, caller=AGENT)
    with pytest.raises(SandboxError):
        db.write(
            "INSERT INTO bills(amount, note) VALUES (1, ?)", [(bad,)], mode=WRITE, caller=AGENT, many=True
        )
    assert read(db, "SELECT COUNT(*) FROM bills").rows == [[3]]


def test_edge_values_that_do_fit_are_bound(db):
    assert read(db, "SELECT :a, :b", {"a": 2**63 - 1, "b": -(2**63)}).rows == [[2**63 - 1, -(2**63)]]
    assert read(db, "SELECT :t", {"t": "Привет 😀"}).rows == [["Привет 😀"]]
