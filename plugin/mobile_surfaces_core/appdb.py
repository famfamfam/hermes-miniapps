"""Per-app SQLite database: dataRev, outbox and sandboxed read/write (ADR-002 §5, ADR-003)."""
from __future__ import annotations

import json
import sqlite3
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import sandbox
from .sandbox import DEFAULT_DB_BYTES, SqlResult

_SCHEMA = """
CREATE TABLE IF NOT EXISTS _ms_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS _ms_outbox (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    type TEXT NOT NULL,
    payload TEXT NOT NULL
);
"""


# A result is kept this long so that a phone that lost the answer can ask again with the same key (ADR-004 §3).
IDEMPOTENCY_KEEP_S = 24 * 3600
IDEMPOTENCY_REUSED = "this request key was already used for a different request"
_IDEMPOTENCY = """
CREATE TABLE IF NOT EXISTS _ms_idempotency (
    key TEXT PRIMARY KEY,
    body_hash TEXT NOT NULL,
    result TEXT NOT NULL,
    created_at REAL NOT NULL
)
"""


class IdempotencyConflict(Exception):
    """The key of a mutation request was used before for a different request."""


@dataclass(frozen=True)
class MutationOutcome:
    """The answer to a mutation: the new dataRev, rows changed and the last inserted row id (None if none)."""

    data_rev: int
    rows_affected: int
    last_insert_id: int | None
    replayed: bool = False

    def as_dict(self) -> dict[str, Any]:
        return {"dataRev": self.data_rev, "rowsAffected": self.rows_affected, "lastInsertId": self.last_insert_id}


@dataclass(frozen=True)
class OutboxSnapshot:
    """Outbox state read in one transaction: what is pending and where the database stands."""

    generation: str
    seq: int  # highest outbox id ever issued (sqlite_sequence), survives trimming
    data_rev: int
    rows: list[tuple[int, str, str, str]]


