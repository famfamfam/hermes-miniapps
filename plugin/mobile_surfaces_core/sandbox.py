"""SQLite sandbox: per-mode authorizer, time/size limits (ADR-003, section 6).

The plugin runs inside the Hermes process, so this is not a boundary against the
agent itself. It protects against author mistakes, heavy queries and abuse from
the phone client.
"""
from __future__ import annotations

import json
import re
import sqlite3
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable

READ = "read"
WRITE = "write"
SCHEMA = "schema"

PHONE = "phone"
AGENT = "agent"

RESERVED_PREFIX = "_ms_"

PHONE_TIMEOUT_S = 0.25
AGENT_TIMEOUT_S = 2.0
MAX_ROWS_HARD = 1000
MAX_RESULT_BYTES = 256 * 1024
DEFAULT_DB_BYTES = 64 * 1024 * 1024
# SQLITE_LIMIT_LENGTH: the longest string/blob/row any single value or function result may reach.
# The progress handler cannot interrupt one VM step, so without this a single printf('%.*c', 9e8, 'x')
# allocates ~GB (and the service is OOM-killed). Peak is roughly three copies of the value (SQLite,
# the Python str, the JSON dump), so 16 MiB stays far below the service's memory ceiling. A row of a
# linked foreign database larger than this cannot be read through the sandbox.
MAX_VALUE_BYTES = 16 * 1024 * 1024

_OK = sqlite3.SQLITE_OK
_DENY = sqlite3.SQLITE_DENY

ALLOWED_FUNCTIONS = frozenset(
    """
    abs avg coalesce count date datetime group_concat hex ifnull iif instr json json_array
    json_array_length json_extract json_group_array json_group_object json_insert json_object
    json_patch json_quote json_remove json_replace json_set json_type json_valid julianday length
    like glob lower ltrim max min nullif printf format quote round rtrim sign strftime substr
    substring sum time total trim typeof unicode unixepoch upper ->  ->> likely unlikely
    likelihood row_number rank dense_rank percent_rank cume_dist ntile lag lead first_value
    last_value nth_value json_each json_tree
    replace char concat concat_ws ceil ceiling floor trunc mod pow power sqrt exp ln log log10 log2
    """.split()
)


class SandboxError(Exception):
    """Statement rejected or failed inside the sandbox."""


class QueryTimeout(SandboxError):
    pass


@dataclass
class SqlResult:
    columns: list[str] = field(default_factory=list)
    rows: list[list[Any]] = field(default_factory=list)
    truncated: bool = False
    rowcount: int = 0
    tables: list[str] = field(default_factory=list)
    deletes: list[str] = field(default_factory=list)


def _is_reserved(name: str | None) -> bool:
    return bool(name) and name.lower().startswith(RESERVED_PREFIX)


def _is_internal_sqlite(name: str | None) -> bool:
    return bool(name) and name.lower().startswith("sqlite_")


class _Authorizer:
    """Per-statement authorizer for one mode and caller; records touched tables."""

    def __init__(self, mode: str, caller: str) -> None:
        self.mode = mode
        self.caller = caller
        self.touched: set[str] = set()
        self.deletes: set[str] = set()

    def __call__(self, action: int, arg1: str | None, arg2: str | None, dbname: str | None, source: str | None) -> int:
        s = sqlite3
        if action in (s.SQLITE_SELECT, s.SQLITE_RECURSIVE):
            return _OK
        if action == s.SQLITE_READ:
            if _is_reserved(arg1):
                return _DENY
            if _is_internal_sqlite(arg1) and self.caller == PHONE:
                return _DENY
            return _OK
        if action == s.SQLITE_FUNCTION:
            return _OK if (arg2 or "").lower() in ALLOWED_FUNCTIONS else _DENY
        if self.mode == READ:
            return _DENY
        if action in (s.SQLITE_INSERT, s.SQLITE_UPDATE, s.SQLITE_DELETE):
            if _is_reserved(arg1):
                return _DENY
            if _is_internal_sqlite(arg1):
                # DDL itself records into the schema table. SQLite refuses direct writes to it
                # ("may not be modified"), so allowing the callback only in schema mode is safe.
                return _OK if self.mode == SCHEMA else _DENY
            if not _is_internal_sqlite(arg1):
                self.touched.add(arg1)
            if action == s.SQLITE_DELETE and not _is_internal_sqlite(arg1):
                self.deletes.add(arg1)
            return _OK
        if self.mode == SCHEMA and action in _SCHEMA_ACTIONS:
            # The meaning of the arguments differs per action (SQLite docs, "Authorizer Action Codes"):
            #   CREATE/DROP TABLE|VIEW   arg1 = the object
            #   CREATE/DROP INDEX        arg1 = the index,  arg2 = its table
            #   ALTER TABLE              arg1 = the database ("main"), arg2 = the table
            # Every named object is checked, and the table (not "main") is what gets recorded.
            if action == s.SQLITE_ALTER_TABLE:
                named, table = (arg2,), arg2
            elif action in (s.SQLITE_CREATE_INDEX, s.SQLITE_DROP_INDEX):
                named, table = (arg1, arg2), arg2
            elif action == s.SQLITE_REINDEX:  # SQLite fires this to fill a freshly created index
                named, table = (arg1,), None
            else:
                named, table = (arg1,), arg1
            if any(_is_reserved(n) or _is_internal_sqlite(n) for n in named):
                return _DENY
            if table:
                self.touched.add(table)
            return _OK
        return _DENY


