"""Registry, publication and named-query execution (ADR-002, ADR-003, ADR-007 §5)."""
from __future__ import annotations

import base64
import hashlib
import json
import re
import secrets
import shutil
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

from . import linked
from . import params as P
from . import sandbox
from .appdb import AppDb
from .bundle import BuiltBundle, BundleError, verify_bundle
from .errors import ApprovalRefused, Conflict, NotFound, StoreError, TooManyAttempts  # noqa: F401 - re-exported
from .files import AppFiles
from .linked import LinkedDb

APP_ID = re.compile(r"^[a-z][a-z0-9_]{1,39}$")
BUNDLE_ID = re.compile(r"^sha256:[0-9a-f]{64}$")
SHAPES = ("rows", "row", "value")
DEFAULT_MAX_ROWS = 200
# ADR-002 §5: events of the shared journal older than 24 hours are deleted. The sweep runs only once the
# oldest row is an hour past that, so a busy journal is trimmed about once an hour, not on every poll.
JOURNAL_KEEP_S = 24 * 3600
JOURNAL_SWEEP_SLACK_S = 3600

_REGISTRY = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS apps (
    app_id TEXT PRIMARY KEY,
    title TEXT NOT NULL,
    icon TEXT,
    brief TEXT,
    revision INTEGER NOT NULL DEFAULT 0,
    bundle_id TEXT,
    definitions TEXT NOT NULL DEFAULT '{"queries":{},"mutations":{}}',
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
-- The id is a digest of content, so two apps built from the same template share one id:
-- the key must include the app or the second publish silently loses its bundle row.
CREATE TABLE IF NOT EXISTS bundles (
    app_id TEXT NOT NULL,
    bundle_id TEXT NOT NULL,
    size INTEGER NOT NULL,
    manifest TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (app_id, bundle_id)
);
CREATE TABLE IF NOT EXISTS events (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    ts TEXT NOT NULL,
    type TEXT NOT NULL,
    app_id TEXT,
    bundle_id TEXT,
    payload TEXT
);
CREATE TABLE IF NOT EXISTS outbox_positions (
    app_id TEXT PRIMARY KEY,
    generation TEXT NOT NULL,
    last_id INTEGER NOT NULL,
    data_rev INTEGER NOT NULL DEFAULT 0
);
-- Apps whose data is a database owned by another program (read-only). Such a file cannot carry our
-- dataRev/outbox, so the revision and the last seen file signature are kept here instead.
CREATE TABLE IF NOT EXISTS app_sources (
    app_id TEXT PRIMARY KEY,
    path TEXT NOT NULL,
    signature TEXT NOT NULL,
    data_rev INTEGER NOT NULL DEFAULT 1,
    created_at TEXT NOT NULL
);
-- Public keys of devices allowed to approve a publication (ADR-007 §5). The private key never leaves
-- the phone; the server can verify an approval but cannot produce one.
CREATE TABLE IF NOT EXISTS approvers (
    device_id TEXT PRIMARY KEY,
    public_key TEXT NOT NULL,
    created_at TEXT NOT NULL
);
-- One-time challenges: an approval signs a nonce bound to one app, build and draft revision.
CREATE TABLE IF NOT EXISTS approval_nonces (
    nonce TEXT PRIMARY KEY,
    app_id TEXT NOT NULL,
    build_id TEXT NOT NULL,
    draft_rev INTEGER NOT NULL,
    expires_at REAL NOT NULL
);
-- One-time codes that hand a phone its token and pair it as approver. Only a digest is kept: the
-- code itself is shown once, to whoever asked for it.
CREATE TABLE IF NOT EXISTS pair_codes (
    code_hash TEXT PRIMARY KEY,
    expires_at REAL NOT NULL
);
-- Files kept for an app (uploaded from the phone, or imported from a folder the administrator linked). The
-- bytes live in apps/<id>/files/<file_id>; the name here is only what is shown and offered when saving.
CREATE TABLE IF NOT EXISTS app_files (
    file_id TEXT PRIMARY KEY,
    app_id TEXT NOT NULL,
    name TEXT NOT NULL,
    mime TEXT NOT NULL,
    size INTEGER NOT NULL,
    sha256 TEXT NOT NULL,
    source TEXT NOT NULL,
    created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS app_files_by_app ON app_files(app_id, sha256);
-- Read-only folders of the host that an app's file locators may point into (set by the administrator).
CREATE TABLE IF NOT EXISTS app_file_roots (
    app_id TEXT NOT NULL,
    name TEXT NOT NULL,
    path TEXT NOT NULL,
    strip_prefix TEXT,
    created_at TEXT NOT NULL,
    PRIMARY KEY (app_id, name)
);
"""

TRASH_KEEP_DAYS = 30
PAIR_CODE_TTL_S = 15 * 60
CLAIM_FAILURES_BEFORE_LOCK = 5
CLAIM_LOCK_S = 60.0
_TRASH_NAME = re.compile(r"^([a-z][a-z0-9_]{1,39})-(\d{8}T\d{6}Z)-[0-9a-f]{4}$")
# Columns restored from a trash entry. Fixed lists: the file is read back from disk and must not name columns.
_TRASH_TABLES = {
    "apps": ("app_id", "title", "icon", "brief", "revision", "bundle_id", "definitions", "created_at", "updated_at"),
    "bundles": ("app_id", "bundle_id", "size", "manifest", "created_at"),
    "app_sources": ("app_id", "path", "signature", "data_rev", "created_at"),
    "outbox_positions": ("app_id", "generation", "last_id", "data_rev"),
    "app_files": ("file_id", "app_id", "name", "mime", "size", "sha256", "source", "created_at"),
    "app_file_roots": ("app_id", "name", "path", "strip_prefix", "created_at"),
}


AGENT_CELL_CHARS = 300


def _clip_rows(rows: list[list[Any]]) -> tuple[list[list[Any]], int]:
    clipped = 0
    out: list[list[Any]] = []
    for row in rows:
        new: list[Any] = []
        for value in row:
            if isinstance(value, str) and len(value) > AGENT_CELL_CHARS:
                new.append(value[:AGENT_CELL_CHARS] + f"... [{len(value) - AGENT_CELL_CHARS} more characters]")
                clipped += 1
            else:
                new.append(value)
        out.append(new)
    return out, clipped


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


class Store:
    def __init__(self, home: Path) -> None:
        self.root = home.resolve() / "mobile-surfaces"
        self.root.mkdir(parents=True, exist_ok=True)
        self._reg_path = self.root / "registry.db"
        self._claim_lock = threading.Lock()
        self._claim_failures: list[float] = []
        self._claim_locked_until = 0.0
        conn = self._registry()
        try:
            conn.execute("PRAGMA journal_mode = WAL")
            conn.executescript(_REGISTRY)
            conn.execute("INSERT OR IGNORE INTO meta(key, value) VALUES ('epoch', ?)", (uuid.uuid4().hex[:12],))
        finally:
            conn.close()
        self.files = AppFiles(self)

    # -- plumbing -----------------------------------------------------------

    def _registry(self) -> sqlite3.Connection:
        conn = sqlite3.connect(self._reg_path, isolation_level=None, check_same_thread=False)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA busy_timeout = 2000")
        return conn

    def _app_dir(self, app_id: str) -> Path:
        if not APP_ID.match(app_id):
            raise NotFound("unknown app")
        return self.root / "apps" / app_id

    def app_dir(self, app_id: str) -> Path:
        """Directory of an existing app (bundles, sources, drafts). Unknown ids are NotFound."""
        self._row(app_id)
        return self._app_dir(app_id)

    def app_db(self, app_id: str) -> AppDb | LinkedDb:
        """Handle to an existing app database. Opening writes nothing, so reads stay lock-free.

        A linked app answers with a read-only handle over the file its owner maintains.
        """
        self._row(app_id)
        source = self._source_path(app_id)
        if source is not None:
            return LinkedDb(source, lambda: self._linked_rev(app_id)[0])
        return AppDb(self._app_dir(app_id) / "data.db")

    def _source_path(self, app_id: str) -> Path | None:
        conn = self._registry()
        try:
            row = conn.execute("SELECT path FROM app_sources WHERE app_id = ?", (app_id,)).fetchone()
        finally:
            conn.close()
        return Path(row["path"]) if row else None

    def _linked_rev(self, app_id: str) -> tuple[int, bool]:
        """Current dataRev of a linked app and whether this call advanced it.

        The file's signature is compared with the one stored; a difference advances the revision
        and journals one `data.changed` event, both in one registry transaction taken under the
        write lock, so concurrent callers (phone reads, event polls) advance it once per change.
        """
        conn = self._registry()
        try:
            row = conn.execute(
                "SELECT path, signature, data_rev FROM app_sources WHERE app_id = ?", (app_id,)
            ).fetchone()
            if row is None:
                raise NotFound("unknown app")
            current = linked.signature(Path(row["path"]))
            if current == row["signature"]:  # idle fast path: no write lock
                return row["data_rev"], False
            conn.execute("BEGIN IMMEDIATE")
            try:
                row = conn.execute(
                    "SELECT signature, data_rev FROM app_sources WHERE app_id = ?", (app_id,)
                ).fetchone()
                if current == row["signature"]:  # another caller got here first
                    conn.execute("COMMIT")
                    return row["data_rev"], False
                rev = row["data_rev"] + 1
                conn.execute(
                    "UPDATE app_sources SET signature = ?, data_rev = ? WHERE app_id = ?", (current, rev, app_id)
                )
                conn.execute(
                    "INSERT INTO events(ts, type, app_id, bundle_id, payload) VALUES (?,?,?,NULL,?)",
                    (_now(), "data.changed", app_id, json.dumps({"dataRev": rev, "tables": []})),
                )
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
            return rev, True
        finally:
            conn.close()

    def epoch(self) -> str:
        conn = self._registry()
        try:
            return conn.execute("SELECT value FROM meta WHERE key = 'epoch'").fetchone()[0]
        finally:
            conn.close()

    def _row(self, app_id: str) -> sqlite3.Row:
        if not APP_ID.match(app_id):
            raise NotFound("unknown app")
        conn = self._registry()
        try:
            row = conn.execute("SELECT * FROM apps WHERE app_id = ?", (app_id,)).fetchone()
        finally:
            conn.close()
        if row is None:
            raise NotFound("unknown app")
        return row

    # -- apps ---------------------------------------------------------------

    def create_app(self, app_id: str, title: str, *, icon: str | None = None, brief: str | None = None) -> None:
        if not APP_ID.match(app_id):
            raise StoreError("appId must match ^[a-z][a-z0-9_]{1,39}$")
        if not title.strip() or len(title) > 80:
            raise StoreError("title must be 1-80 characters")
        conn = self._registry()
        try:
            try:
                conn.execute(
                    "INSERT INTO apps(app_id, title, icon, brief, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                    (app_id, title.strip(), icon, brief, _now(), _now()),
                )
            except sqlite3.IntegrityError:
                raise Conflict("app already exists") from None
        finally:
            conn.close()
        AppDb.create(self._app_dir(app_id) / "data.db")

    def link_source(
        self, app_id: str, title: str, path: str | Path, *, icon: str | None = None, brief: str | None = None
    ) -> None:
        """Create an app whose data is an existing SQLite database, opened read-only.

        The file is never modified and gets no service tables. Writes, schema changes and mutation
        definitions are refused for this app.
        """
        if not APP_ID.match(app_id):
            raise StoreError("appId must match ^[a-z][a-z0-9_]{1,39}$")
        if not title.strip() or len(title) > 80:
            raise StoreError("title must be 1-80 characters")
        try:
            source = linked.check_source(Path(path))
        except linked.SourceError as exc:
            raise StoreError(str(exc)) from None
        if source == self.root or self.root in source.parents:
            raise StoreError("a source must not live inside the service's own storage")
        conn = self._registry()
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                conn.execute(
                    "INSERT INTO apps(app_id, title, icon, brief, created_at, updated_at) VALUES (?,?,?,?,?,?)",
                    (app_id, title.strip(), icon, brief, _now(), _now()),
                )
                conn.execute(
                    "INSERT INTO app_sources(app_id, path, signature, created_at) VALUES (?,?,?,?)",
                    (app_id, str(source), linked.signature(source), _now()),
                )
                conn.execute("COMMIT")
            except sqlite3.IntegrityError:
                conn.execute("ROLLBACK")
                raise Conflict("app already exists") from None
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        finally:
            conn.close()

    def list_apps(self) -> list[dict[str, Any]]:
        conn = self._registry()
        try:
            rows = conn.execute("SELECT * FROM apps WHERE bundle_id IS NOT NULL ORDER BY title").fetchall()
        finally:
            conn.close()
        return [self._summary(r) for r in rows]

    def all_apps(self) -> list[dict[str, Any]]:
        """Every app including ones never published. For the author's tools, not for phones."""
        conn = self._registry()
        try:
            rows = conn.execute("SELECT * FROM apps ORDER BY title").fetchall()
            linked_ids = {r[0] for r in conn.execute("SELECT app_id FROM app_sources")}
        finally:
            conn.close()
        return [
            {
                **self._summary(r),
                "published": r["bundle_id"] is not None,
                "brief": r["brief"],
                "linked": r["app_id"] in linked_ids,
            }
            for r in rows
        ]

    @staticmethod
    def _summary(row: sqlite3.Row) -> dict[str, Any]:
        return {"appId": row["app_id"], "title": row["title"], "icon": row["icon"], "revision": row["revision"]}

    def get_manifest(self, app_id: str) -> dict[str, Any]:
        row = self._row(app_id)
        if row["bundle_id"] is None:
            raise NotFound("app is not published")
        conn = self._registry()
        try:
            b = conn.execute(
                "SELECT * FROM bundles WHERE app_id = ? AND bundle_id = ?", (app_id, row["bundle_id"])
            ).fetchone()
        finally:
            conn.close()
        bundle = json.loads(b["manifest"])
        defs = json.loads(row["definitions"])
        return {
            **self._summary(row),
            "bundle": {
                "bundleId": row["bundle_id"],
                "size": b["size"],
                "format": bundle["format"],
                "sdkMajor": bundle["sdkMajor"],
                "capabilities": bundle["capabilities"],
                "contractHash": bundle["contractHash"],
            },
            "queries": {
                name: {
                    "params": q.get("params", {}),
                    "shape": q["shape"],
                    "maxRows": q["maxRows"],
                    "columns": q["columns"],
                    "completeness": q["completeness"],
                }
                for name, q in defs["queries"].items()
            },
            "mutations": {
                name: {"params": m.get("params", {}), "destructive": m["destructive"]}
                for name, m in defs["mutations"].items()
            },
            **({"files": {name: {"params": f.get("params", {})} for name, f in defs["files"].items()}}
               if defs.get("files") else {}),
        }

    def bundle_path(self, app_id: str, bundle_id: str) -> Path:
        if not BUNDLE_ID.match(bundle_id):
            raise NotFound("unknown bundle")
        conn = self._registry()
        try:
            ok = conn.execute(
                "SELECT 1 FROM bundles WHERE bundle_id = ? AND app_id = ?", (bundle_id, app_id)
            ).fetchone()
        finally:
            conn.close()
        path = self._app_dir(app_id) / "bundles" / (bundle_id.split(":", 1)[1] + ".zip")
        if not ok or not path.is_file():
            raise NotFound("unknown bundle")
        return path

    def etag_for(self, app_id: str | None = None) -> str:
        epoch = self.epoch()
        if app_id is not None:
            return f'W/"{epoch}-{self._row(app_id)["revision"]}"'
        digest = hashlib.sha256(
            json.dumps([(a["appId"], a["revision"]) for a in self.list_apps()]).encode()
        ).hexdigest()[:16]
        return f'W/"{epoch}-{digest}"'

    # -- definitions --------------------------------------------------------

    def validate_definitions(self, app_id: str, definitions: dict[str, Any]) -> dict[str, Any]:
        """Normalise and check definitions against the app database (ADR-003 §7)."""
        db = self.app_db(app_id)
        unknown = set(definitions) - {"queries", "mutations", "files"}
        if unknown:
            raise StoreError(f"unknown definition sections: {sorted(unknown)}")
        out: dict[str, Any] = {"queries": {}, "mutations": {}}
        for name, q in (definitions.get("queries") or {}).items():
            out["queries"][name] = self._check_query(db, name, q)
        for name, m in (definitions.get("mutations") or {}).items():
            out["mutations"][name] = self._check_mutation(db, name, m)
        declared = definitions.get("files") or {}
        if declared:  # only when used, so the contract of an app without files is byte-for-byte what it was
            roots = self.files.root_names(app_id)
            out["files"] = {name: self._check_file(db, name, f, roots) for name, f in declared.items()}
        return out

    @staticmethod
    def contract_hash(defs: dict[str, Any]) -> str:
        """Hash of normalised queries/mutations (and file locators, when there are any) including SQL: changes
        whenever semantics or types change."""
        body: dict[str, Any] = {"queries": defs["queries"], "mutations": defs["mutations"]}
        if defs.get("files"):
            body["files"] = defs["files"]
        return "sha256:" + hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()

    @staticmethod
    def _check_name(name: str) -> None:
        if not re.match(r"^[a-z][a-z0-9_]{1,39}$", name):
            raise StoreError(f"bad operation name: {name!r}")

    @staticmethod
    def _check_params(label: str, sql: str, specs: dict[str, Any]) -> None:
        try:
            P.validate_param_specs(specs)
        except P.ParamError as exc:
            raise StoreError(f"{label}: {exc}") from None
        for name in specs:
            if not re.search(rf":{name}\b", sql):
                raise StoreError(f"{label}: parameter {name!r} is declared but not used in SQL")

    def _check_query(self, db: AppDb, name: str, q: dict[str, Any]) -> dict[str, Any]:
        self._check_name(name)
        sql, specs = q.get("sql"), q.get("params") or {}
        shape = q.get("shape", "rows")
        if not isinstance(sql, str) or shape not in SHAPES:
            raise StoreError(f"query {name}: needs sql and shape in {SHAPES}")
        max_rows = q.get("maxRows", DEFAULT_MAX_ROWS)
        if not isinstance(max_rows, int) or not 1 <= max_rows <= sandbox.MAX_ROWS_HARD:
            raise StoreError(f"query {name}: maxRows must be 1..{sandbox.MAX_ROWS_HARD}")
        self._check_params(f"query {name}", sql, specs)
        bindings = {k: None for k in specs} | P.service_bindings(device_id="probe", tz_name=None)
        try:
            result = db.probe_statement(sql, bindings, mode=sandbox.READ)
        except sandbox.SandboxError as exc:
            raise StoreError(f"query {name}: {exc}") from None
        completeness = "complete" if q.get("completeness") == "complete" or shape != "rows" else "bounded"
        return {
            "sql": sql, "params": specs, "shape": shape, "maxRows": max_rows,
            "columns": result.columns, "completeness": completeness,
        }

    def _check_mutation(self, db: AppDb, name: str, m: dict[str, Any]) -> dict[str, Any]:
        self._check_name(name)
        sql, specs = m.get("sql"), m.get("params") or {}
        if not isinstance(sql, str):
            raise StoreError(f"mutation {name}: needs sql")
        self._check_params(f"mutation {name}", sql, specs)
        bindings = {k: None for k in specs} | P.service_bindings(device_id="probe", tz_name=None)
        try:
            result = db.probe_statement(sql, bindings, mode=sandbox.WRITE)
        except sandbox.SandboxError as exc:
            raise StoreError(f"mutation {name}: {exc}") from None
        if not result.tables:
            raise StoreError(f"mutation {name}: statement does not write to any table")
        return {"sql": sql, "params": specs, "destructive": bool(result.deletes)}

    def _check_file(self, db: AppDb, name: str, f: Any, roots: set[str]) -> dict[str, Any]:
        """A file locator: a reviewed query that returns one file reference, and the linked folder it points into."""
        self._check_name(name)
        if not isinstance(f, dict) or set(f) - {"sql", "params", "root"}:
            raise StoreError(f"file {name}: expected an object with sql, params and root")
        sql, specs, root = f.get("sql"), f.get("params") or {}, f.get("root")
        if not isinstance(sql, str) or not isinstance(root, str):
            raise StoreError(f"file {name}: needs sql and root")
        if root not in roots:
            raise StoreError(
                f"file {name}: this app has no linked folder named {root!r}; the administrator links one with "
                "`ms_admin link-files`"
            )
        self._check_params(f"file {name}", sql, specs)
        bindings = {k: None for k in specs} | P.service_bindings(device_id="probe", tz_name=None)
        try:
            result = db.probe_statement(sql, bindings, mode=sandbox.READ)
        except sandbox.SandboxError as exc:
            raise StoreError(f"file {name}: {exc}") from None
        if len(result.columns) != 1:
            raise StoreError(f"file {name}: the statement must return exactly one column, the file reference")
        return {"sql": sql, "params": specs, "root": root}

    def locate_download(
        self, app_id: str, revision: int, name: str, args: dict[str, Any] | None, *, device_id: str,
        tz_name: str | None,
    ) -> tuple[Path, str, str, int]:
        """The file a published app's locator names for these arguments: (path, name, media type, size)."""
        row = self._row(app_id)
        if row["bundle_id"] is None:
            raise NotFound("app is not published")
        if revision != row["revision"]:
            raise Conflict("stale revision")
        locator = (json.loads(row["definitions"]).get("files") or {}).get(name)
        if locator is None:
            raise StoreError(f"unknown file source: {name!r}")
        try:
            bindings = P.bind_args(locator["params"], args) | P.service_bindings(device_id=device_id, tz_name=tz_name)
            _rev, [res] = self.app_db(app_id).read_group([(locator["sql"], bindings, 1)], caller=sandbox.PHONE)
        except P.ParamError as exc:
            raise StoreError(f"file {name}: {exc}") from None
        except sandbox.SandboxError as exc:
            raise StoreError(str(exc)) from None
        value = res.rows[0][0] if res.rows else None
        if value is None:
            raise NotFound("there is no file for these arguments")
        return self.files.resolve(app_id, locator["root"], value)

    # -- publication --------------------------------------------------------

    def publish(self, app_id: str, bundle: BuiltBundle, definitions: dict[str, Any]) -> int:
        """Store the immutable bundle, then switch manifest/definitions/revision in one transaction."""
        row = self._row(app_id)
        try:
            manifest = verify_bundle(bundle.data, expected_id=bundle.bundle_id)
        except BundleError as exc:
            raise StoreError(f"bundle rejected: {exc}") from None
        defs = self.validate_definitions(app_id, definitions)
        if manifest.get("contractHash") != self.contract_hash(defs):
            raise StoreError("bundle was built for a different query/action contract")
        target = self._app_dir(app_id) / "bundles" / (bundle.bundle_id.split(":", 1)[1] + ".zip")
        target.parent.mkdir(parents=True, exist_ok=True)
        if not target.exists():
            tmp = target.with_suffix(".part")
            tmp.write_bytes(bundle.data)
            tmp.replace(target)  # fully written before the registry transaction references it
        first = row["bundle_id"] is None
        conn = self._registry()
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                rev = conn.execute("SELECT revision FROM apps WHERE app_id = ?", (app_id,)).fetchone()[0] + 1
                conn.execute(
                    "INSERT OR IGNORE INTO bundles(app_id, bundle_id, size, manifest, created_at) VALUES (?,?,?,?,?)",
                    (app_id, bundle.bundle_id, len(bundle.data), json.dumps(manifest), _now()),
                )
                conn.execute(
                    "UPDATE apps SET revision = ?, bundle_id = ?, definitions = ?, updated_at = ? WHERE app_id = ?",
                    (rev, bundle.bundle_id, json.dumps(defs), _now(), app_id),
                )
                events = [("app.changed", None), ("bundle.changed", bundle.bundle_id)]
                if first:
                    events.insert(0, ("registry.changed", None))
                for etype, bid in events:
                    conn.execute(
                        "INSERT INTO events(ts, type, app_id, bundle_id, payload) VALUES (?,?,?,?,?)",
                        (_now(), etype, app_id, bid, json.dumps({"revision": rev})),
                    )
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        finally:
            conn.close()
        return rev

    # -- deletion (to a trash directory, restorable) -------------------------

    def delete_app(self, app_id: str) -> str:
        """Remove an app from the registry and move its directory to `trash/`. Returns the trash name.

        Nothing is erased: the removed rows are saved beside the moved directory, so `trash_restore` can
        bring the app back until `trash_purge` drops it. A linked app's source file is never touched; it
        is not ours, and only our own directory goes to the trash. The registry changes first, so a crash
        before the move leaves an unreferenced directory, never a registry row without its files.
        """
        return self.move_to_trash(app_id, self.unregister_app(app_id))

    def unregister_app(self, app_id: str) -> Path:
        """First half of `delete_app`: the registry rows go and the removed rows are saved in a new trash slot,
        which is returned. The caller then calls `move_to_trash`; the two are separate so a caller that holds
        a lock file inside the app's directory can release it first (a held file blocks the move on Windows)."""
        self._row(app_id)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        slot = self.root / "trash" / f"{app_id}-{stamp}-{secrets.token_hex(2)}"
        slot.mkdir(parents=True)
        try:
            conn = self._registry()
            try:
                conn.execute("BEGIN IMMEDIATE")
                try:
                    saved = {
                        table: [dict(r) for r in conn.execute(f"SELECT * FROM {table} WHERE app_id = ?", (app_id,))]
                        for table in _TRASH_TABLES
                    }
                    if not saved["apps"]:
                        raise NotFound("unknown app")
                    (slot / "rows.json").write_text(json.dumps(saved, ensure_ascii=False), encoding="utf-8")
                    for table in _TRASH_TABLES:
                        conn.execute(f"DELETE FROM {table} WHERE app_id = ?", (app_id,))
                    for etype in ("registry.changed", "app.deleted"):
                        conn.execute(
                            "INSERT INTO events(ts, type, app_id, bundle_id, payload) VALUES (?,?,?,NULL,?)",
                            (_now(), etype, app_id, "{}"),
                        )
                    conn.execute("COMMIT")
                except BaseException:
                    conn.execute("ROLLBACK")
                    raise
            finally:
                conn.close()
        except BaseException:
            shutil.rmtree(slot, ignore_errors=True)
            raise
        return slot

    def move_to_trash(self, app_id: str, slot: Path) -> str:
        """Second half of `delete_app`: the app's directory moves into its trash slot. Returns the slot name."""
        app_dir = self._app_dir(app_id)
        if app_dir.exists():
            try:
                app_dir.replace(slot / "app")
            except OSError:
                pass  # the app is already gone from the registry; the directory is only disk space
        self.trash_purge()
        return slot.name

    def trash_list(self) -> list[dict[str, Any]]:
        out = []
        trash = self.root / "trash"
        for slot in sorted(trash.iterdir()) if trash.is_dir() else []:
            match = _TRASH_NAME.match(slot.name)
            if not match or not (slot / "rows.json").is_file():
                continue
            try:
                row = json.loads((slot / "rows.json").read_text(encoding="utf-8"))["apps"][0]
            except (OSError, ValueError, KeyError, IndexError):
                continue
            deleted = datetime.strptime(match.group(2), "%Y%m%dT%H%M%SZ").strftime("%Y-%m-%dT%H:%M:%SZ")
            out.append({"name": slot.name, "appId": match.group(1), "title": row.get("title"), "deletedAt": deleted})
        return out

    def trash_restore(self, name: str) -> str:
        """Bring a deleted app back with the same id, revision and data. Refused if the id is taken again."""
        match = _TRASH_NAME.match(name or "")
        slot = self.root / "trash" / name if match else None
        if slot is None or not (slot / "rows.json").is_file():
            raise NotFound("unknown trash entry")
        app_id = match.group(1)
        try:
            saved = json.loads((slot / "rows.json").read_text(encoding="utf-8"))
            rows = {table: saved.get(table, []) for table in _TRASH_TABLES}
            if len(rows["apps"]) != 1 or rows["apps"][0]["app_id"] != app_id:
                raise ValueError
        except (OSError, ValueError, KeyError, TypeError):
            raise StoreError("the trash entry is damaged") from None
        target = self._app_dir(app_id)
        if target.exists():
            raise Conflict("an app with this id already exists")
        moved = (slot / "app").is_dir()
        if moved:
            (slot / "app").replace(target)
        try:
            conn = self._registry()
            try:
                conn.execute("BEGIN IMMEDIATE")
                try:
                    for table, columns in _TRASH_TABLES.items():
                        for row in rows[table]:
                            conn.execute(
                                f"INSERT INTO {table}({', '.join(columns)}) VALUES ({', '.join('?' * len(columns))})",
                                [row[c] for c in columns],
                            )
                    for etype in ("registry.changed", "app.changed"):
                        conn.execute(
                            "INSERT INTO events(ts, type, app_id, bundle_id, payload) VALUES (?,?,?,NULL,?)",
                            (_now(), etype, app_id, "{}"),
                        )
                    conn.execute("COMMIT")
                except BaseException:
                    conn.execute("ROLLBACK")
                    raise
            finally:
                conn.close()
        except sqlite3.IntegrityError:
            if moved:
                target.replace(slot / "app")
            raise Conflict("an app with this id already exists") from None
        except BaseException:
            if moved and target.exists():
                target.replace(slot / "app")
            raise
        shutil.rmtree(slot, ignore_errors=True)
        return app_id

    def trash_purge(self, days: float = TRASH_KEEP_DAYS, now: datetime | None = None) -> int:
        """Delete trash entries older than `days`. Returns how many went. Names that are not ours are left."""
        trash = self.root / "trash"
        if not trash.is_dir():
            return 0
        cutoff = (now or datetime.now(timezone.utc)) - timedelta(days=days)
        removed = 0
        for slot in list(trash.iterdir()):
            match = _TRASH_NAME.match(slot.name)
            if not match or not slot.is_dir():
                continue
            deleted = datetime.strptime(match.group(2), "%Y%m%dT%H%M%SZ").replace(tzinfo=timezone.utc)
            if deleted < cutoff:
                shutil.rmtree(slot, ignore_errors=True)
                removed += 1
        return removed

    # -- connection codes (token hand-over and approver pairing) ------------

    @staticmethod
    def _code_digest(code: str) -> str:
        return hashlib.sha256(code.encode("utf-8")).hexdigest()

    def issue_pair_code(self, ttl_s: float = PAIR_CODE_TTL_S) -> str:
        """A fresh one-time code (128 random bits). Only its digest is stored."""
        code = secrets.token_urlsafe(16)
        conn = self._registry()
        try:
            conn.execute("DELETE FROM pair_codes WHERE expires_at < ?", (time.time(),))
            conn.execute(
                "INSERT INTO pair_codes(code_hash, expires_at) VALUES (?,?)",
                (self._code_digest(code), time.time() + ttl_s),
            )
        finally:
            conn.close()
        return code

    def consume_pair_code(self, code: Any) -> None:
        """Spend a code. Every failure reads the same (unknown, used, expired) so the reply teaches nothing;
        after repeated failures all attempts are refused for a minute."""
        now = time.monotonic()
        with self._claim_lock:
            if now < self._claim_locked_until:
                raise TooManyAttempts("too many attempts; wait a minute and ask for a new code")
        row = None
        if isinstance(code, str) and 0 < len(code) <= 200:
            conn = self._registry()
            try:
                conn.execute("BEGIN IMMEDIATE")
                try:
                    digest = self._code_digest(code)
                    row = conn.execute("SELECT expires_at FROM pair_codes WHERE code_hash = ?", (digest,)).fetchone()
                    conn.execute("DELETE FROM pair_codes WHERE code_hash = ?", (digest,))
                    conn.execute("COMMIT")
                except BaseException:
                    conn.execute("ROLLBACK")
                    raise
            finally:
                conn.close()
        with self._claim_lock:
            if row is not None and row["expires_at"] >= time.time():
                self._claim_failures.clear()
                return
            self._claim_failures = [t for t in self._claim_failures if now - t < CLAIM_LOCK_S] + [now]
            if len(self._claim_failures) >= CLAIM_FAILURES_BEFORE_LOCK:
                self._claim_locked_until = now + CLAIM_LOCK_S
                self._claim_failures.clear()
        raise StoreError("the connection code is wrong or has expired")

    # -- device approval ----------------------------------------------------

    def approver_count(self) -> int:
        conn = self._registry()
        try:
            return conn.execute("SELECT COUNT(*) FROM approvers").fetchone()[0]
        finally:
            conn.close()

    def approver_keys(self) -> list[str]:
        conn = self._registry()
        try:
            return [r[0] for r in conn.execute("SELECT public_key FROM approvers ORDER BY created_at")]
        finally:
            conn.close()

    @staticmethod
    def check_approver_fields(device_id: Any, public_key_b64: Any) -> None:
        """Shape of a device id and an Ed25519 public key, without touching the registry."""
        try:
            raw = base64.b64decode(public_key_b64, validate=True)
        except Exception:
            raise StoreError("public key must be base64") from None
        if len(raw) != 32:
            raise StoreError("public key must be a 32-byte Ed25519 key")
        if not isinstance(device_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", device_id):
            raise StoreError("device id must be 1-64 letters, digits, - or _")

    def register_approver(self, device_id: str, public_key_b64: str) -> None:
        """Pair the first device as approver. Later keys are refused: re-pairing is an admin action.

        Trust on first use: whoever pairs first is the approver, so pairing is done by the owner,
        on the phone, before an author is given tools (README, step "Pair the phone").
        """
        self.check_approver_fields(device_id, public_key_b64)
        conn = self._registry()
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                rows = conn.execute("SELECT device_id, public_key FROM approvers").fetchall()
                if rows and not (len(rows) == 1 and rows[0]["device_id"] == device_id and rows[0]["public_key"] == public_key_b64):
                    raise Conflict("a device is already paired as the approver")
                if not rows:
                    conn.execute(
                        "INSERT INTO approvers(device_id, public_key, created_at) VALUES (?,?,?)",
                        (device_id, public_key_b64, _now()),
                    )
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        finally:
            conn.close()

    def clear_approvers(self) -> int:
        """Admin action (CLI): forget the paired device. Returns how many were removed."""
        conn = self._registry()
        try:
            n = conn.execute("DELETE FROM approvers").rowcount
            conn.execute("DELETE FROM approval_nonces")
            return n
        finally:
            conn.close()

    def issue_nonce(self, app_id: str, build_id: str, draft_rev: int, ttl_s: float = 120.0) -> str:
        nonce = uuid.uuid4().hex
        conn = self._registry()
        try:
            conn.execute("DELETE FROM approval_nonces WHERE expires_at < ?", (time.time(),))
            conn.execute(
                "INSERT INTO approval_nonces(nonce, app_id, build_id, draft_rev, expires_at) VALUES (?,?,?,?,?)",
                (nonce, app_id, build_id, draft_rev, time.time() + ttl_s),
            )
        finally:
            conn.close()
        return nonce

    def consume_nonce(self, nonce: str, app_id: str, build_id: str, draft_rev: int) -> None:
        """Single use: the nonce is deleted whether or not the rest of the approval succeeds."""
        conn = self._registry()
        try:
            conn.execute("BEGIN IMMEDIATE")
            row = conn.execute("SELECT * FROM approval_nonces WHERE nonce = ?", (nonce,)).fetchone()
            conn.execute("DELETE FROM approval_nonces WHERE nonce = ?", (nonce,))
            conn.execute("COMMIT")
        finally:
            conn.close()
        if row is None or row["expires_at"] < time.time():
            raise Conflict("the approval request expired; open the preview again")
        if (row["app_id"], row["build_id"], row["draft_rev"]) != (app_id, build_id, draft_rev):
            raise Conflict("the approval was issued for a different build")

    def emit(self, event_type: str, app_id: str | None = None, payload: dict[str, Any] | None = None) -> None:
        """Append one event to the shared journal (clients poll it)."""
        conn = self._registry()
        try:
            conn.execute(
                "INSERT INTO events(ts, type, app_id, bundle_id, payload) VALUES (?,?,?,NULL,?)",
                (_now(), event_type, app_id, json.dumps(payload or {})),
            )
        finally:
            conn.close()

    # -- events -------------------------------------------------------------

    def pump_outboxes(self) -> int:
        """Move per-app outbox rows into the shared journal (ADR-002 §5). Returns events added.

        The stored position is read inside the registry write transaction, so two concurrent
        callers (several devices, or a poll plus a resume poll) cannot both journal the same rows.
        The registry transaction (events + processed position) commits first and the outbox is
        trimmed only afterwards: a crash in between re-reads the rows next time, and the stored
        position stops them being journalled twice.

        A database replaced by an older copy shows up as a different generation, or as an outbox
        sequence / dataRev below what was already journalled. Its pending rows belong to another
        lineage, so they are skipped and the epoch is rotated: every client gets `reset` and does
        a full resync, which is the behaviour ADR-002 §5 asks for after a restore.
        """
        added = 0
        conn = self._registry()  # one connection and one query for the whole sweep, however many apps
        try:
            apps = conn.execute(
                "SELECT a.app_id, s.path AS source FROM apps a LEFT JOIN app_sources s ON s.app_id = a.app_id "
                "WHERE a.bundle_id IS NOT NULL ORDER BY a.title"
            ).fetchall()
            for app in apps:
                try:
                    added += self._pump_app(conn, app["app_id"], app["source"])
                except (sqlite3.Error, OSError):
                    # The app may have been deleted (its directory moved to the trash) after the list above
                    # was read; then there is nothing left to pump. Any other failure is real.
                    if conn.execute("SELECT 1 FROM apps WHERE app_id = ?", (app["app_id"],)).fetchone():
                        raise
        finally:
            conn.close()
        return added

    @staticmethod
    def _rewound(pos: sqlite3.Row | None, snap: Any) -> bool:
        return pos is not None and (
            pos["generation"] != snap.generation or snap.seq < pos["last_id"] or snap.data_rev < pos["data_rev"]
        )

    @staticmethod
    def _position(conn: sqlite3.Connection, app_id: str) -> sqlite3.Row | None:
        return conn.execute(
            "SELECT generation, last_id, data_rev FROM outbox_positions WHERE app_id = ?", (app_id,)
        ).fetchone()

    def _pump_app(self, conn: sqlite3.Connection, app_id: str, source: str | None) -> int:
        """`conn` is the sweep's registry connection and `source` the linked file's path, if any."""
        if source is not None:  # linked: change detection by file signature
            return int(self._linked_rev(app_id)[1])
        db = AppDb(self._app_dir(app_id) / "data.db")
        # Idle fast path: nothing pending and nothing rewound, so no write lock is taken. It
        # writes nothing and so cannot cause a duplicate; a change landing right after the
        # check is picked up by the next poll.
        pos = self._position(conn, app_id)
        snap = db.outbox_snapshot(pos["last_id"] if pos else 0)
        if pos is not None and not snap.rows and not self._rewound(pos, snap) and snap.data_rev == pos["data_rev"]:
            return 0
        added, trim_upto = self._journal(conn, app_id, db)
        if trim_upto is not None:
            db.outbox_trim(trim_upto)
        return added

    def _journal(self, conn: sqlite3.Connection, app_id: str, db: AppDb) -> tuple[int, int | None]:
        """Journal pending rows under the registry write lock; position and snapshot are re-read inside it."""
        conn.execute("BEGIN IMMEDIATE")
        try:
            pos = self._position(conn, app_id)
            snap = db.outbox_snapshot(pos["last_id"] if pos else 0)
            added = 0
            if self._rewound(pos, snap):
                conn.execute("UPDATE meta SET value = ? WHERE key = 'epoch'", (uuid.uuid4().hex[:12],))
                new_last, trim_upto = snap.seq, snap.seq
            else:
                for _id, ts, etype, payload in snap.rows:
                    conn.execute(
                        "INSERT INTO events(ts, type, app_id, bundle_id, payload) VALUES (?,?,?,NULL,?)",
                        (ts, etype, app_id, payload),
                    )
                added = len(snap.rows)
                new_last = snap.rows[-1][0] if snap.rows else (pos["last_id"] if pos else 0)
                trim_upto = snap.rows[-1][0] if snap.rows else None
            conn.execute(
                "INSERT INTO outbox_positions(app_id, generation, last_id, data_rev) VALUES (?,?,?,?) "
                "ON CONFLICT(app_id) DO UPDATE SET generation = excluded.generation, "
                "last_id = excluded.last_id, data_rev = excluded.data_rev",
                (app_id, snap.generation, new_last, snap.data_rev),
            )
            conn.execute("COMMIT")
        except BaseException:
            conn.execute("ROLLBACK")
            raise
        return added, trim_upto

    @staticmethod
    def _sweep_journal(conn: sqlite3.Connection) -> None:
        """Delete journal rows older than JOURNAL_KEEP_S (ADR-002 §5). The newest row always stays, so the
        cursor keeps its meaning; a client whose cursor now predates the oldest row gets `reset` below.
        Best effort: if a writer holds the registry the sweep is simply retried by a later poll."""
        oldest = conn.execute("SELECT ts FROM events ORDER BY seq LIMIT 1").fetchone()
        now = datetime.now(timezone.utc)
        stamp = lambda age: (now - timedelta(seconds=age)).isoformat(timespec="seconds").replace("+00:00", "Z")
        if oldest is None or oldest["ts"] >= stamp(JOURNAL_KEEP_S + JOURNAL_SWEEP_SLACK_S):
            return
        try:
            conn.execute(
                "DELETE FROM events WHERE ts < ? AND seq < (SELECT MAX(seq) FROM events)", (stamp(JOURNAL_KEEP_S),)
            )
        except sqlite3.OperationalError:
            pass

    def events_since(self, since: int, epoch: str | None) -> dict[str, Any]:
        """Journal after `since`. A foreign epoch or a cursor older than the journal means reset."""
        self.pump_outboxes()
        current_epoch = self.epoch()
        conn = self._registry()
        try:
            self._sweep_journal(conn)
            latest = conn.execute("SELECT COALESCE(MAX(seq), 0) FROM events").fetchone()[0]
            oldest = conn.execute("SELECT COALESCE(MIN(seq), 0) FROM events").fetchone()[0]
            if epoch != current_epoch or since > latest or (oldest and since < oldest - 1):
                return {"epoch": current_epoch, "seq": latest, "reset": True, "events": []}
            rows = conn.execute(
                "SELECT seq, ts, type, app_id, bundle_id, payload FROM events WHERE seq > ? ORDER BY seq LIMIT 500",
                (since,),
            ).fetchall()
        finally:
            conn.close()
        events = [
            {"seq": r["seq"], "ts": r["ts"], "type": r["type"], "appId": r["app_id"],
             "bundleId": r["bundle_id"], "payload": json.loads(r["payload"] or "{}")}
            for r in rows
        ]
        return {"epoch": current_epoch, "seq": events[-1]["seq"] if events else latest, "reset": False, "events": events}

    # -- data ---------------------------------------------------------------

    def run_queries(
        self,
        app_id: str,
        revision: int,
        calls: list[dict[str, Any]],
        *,
        device_id: str,
        tz_name: str | None,
    ) -> dict[str, Any]:
        row = self._row(app_id)
        if row["bundle_id"] is None:
            raise NotFound("app is not published")
        if revision != row["revision"]:
            raise Conflict("stale revision")
        return self.run_queries_with(
            app_id, json.loads(row["definitions"])["queries"], revision, calls, device_id=device_id, tz_name=tz_name
        )

    def run_queries_with(
        self,
        app_id: str,
        defs: dict[str, Any],
        revision: int,
        calls: list[dict[str, Any]],
        *,
        device_id: str,
        tz_name: str | None,
    ) -> dict[str, Any]:
        """Run named queries from explicit (already normalised) definitions: the published ones, or
        those of a draft awaiting review. The caller has checked the revision."""
        if not 1 <= len(calls) <= 16:
            raise StoreError("1-16 queries per request")
        service = P.service_bindings(device_id=device_id, tz_name=tz_name)
        specs, order = [], []
        for call in calls:
            name = call.get("name")
            q = defs.get(name)
            if q is None:
                raise StoreError(f"unknown query: {name!r}")
            try:
                bindings = P.bind_args(q["params"], call.get("args")) | service
            except P.ParamError as exc:
                raise StoreError(f"query {name}: {exc}") from None
            specs.append((q["sql"], bindings, q["maxRows"]))
            order.append((name, q))
        try:
            data_rev, results = self.app_db(app_id).read_group(specs, caller=sandbox.PHONE)
        except sandbox.SandboxError as exc:
            raise StoreError(str(exc)) from None
        out: dict[str, Any] = {}
        for (name, q), res in zip(order, results):
            cols = res.columns
            rows = [dict(zip(cols, r)) for r in res.rows]
            if q["shape"] == "rows":
                data: Any = rows
            elif q["shape"] == "row":
                data = rows[0] if rows else None
            else:
                data = res.rows[0][0] if res.rows else None
            completeness = "bounded" if res.truncated else q["completeness"]
            out[name] = {"data": data, "completeness": completeness}
        return {"revision": revision, "dataRev": data_rev, "epoch": self.epoch(), "results": out}

    def agent_sql(
        self, app_id: str, mode: str, sql: str, params: Any = None, params_list: list[Any] | None = None
    ) -> dict[str, Any]:
        """Body of the `mobile_data_sql` tool: arbitrary SQL inside the app's own database."""
        db = self.app_db(app_id)
        try:
            if mode == sandbox.READ:
                rev, [res] = db.read_group([(sql, params or {}, sandbox.MAX_ROWS_HARD)], caller=sandbox.AGENT)
                # The author needs the shape of the data, not whole documents: long text cells are cut
                # (what the model reads is sent to its provider). Schema listings are exempt.
                keep_whole = "sqlite_master" in sql.lower() or "sqlite_schema" in sql.lower()
                rows, clipped = (res.rows, 0) if keep_whole else _clip_rows(res.rows)
                out: dict[str, Any] = {
                    "dataRev": rev, "columns": res.columns, "rows": rows, "truncated": res.truncated,
                }
                if clipped:
                    out["clippedCells"] = clipped
                return out
            if mode not in (sandbox.WRITE, sandbox.SCHEMA):
                raise StoreError("mode must be read, write or schema")
            many = params_list is not None
            rev, res = db.write(
                sql, params_list if many else (params or {}), mode=mode, caller=sandbox.AGENT, many=many
            )
            return {"dataRev": rev, "rowcount": res.rowcount, "tables": res.tables}
        except sandbox.SandboxError as exc:
            raise StoreError(str(exc)) from None