class AppDb:
    """Handle to one app database. Opening is read-only on disk: reads never touch the write lock.

    The file is created and its service tables are bootstrapped only by `AppDb.create`.
    """

    def __init__(self, path: Path, max_bytes: int = DEFAULT_DB_BYTES) -> None:
        self.path = path
        self.max_bytes = max_bytes

    @classmethod
    def create(cls, path: Path, max_bytes: int = DEFAULT_DB_BYTES) -> "AppDb":
        path.parent.mkdir(parents=True, exist_ok=True)
        conn = sqlite3.connect(path, isolation_level=None)
        try:
            conn.execute("PRAGMA journal_mode = WAL")
            conn.executescript(_SCHEMA)
            conn.execute("INSERT OR IGNORE INTO _ms_meta(key, value) VALUES ('dataRev', '0')")
            conn.execute("INSERT OR IGNORE INTO _ms_meta(key, value) VALUES ('generation', ?)", (uuid.uuid4().hex[:12],))
        finally:
            conn.close()
        return cls(path, max_bytes)

    def generation(self) -> str:
        conn = sandbox.connect(self.path, readonly=True)
        try:
            return conn.execute("SELECT value FROM _ms_meta WHERE key = 'generation'").fetchone()[0]
        finally:
            conn.close()

    def outbox_snapshot(self, last_id: int, limit: int = 500) -> OutboxSnapshot:
        """Pending rows plus generation, sequence and dataRev from a single read transaction.

        Trusted library code, no authorizer. The sequence lets the caller notice a database that
        was replaced by an older copy: it is then lower than the position already journalled.
        """
        conn = sandbox.connect(self.path, readonly=True)
        try:
            conn.execute("BEGIN")
            meta = dict(conn.execute("SELECT key, value FROM _ms_meta"))
            seq_row = conn.execute("SELECT seq FROM sqlite_sequence WHERE name = '_ms_outbox'").fetchone()
            rows = [
                tuple(r)
                for r in conn.execute(
                    "SELECT id, ts, type, payload FROM _ms_outbox WHERE id > ? ORDER BY id LIMIT ?", (last_id, limit)
                )
            ]
            conn.execute("COMMIT")
            return OutboxSnapshot(meta["generation"], seq_row[0] if seq_row else 0, int(meta["dataRev"]), rows)
        finally:
            conn.close()

    def outbox_trim(self, upto_id: int) -> None:
        """Drop rows already recorded in the registry. Called only after that commit succeeded.

        Best effort: the registry position already prevents re-journalling, so if a writer holds
        the database right now the trim is simply retried by a later pump instead of making a
        poll wait for the lock or fail.
        """
        conn = sandbox.connect(self.path, readonly=False, max_db_bytes=self.max_bytes)
        try:
            conn.execute("PRAGMA busy_timeout = 100")
            try:
                conn.execute("DELETE FROM _ms_outbox WHERE id <= ?", (upto_id,))
            except sqlite3.OperationalError:
                pass
        finally:
            conn.close()

    def data_rev(self) -> int:
        conn = sandbox.connect(self.path, readonly=True)
        try:
            return int(conn.execute("SELECT value FROM _ms_meta WHERE key = 'dataRev'").fetchone()[0])
        finally:
            conn.close()

    def read_group(
        self, specs: list[tuple[str, dict[str, Any], int]], *, caller: str, timeout_s: float | None = None
    ) -> tuple[int, list[SqlResult]]:
        """Run several SELECTs in one read transaction: one consistent dataRev for the group."""
        conn = sandbox.connect(self.path, readonly=True)
        try:
            conn.execute("BEGIN")
            rev = int(conn.execute("SELECT value FROM _ms_meta WHERE key = 'dataRev'").fetchone()[0])
            results = [
                sandbox.run_select(conn, sql, bindings, caller=caller, max_rows=max_rows, timeout_s=timeout_s)
                for sql, bindings, max_rows in specs
            ]
            conn.execute("COMMIT")
            return rev, results
        finally:
            conn.close()

    def write(
        self,
        sql: str,
        bindings: Any = (),
        *,
        mode: str,
        caller: str,
        many: bool = False,
        timeout_s: float | None = None,
    ) -> tuple[int, SqlResult]:
        """One write/DDL statement in one transaction; bumps dataRev and queues data.changed."""
        conn = sandbox.connect(self.path, readonly=False, max_db_bytes=self.max_bytes)
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                result = sandbox.run_write(
                    conn, sql, bindings, mode=mode, caller=caller, many=many, timeout_s=timeout_s
                )
                rev = self._bump(conn, result.tables)
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
            return rev, result
        finally:
            conn.close()

    def write_many(
        self,
        statements: list[str],
        bindings: dict[str, Any],
        *,
        caller: str,
        key: str,
        body_hash: str,
        now: float | None = None,
        timeout_s: float | None = None,
    ) -> "MutationOutcome":
        """The statements of one mutation in one transaction, exactly once per idempotency key.

        The key and the result are stored in the same transaction as the data (`_ms_idempotency`), so a
        write is either fully recorded with its key or not there at all. The same key with the same request
        answers with the stored result and writes nothing; the same key with another request is refused.
        Rows older than a day are dropped here, which bounds the table.
        """
        stamp = time.time() if now is None else now
        conn = sandbox.connect(self.path, readonly=False, max_db_bytes=self.max_bytes)
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                conn.execute(_IDEMPOTENCY)
                conn.execute("DELETE FROM _ms_idempotency WHERE created_at < ?", (stamp - IDEMPOTENCY_KEEP_S,))
                seen = conn.execute("SELECT body_hash, result FROM _ms_idempotency WHERE key = ?", (key,)).fetchone()
                if seen is not None:
                    if seen[0] != body_hash:
                        raise IdempotencyConflict(IDEMPOTENCY_REUSED)
                    stored = json.loads(seen[1])
                    conn.execute("COMMIT")
                    return MutationOutcome(stored["dataRev"], stored["rowsAffected"], stored["lastInsertId"], True)
                done = sandbox.run_write_group(conn, statements, bindings, caller=caller, timeout_s=timeout_s)
                outcome = MutationOutcome(self._bump(conn, done.tables), done.rows_affected, done.last_insert_id)
                conn.execute(
                    "INSERT INTO _ms_idempotency(key, body_hash, result, created_at) VALUES (?,?,?,?)",
                    (key, body_hash, json.dumps(outcome.as_dict()), stamp),
                )
                conn.execute("COMMIT")
                return outcome
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        finally:
            conn.close()

    def probe_statement(self, sql: str, bindings: dict[str, Any], *, mode: str, shape_rows: int = 1) -> SqlResult:
        """Validate a definition's statement without changing data.

        Reads execute with NULL parameters. Writes are only compiled (EXPLAIN) inside a
        transaction that is always rolled back; the authorizer reports touched/deleted tables.
        """
        if mode == sandbox.READ:
            conn = sandbox.connect(self.path, readonly=True)
            try:
                conn.execute("BEGIN")
                try:
                    # Validate under the phone's limits: that is how the query will really run.
                    return sandbox.run_select(
                        conn, sql, bindings, caller=sandbox.PHONE, max_rows=shape_rows
                    )
                finally:
                    conn.execute("ROLLBACK")
            finally:
                conn.close()
        conn = sandbox.connect(self.path, readonly=False, max_db_bytes=self.max_bytes)
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                return sandbox.run_write(conn, "EXPLAIN " + sql, bindings, mode=mode, caller=sandbox.PHONE)
            finally:
                conn.execute("ROLLBACK")
        finally:
            conn.close()

    @staticmethod
    def _bump(conn: sqlite3.Connection, tables: list[str]) -> int:
        conn.execute("UPDATE _ms_meta SET value = CAST(CAST(value AS INTEGER) + 1 AS TEXT) WHERE key = 'dataRev'")
        rev = int(conn.execute("SELECT value FROM _ms_meta WHERE key = 'dataRev'").fetchone()[0])
        conn.execute(
            "INSERT INTO _ms_outbox(ts, type, payload) VALUES (?, 'data.changed', ?)",
            (
                datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
                json.dumps({"dataRev": rev, "tables": tables}),
            ),
        )
        return rev