_SCHEMA_ACTIONS = frozenset(
    {
        sqlite3.SQLITE_CREATE_TABLE,
        sqlite3.SQLITE_CREATE_INDEX,
        sqlite3.SQLITE_CREATE_VIEW,
        sqlite3.SQLITE_DROP_TABLE,
        sqlite3.SQLITE_DROP_INDEX,
        sqlite3.SQLITE_DROP_VIEW,
        sqlite3.SQLITE_ALTER_TABLE,
        sqlite3.SQLITE_REINDEX,
    }
)


def _jsonable(value: Any) -> Any:
    if isinstance(value, (bytes, bytearray, memoryview)):
        return f"<blob {len(value)} bytes>"
    return value


def connect(path: Path, *, readonly: bool, max_db_bytes: int = DEFAULT_DB_BYTES) -> sqlite3.Connection:
    """Open a connection with the fixed hardening pragmas (applied before any authorizer)."""
    if readonly:
        uri = f"{path.resolve().as_uri()}?mode=ro"
        conn = sqlite3.connect(uri, uri=True, isolation_level=None, check_same_thread=False)
        conn.execute("PRAGMA query_only = ON")
    else:
        conn = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        page_size = conn.execute("PRAGMA page_size").fetchone()[0]
        conn.execute(f"PRAGMA max_page_count = {max(1, max_db_bytes // page_size)}")
    conn.execute("PRAGMA trusted_schema = OFF")
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA busy_timeout = 2000")
    conn.setlimit(sqlite3.SQLITE_LIMIT_LENGTH, MAX_VALUE_BYTES)
    return conn


def _arm(conn: sqlite3.Connection, authorizer: _Authorizer, timeout_s: float) -> None:
    deadline = time.monotonic() + timeout_s
    conn.set_authorizer(authorizer)
    conn.set_progress_handler(lambda: 1 if time.monotonic() > deadline else 0, 1000)


def _disarm(conn: sqlite3.Connection) -> None:
    conn.set_authorizer(None)
    conn.set_progress_handler(None, 0)


def _translate(exc: sqlite3.Error) -> SandboxError:
    text = str(exc)
    if "interrupted" in text.lower():
        return QueryTimeout("query exceeded the time limit")
    return SandboxError(text)


def _unbindable() -> SandboxError:
    """Binding a Python value can fail outside sqlite3.Error (OverflowError, UnicodeEncodeError)."""
    return SandboxError("a parameter value cannot be used: integer out of range or text that is not valid Unicode")


# -- statements that delete rows without a DELETE ---------------------------------------------
#
# REPLACE INTO / INSERT OR REPLACE / UPDATE OR REPLACE remove the rows they conflict with, and a
# table declared with `ON CONFLICT REPLACE` does the same for a plain INSERT/UPDATE. The authorizer
# reports only INSERT/UPDATE for those, so they are recognised from the statement text and the
# tables' own DDL. Both checks err towards "destructive".

_SQL_TOKEN = re.compile(
    r"""--[^\n]*|/\*.*?(?:\*/|\Z)|'(?:[^']|'')*(?:'|\Z)|"(?:[^"]|"")*(?:"|\Z)|`(?:[^`]|``)*(?:`|\Z)"""
    r"""|\[[^\]]*(?:\]|\Z)|[A-Za-z_][A-Za-z0-9_$]*|\S""",
    re.S,
)


