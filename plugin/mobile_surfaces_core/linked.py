"""Read-only access to an SQLite database that another program owns (ADR-002 §13a).

A linked app reads a file written by someone else, for example the receipts database of an
existing Hermes skill. The file is opened read-only, nothing is added to it (no `_ms_*` tables),
and the program that owns it keeps working unchanged. Because the service cannot count commits
inside a file it does not write to, change detection is by file signature (see `signature`) and
the data revision lives in the registry.
"""
from __future__ import annotations

import sqlite3
from pathlib import Path
from typing import Any, Callable

from . import sandbox
from .sandbox import SqlResult

SQLITE_MAGIC = b"SQLite format 3\x00"
READ_ONLY_MESSAGE = "this app reads a database owned by another service; it is read-only"


class SourceError(Exception):
    """The file cannot be used as a linked source; the message is safe to show."""


class SourceUnavailable(sandbox.SandboxError):
    """The owner moved, removed or damaged the file after linking. A SandboxError, so every caller
    that already reports sandbox problems (phone data call, authoring check) reports this one
    too instead of failing with a raw sqlite3 exception. SQLite's text never contains the path."""

    def __init__(self, exc: sqlite3.Error) -> None:
        super().__init__(f"the database this app reads is not available right now: {exc}")


def check_source(path: Path) -> Path:
    """Resolve and sanity-check a source path. Reads only the 16-byte file header."""
    if not path.is_absolute():
        raise SourceError("source path must be absolute")
    try:
        resolved = path.resolve(strict=True)
    except OSError:
        raise SourceError("source file does not exist") from None
    if not resolved.is_file():
        raise SourceError("source must be a regular file")
    try:
        with resolved.open("rb") as handle:
            header = handle.read(16)
    except OSError as exc:
        raise SourceError(f"source file cannot be read: {exc.strerror or exc}") from None
    if header != SQLITE_MAGIC:
        raise SourceError("source is not an SQLite database")
    return resolved


def signature(path: Path) -> str:
    """Cheap fingerprint that changes when the owner commits to the database.

    mtime and size of the main file and of its `-wal`, plus the file change counter from the
    database header (bytes 24-27), which a rollback-journal database bumps on every commit.
    A WAL database appends to `-wal` instead, which the second part sees. Granularity is the
    filesystem timestamp, so two commits inside one tick with identical size are one change; for
    invalidation that is enough because the next read returns the latest data anyway.
    """
    parts: list[str] = []
    for candidate in (path, path.with_name(path.name + "-wal")):
        try:
            stat = candidate.stat()
            parts.append(f"{stat.st_mtime_ns}:{stat.st_size}")
        except OSError:
            parts.append("-")
    try:
        with path.open("rb") as handle:
            handle.seek(24)
            parts.append(handle.read(4).hex() or "-")
    except OSError:
        parts.append("-")
    return "|".join(parts)


class LinkedDb:
    """Same read surface as `AppDb`, over a foreign database. Writes are refused."""

    def __init__(self, path: Path, current_rev: Callable[[], int]) -> None:
        self.path = path
        self._current_rev = current_rev

    def read_group(
        self, specs: list[tuple[str, dict[str, Any], int]], *, caller: str, timeout_s: float | None = None
    ) -> tuple[int, list[SqlResult]]:
        """Several SELECTs in one read transaction, with the revision taken *before* reading.

        A change can land between the revision check and the read. The result is then newer than
        the revision it carries, which is safe: the client refetches on the next event and gets
        the same data again. The opposite order could label old data with a new revision and the
        client would never refetch.
        """
        rev = self._current_rev()
        try:
            conn = sandbox.connect(self.path, readonly=True)
            try:
                conn.execute("BEGIN")
                results = [
                    sandbox.run_select(conn, sql, bindings, caller=caller, max_rows=max_rows, timeout_s=timeout_s)
                    for sql, bindings, max_rows in specs
                ]
                conn.execute("COMMIT")
                return rev, results
            finally:
                conn.close()
        except sqlite3.Error as exc:
            raise SourceUnavailable(exc) from None

    def probe_statement(self, sql: str, bindings: dict[str, Any], *, mode: str, shape_rows: int = 1) -> SqlResult:
        if mode != sandbox.READ:
            raise sandbox.SandboxError(READ_ONLY_MESSAGE)
        try:
            conn = sandbox.connect(self.path, readonly=True)
            try:
                conn.execute("BEGIN")
                try:
                    return sandbox.run_select(conn, sql, bindings, caller=sandbox.PHONE, max_rows=shape_rows)
                finally:
                    conn.execute("ROLLBACK")
            finally:
                conn.close()
        except sqlite3.Error as exc:
            raise SourceUnavailable(exc) from None

    def write(self, *args: Any, **kwargs: Any) -> Any:
        raise sandbox.SandboxError(READ_ONLY_MESSAGE)