def _sql_words(sql: str) -> list[str]:
    """Upper-cased keywords/identifiers; literals and punctuation become "?", comments vanish."""
    words: list[str] = []
    for match in _SQL_TOKEN.finditer(sql):
        token = match.group()
        if token.startswith(("--", "/*")):
            continue
        words.append(token.upper() if token.isascii() and (token[0].isalpha() or token[0] == "_") else "?")
    return words


def _statement_replaces(sql: str) -> bool:
    words = _sql_words(sql)
    for i, word in enumerate(words):
        if word != "REPLACE":
            continue
        if words[i + 1 : i + 2] == ["INTO"]:
            return True
        if i >= 2 and words[i - 1] == "OR" and words[i - 2] in ("INSERT", "UPDATE"):
            return True
    return False


def _tables_replace_on_conflict(conn: sqlite3.Connection, tables: Iterable[str]) -> bool:
    names = [t.lower() for t in tables]
    if not names:
        return False
    marks = ",".join("?" * len(names))
    for (ddl,) in conn.execute(
        f"SELECT sql FROM sqlite_master WHERE type = 'table' AND lower(name) IN ({marks})", names
    ):
        words = _sql_words(ddl or "")
        if any(words[i : i + 3] == ["ON", "CONFLICT", "REPLACE"] for i in range(len(words))):
            return True
    return False


def timeout_for(caller: str) -> float:
    return PHONE_TIMEOUT_S if caller == PHONE else AGENT_TIMEOUT_S


def run_select(
    conn: sqlite3.Connection,
    sql: str,
    bindings: dict[str, Any] | Iterable[Any],
    *,
    caller: str,
    max_rows: int = MAX_ROWS_HARD,
    max_bytes: int = MAX_RESULT_BYTES,
    timeout_s: float | None = None,
) -> SqlResult:
    """Run one read statement. The connection must already be inside the caller's transaction."""
    max_rows = min(max_rows, MAX_ROWS_HARD)
    authorizer = _Authorizer(READ, caller)
    _arm(conn, authorizer, timeout_s if timeout_s is not None else timeout_for(caller))
    try:
        cur = conn.execute(sql, bindings)
        columns = [d[0] for d in cur.description] if cur.description else []
        rows: list[list[Any]] = []
        size = 0
        truncated = False
        while True:
            row = cur.fetchone()
            if row is None:
                break
            if len(rows) >= max_rows:
                truncated = True
                break
            clean = [_jsonable(v) for v in row]
            size += len(json.dumps(clean, ensure_ascii=False))
            if size > max_bytes:
                truncated = True
                break
            rows.append(clean)
        return SqlResult(columns=columns, rows=rows, truncated=truncated)
    except sqlite3.Error as exc:
        raise _translate(exc) from None
    except (OverflowError, UnicodeEncodeError):
        raise _unbindable() from None
    finally:
        _disarm(conn)


def run_write(
    conn: sqlite3.Connection,
    sql: str,
    bindings: Any,
    *,
    mode: str,
    caller: str,
    many: bool = False,
    timeout_s: float | None = None,
) -> SqlResult:
    """Run one write/DDL statement (optionally executemany). Caller owns the transaction."""
    if mode not in (WRITE, SCHEMA):
        raise SandboxError(f"unsupported write mode: {mode}")
    authorizer = _Authorizer(mode, caller)
    _arm(conn, authorizer, timeout_s if timeout_s is not None else timeout_for(caller))
    try:
        cur = conn.executemany(sql, bindings) if many else conn.execute(sql, bindings)
        rowcount = cur.rowcount
    except sqlite3.Error as exc:
        raise _translate(exc) from None
    except (OverflowError, UnicodeEncodeError):
        raise _unbindable() from None
    finally:
        _disarm(conn)
    deletes = set(authorizer.deletes)
    if authorizer.touched:
        # Authorizer is disarmed: trusted library code reading the schema inside the caller's transaction.
        try:
            if _statement_replaces(sql) or _tables_replace_on_conflict(conn, authorizer.touched):
                deletes |= authorizer.touched
        except sqlite3.Error as exc:
            raise _translate(exc) from None
    return SqlResult(rowcount=rowcount, tables=sorted(authorizer.touched), deletes=sorted(deletes))
