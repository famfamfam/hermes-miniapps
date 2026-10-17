"""Files of an app (ADR-002 §6 attachments, ADR-004 §6).

Two kinds, both reached only through the phone API or the author's tools, never by a path the page names:

* stored files: uploaded from the phone or imported by the author from a folder of the host. The bytes live in
  `apps/<id>/files/<file_id>` under a random id; the name is kept only for display and saving. A file is
  never executed or interpreted here, and every download is an attachment of a type taken from the
  extension, not from what the sender claimed.
* linked folders: a read-only folder of the host that the administrator linked to an app (`link_root`). A
  named locator of the app's reviewed definitions returns a path from the app's own database; it is served
  only if it stays inside that folder. This is how receipts that another skill keeps on disk reach the phone.
"""
from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import secrets
import sqlite3
import unicodedata
from datetime import datetime, timezone
from pathlib import Path, PurePosixPath
from typing import Any

from .errors import Conflict, InsufficientStorage, NotFound, StoreError, TooLarge

MAX_FILE_BYTES = 20 * 1024 * 1024        # the edge proxy admits 25 MB bodies
MAX_APP_BYTES = 256 * 1024 * 1024
MAX_APP_FILES = 200
MAX_TOTAL_BYTES = 2 * 1024 * 1024 * 1024
MAX_LINKED_BYTES = 30 * 1024 * 1024
AGENT_TEXT_BYTES = 64 * 1024
CHUNK = 64 * 1024

FILE_ID = re.compile(r"^f_[0-9a-f]{16}$")
ROOT_NAME = re.compile(r"^[a-z][a-z0-9_]{1,39}$")
SOURCES = ("phone", "import")

# Extension -> media type. Anything else is refused: what the phone is offered to open or share is a document,
# a picture, a table or an archive, not a program.
MIME = {
    "pdf": "application/pdf",
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "webp": "image/webp", "gif": "image/gif",
    "heic": "image/heic", "heif": "image/heif",
    "txt": "text/plain", "csv": "text/csv", "md": "text/markdown", "json": "application/json",
    "rtf": "application/rtf",
    "doc": "application/msword",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xls": "application/vnd.ms-excel",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
    "odt": "application/vnd.oasis.opendocument.text",
    "ods": "application/vnd.oasis.opendocument.spreadsheet",
    "zip": "application/zip",
    "mp3": "audio/mpeg", "wav": "audio/wav", "m4a": "audio/mp4", "ogg": "audio/ogg",
}
TEXT_MIMES = {"text/plain", "text/csv", "text/markdown", "application/json"}
IMAGE_MIMES = {"image/png", "image/jpeg", "image/webp", "image/gif"}


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def clean_name(raw: Any) -> str:
    """A display name from whatever the sender gave: no directories, no control characters, at most 120 characters."""
    if not isinstance(raw, str):
        raise StoreError("the file name is missing")
    name = unicodedata.normalize("NFC", raw.replace("\\", "/").rsplit("/", 1)[-1])
    name = "".join(ch for ch in name if ch.isprintable() and ch not in '<>:"|?*').strip(" .")
    if not name:
        raise StoreError("the file name is missing")
    if len(name) > 120:
        stem, dot, ext = name.rpartition(".")
        name = (stem[: 115 - len(ext)] + dot + ext) if dot and len(ext) <= 8 else name[:120]
    return name


def mime_for(name: str) -> str:
    ext = name.rpartition(".")[2].lower() if "." in name else ""
    mime = MIME.get(ext)
    if mime is None:
        raise StoreError(f"files of this type are not accepted ({'.' + ext if ext else 'no extension'})")
    return mime


# The first bytes of a file say what it is, whatever its name says. A receipts skill that saves photos of paper
# receipts as `x.pdf` is the case this exists for: offered as a PDF, a JPEG cannot be opened on the phone.
_MAGIC = (
    (b"%PDF-", "application/pdf", "pdf"),
    (b"\xff\xd8\xff", "image/jpeg", "jpg"),
    (b"\x89PNG\r\n\x1a\n", "image/png", "png"),
    (b"GIF87a", "image/gif", "gif"),
    (b"GIF89a", "image/gif", "gif"),
)


def sniff_type(head: bytes) -> tuple[str, str] | None:
    """(media type, extension) of a file from its first bytes, or None when they are not one of the few we know."""
    for magic, mime, ext in _MAGIC:
        if head.startswith(magic):
            return mime, ext
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp", "webp"
    return None


def corrected(name: str, mime: str, head: bytes) -> tuple[str, str]:
    """The name and media type to offer: those of the content when it is clearly something else than the extension
    says (the extension is then replaced), otherwise the ones the extension gave."""
    found = sniff_type(head)
    if found is None or found[0] == mime:
        return name, mime
    stem, dot, _ext = name.rpartition(".")
    return f"{stem if dot else name}.{found[1]}", found[0]


# File modes mean nothing on Windows, where the check is off.
CHECK_MODES = os.name != "nt"


def _mode(path: str) -> int:
    return os.stat(path).st_mode


def not_readable_by_service(root: Path, *, check_modes: bool | None = None, limit: int = 5000) -> dict[str, Any]:
    """Entries of a linked folder that the service cannot read. The service runs as its own user without any rights
    of its own, so what counts is the "others" bits: a file needs r, a folder needs r and x. Only files of the
    accepted types are looked at (the rest is never served). `check_modes` is False where modes mean nothing
    (Windows); `limit` bounds the walk. Returns counts and up to five examples of each, relative to `root`."""
    if check_modes is None:
        check_modes = CHECK_MODES
    out: dict[str, Any] = {"files": 0, "folders": 0, "examples": [], "truncated": False, "checked": check_modes}
    if not check_modes:
        return out
    seen = 0
    for dirpath, dirs, names in os.walk(root):
        base = Path(dirpath)
        try:
            folder_ok = (_mode(dirpath) & 0o005) == 0o005
        except OSError:
            continue
        if not folder_ok and base != root:
            out["folders"] += 1
            if len(out["examples"]) < 5:
                out["examples"].append(base.relative_to(root).as_posix() + "/")
        for name in names:
            seen += 1
            if seen > limit:
                out["truncated"] = True
                return out
            if name.rpartition(".")[2].lower() not in MIME:
                continue
            try:
                readable = (_mode(os.path.join(dirpath, name)) & 0o004) != 0
            except OSError:
                continue
            if not readable:
                out["files"] += 1
                if len(out["examples"]) < 5:
                    out["examples"].append((base / name).relative_to(root).as_posix())
    return out


def _storage_error(exc: OSError) -> StoreError:
    if exc.errno in (errno.ENOSPC, getattr(errno, "EDQUOT", -1)):
        return InsufficientStorage("the server is out of disk space")
    return StoreError(f"the file could not be stored: {exc.strerror or type(exc).__name__}")


class Incoming:
    """A file being received: bytes go to a temporary name beside the final place and are hashed on the way."""

    def __init__(self, path: Path, limit: int) -> None:
        self.path = path
        self.size = 0
        self._limit = limit
        self._sha = hashlib.sha256()
        self._fh = open(path, "wb")

    def write(self, chunk: bytes) -> None:
        self.size += len(chunk)
        if self.size > self._limit:
            raise TooLarge(f"the file is larger than {self._limit // (1024 * 1024)} MB")
        self._sha.update(chunk)
        try:
            self._fh.write(chunk)
        except OSError as exc:
            raise _storage_error(exc) from None

    def digest(self) -> str:
        return self._sha.hexdigest()

    def close(self) -> None:
        try:
            self._fh.close()
        except OSError as exc:
            raise _storage_error(exc) from None

    def discard(self) -> None:
        try:
            self._fh.close()
        except OSError:
            pass
        self.path.unlink(missing_ok=True)


class AppFiles:
    def __init__(self, store: Any) -> None:
        self.store = store

    # -- stored files ---------------------------------------------------------------------------

    def _dir(self, app_id: str) -> Path:
        return self.store._app_dir(app_id) / "files"

    @staticmethod
    def _record(row: sqlite3.Row) -> dict[str, Any]:
        return {
            "fileId": row["file_id"], "name": row["name"], "mime": row["mime"], "size": row["size"],
            "sha256": row["sha256"], "source": row["source"], "createdAt": row["created_at"],
        }

    def _usage(self, conn: sqlite3.Connection, app_id: str) -> tuple[int, int, int]:
        count, size = conn.execute(
            "SELECT COUNT(*), COALESCE(SUM(size), 0) FROM app_files WHERE app_id = ?", (app_id,)
        ).fetchone()
        total = conn.execute("SELECT COALESCE(SUM(size), 0) FROM app_files").fetchone()[0]
        return count, size, total

    def _check_room(self, conn: sqlite3.Connection, app_id: str, extra: int) -> None:
        count, size, total = self._usage(conn, app_id)
        if count >= MAX_APP_FILES:
            raise StoreError(f"this app already holds {MAX_APP_FILES} files; delete some first")
        if size + extra > MAX_APP_BYTES:
            raise TooLarge(f"this app's files would exceed {MAX_APP_BYTES // (1024 * 1024)} MB; delete some first")
        if total + extra > MAX_TOTAL_BYTES:
            raise InsufficientStorage("the server's file storage is full")

    def begin(self, app_id: str, raw_name: Any, declared_size: int | None = None) -> tuple[Incoming, str, str]:
        """Check what can be checked before any byte is read: the app, the name and type, the size. The room left
        is checked in `finish`, once the content is known: the same file sent again (a retry after a lost answer)
        must be answered even when the app is full. Returns the receiving file, the cleaned name and the type."""
        self.store._row(app_id)
        name = clean_name(raw_name)
        mime = mime_for(name)
        if declared_size is not None:
            if declared_size <= 0:
                raise StoreError("the file is empty")
            if declared_size > MAX_FILE_BYTES:
                raise TooLarge(f"the file is larger than {MAX_FILE_BYTES // (1024 * 1024)} MB")
        directory = self._dir(app_id)
        try:
            directory.mkdir(parents=True, exist_ok=True)
            incoming = Incoming(directory / f".incoming-{secrets.token_hex(8)}", MAX_FILE_BYTES)
        except OSError as exc:
            raise _storage_error(exc) from None
        return incoming, name, mime

    def finish(self, app_id: str, incoming: Incoming, name: str, mime: str, source: str = "phone") -> dict[str, Any]:
        """Make a received file permanent. The same content uploaded again to the same app is the same file."""
        if source not in SOURCES:
            raise StoreError("unknown file source")
        try:
            incoming.close()
            if incoming.size == 0:
                raise StoreError("the file is empty")
            digest = incoming.digest()
            file_id = "f_" + secrets.token_hex(8)
            target = self._dir(app_id) / file_id
            conn = self.store._registry()
            try:
                conn.execute("BEGIN IMMEDIATE")
                try:
                    again = conn.execute(
                        "SELECT * FROM app_files WHERE app_id = ? AND sha256 = ?", (app_id, digest)
                    ).fetchone()
                    if again is not None and (self._dir(app_id) / again["file_id"]).is_file():
                        conn.execute("ROLLBACK")
                        incoming.discard()
                        return {**self._record(again), "duplicate": True}
                    self._check_room(conn, app_id, incoming.size)
                    conn.execute(
                        "INSERT INTO app_files(file_id, app_id, name, mime, size, sha256, source, created_at) "
                        "VALUES (?,?,?,?,?,?,?,?)",
                        (file_id, app_id, name, mime, incoming.size, digest, source, _now()),
                    )
                    conn.execute(
                        "INSERT INTO events(ts, type, app_id, bundle_id, payload) VALUES (?,?,?,NULL,?)",
                        (_now(), "files.changed", app_id, json.dumps({"fileId": file_id, "change": "added"})),
                    )
                    incoming.path.replace(target)
                    conn.execute("COMMIT")
                except BaseException:
                    conn.execute("ROLLBACK")
                    target.unlink(missing_ok=True)
                    raise
            finally:
                conn.close()
        except OSError as exc:
            incoming.discard()
            raise _storage_error(exc) from None
        except BaseException:
            incoming.discard()
            raise
        return {
            "fileId": file_id, "name": name, "mime": mime, "size": incoming.size, "sha256": digest,
            "source": source, "createdAt": _now(), "duplicate": False,
        }

    def list_files(self, app_id: str) -> list[dict[str, Any]]:
        self.store._row(app_id)
        conn = self.store._registry()
        try:
            rows = conn.execute(
                "SELECT * FROM app_files WHERE app_id = ? ORDER BY created_at DESC, file_id", (app_id,)
            ).fetchall()
        finally:
            conn.close()
        return [self._record(r) for r in rows]

    def get(self, app_id: str, file_id: str) -> tuple[Path, dict[str, Any]]:
        """The file and its record; a file of another app, or one that is gone, is NotFound."""
        if not FILE_ID.match(file_id or ""):
            raise NotFound("unknown file")
        self.store._row(app_id)
        conn = self.store._registry()
        try:
            row = conn.execute(
                "SELECT * FROM app_files WHERE app_id = ? AND file_id = ?", (app_id, file_id)
            ).fetchone()
        finally:
            conn.close()
        path = self._dir(app_id) / file_id
        if row is None or not path.is_file():
            raise NotFound("unknown file")
        return path, self._record(row)

    def delete(self, app_id: str, file_id: str) -> None:
        path, _record = self.get(app_id, file_id)
        conn = self.store._registry()
        try:
            conn.execute("BEGIN IMMEDIATE")
            try:
                conn.execute("DELETE FROM app_files WHERE app_id = ? AND file_id = ?", (app_id, file_id))
                conn.execute(
                    "INSERT INTO events(ts, type, app_id, bundle_id, payload) VALUES (?,?,?,NULL,?)",
                    (_now(), "files.changed", app_id, json.dumps({"fileId": file_id, "change": "deleted"})),
                )
                conn.execute("COMMIT")
            except BaseException:
                conn.execute("ROLLBACK")
                raise
        finally:
            conn.close()
        path.unlink(missing_ok=True)

    def read_for_agent(self, app_id: str, file_id: str) -> dict[str, Any]:
        """What the author's tool shows of a file: its record, plus the text when it is a short text file."""
        path, record = self.get(app_id, file_id)
        out: dict[str, Any] = dict(record)
        if record["mime"] in TEXT_MIMES and record["size"] <= AGENT_TEXT_BYTES:
            out["text"] = path.read_bytes().decode("utf-8", errors="replace")
        return out

    def image_bytes(self, app_id: str, file_id: str, limit: int = 5 * 1024 * 1024) -> tuple[bytes, str] | None:
        """The bytes and media type of an image small enough to show a model, else None."""
        path, record = self.get(app_id, file_id)
        if record["mime"] not in IMAGE_MIMES or record["size"] > limit:
            return None
        return path.read_bytes(), record["mime"]

    def import_from_root(self, app_id: str, root_name: str, value: str) -> dict[str, Any]:
        """Copy a file of a linked folder into the app's own files (a generated picture, a downloaded document)."""
        path, name, mime, _size = self.resolve(app_id, root_name, value)
        incoming, clean, _mime = self.begin(app_id, name, path.stat().st_size)
        try:
            with open(path, "rb") as src:
                for chunk in iter(lambda: src.read(CHUNK), b""):
                    incoming.write(chunk)
        except OSError as exc:
            incoming.discard()
            raise _storage_error(exc) from None
        except BaseException:
            incoming.discard()
            raise
        return self.finish(app_id, incoming, clean, mime, source="import")

    # -- linked folders -------------------------------------------------------------------------

    def link_root(self, app_id: str, name: str, path: str | Path, strip_prefix: str | None = None) -> Path:
        """Let the app's file locators point into this folder (read only). `strip_prefix` is the part of the
        paths stored in the app's data that the folder replaces, e.g. `/root/.hermes/zhkh`."""
        self.store._row(app_id)
        if not ROOT_NAME.match(name or ""):
            raise StoreError("a root name is 2-40 lowercase letters, digits and underscores, starting with a letter")
        folder = Path(path)
        if not folder.is_absolute():
            raise StoreError("the folder path must be absolute")
        try:
            real = folder.resolve(strict=True)
        except OSError:
            raise StoreError("the folder does not exist") from None
        if not real.is_dir():
            raise StoreError("the path is not a folder")
        service = self.store.root
        if real == service or service in real.parents or real in service.parents:
            raise StoreError("the folder must not contain or lie inside the service's own storage")
        if strip_prefix is not None:
            prefix = PurePosixPath(strip_prefix)
            if not prefix.is_absolute() or any(p in ("..", ".") for p in prefix.parts):
                raise StoreError("the prefix must be an absolute path without . or .. parts")
            strip_prefix = str(prefix)
        conn = self.store._registry()
        try:
            try:
                conn.execute(
                    "INSERT INTO app_file_roots(app_id, name, path, strip_prefix, created_at) VALUES (?,?,?,?,?)",
                    (app_id, name, str(real), strip_prefix, _now()),
                )
            except sqlite3.IntegrityError:
                raise Conflict(f"this app already has a folder named {name!r}") from None
        finally:
            conn.close()
        return real

    def unlink_root(self, app_id: str, name: str) -> None:
        conn = self.store._registry()
        try:
            if conn.execute("DELETE FROM app_file_roots WHERE app_id = ? AND name = ?", (app_id, name)).rowcount == 0:
                raise NotFound("no such folder")
        finally:
            conn.close()

    def roots(self, app_id: str) -> list[dict[str, Any]]:
        conn = self.store._registry()
        try:
            rows = conn.execute(
                "SELECT name, path, strip_prefix FROM app_file_roots WHERE app_id = ? ORDER BY name", (app_id,)
            ).fetchall()
        finally:
            conn.close()
        return [{"name": r["name"], "path": r["path"], "stripPrefix": r["strip_prefix"]} for r in rows]

    def readability_warnings(self, app_id: str) -> list[dict[str, Any]]:
        """One entry per linked folder that holds files the service may not read (see `not_readable_by_service`).
        A folder that cannot be reached from this process (another mount namespace) is skipped, not reported."""
        out = []
        for r in self.roots(app_id):
            try:
                found = not_readable_by_service(Path(r["path"]))
            except OSError:
                continue
            if found["files"] or found["folders"]:
                out.append({"root": r["name"], **found})
        return out

    def root_names(self, app_id: str) -> set[str]:
        return {r["name"] for r in self.roots(app_id)}

    @staticmethod
    def _parts(root: Path, strip_prefix: str | None, value: Any) -> list[str]:
        if not isinstance(value, str) or not value.strip() or len(value) > 1024 or "\x00" in value:
            raise StoreError("the data holds no usable file reference for this request")
        text = value.strip().replace("\\", "/")
        posix = PurePosixPath(text)
        parts = list(posix.parts)
        if posix.is_absolute() or re.match(r"^[A-Za-z]:/", text):  # a drive letter: a Windows host, the same rule
            prefixes = ([PurePosixPath(strip_prefix)] if strip_prefix else []) + [PurePosixPath(root.as_posix())]
            for prefix in prefixes:
                try:
                    parts = list(posix.relative_to(prefix).parts)
                    break
                except ValueError:
                    continue
            else:
                raise StoreError("the file is outside the folder linked for this app")
        if any(p in ("..", ".") for p in parts):
            raise StoreError("the file is outside the folder linked for this app")
        if not parts:
            raise StoreError("the data holds no usable file reference for this request")
        return parts

    def resolve(self, app_id: str, root_name: str, value: Any) -> tuple[Path, str, str, int]:
        """The file a reference names inside the app's linked folder: (path, display name, media type, size).
        It must exist, stay inside the folder after symbolic links are followed, be an ordinary file of an
        accepted type and not be too large."""
        conn = self.store._registry()
        try:
            row = conn.execute(
                "SELECT path, strip_prefix FROM app_file_roots WHERE app_id = ? AND name = ?", (app_id, root_name)
            ).fetchone()
        finally:
            conn.close()
        if row is None:
            raise StoreError(f"this app has no linked folder named {root_name!r}")
        try:
            root = Path(row["path"]).resolve(strict=True)
        except OSError:
            raise StoreError("the linked folder is not available right now") from None
        parts = self._parts(root, row["strip_prefix"], value)
        try:
            real = root.joinpath(*parts).resolve(strict=True)
        except OSError:
            raise NotFound("the file does not exist") from None
        if real != root and root not in real.parents:
            raise StoreError("the file is outside the folder linked for this app")
        try:
            info = real.stat()
        except OSError:
            raise NotFound("the file does not exist") from None
        if not real.is_file():
            raise StoreError("the reference is not a file")
        # Found, but the service may be forbidden to read it (a file the skill saved with a stricter mode than its
        # siblings). Say so now: once the answer has started, a failed open can only cut the connection.
        try:
            with open(real, "rb") as handle:
                head = handle.read(16)
        except OSError:
            raise StoreError(
                "the server is not allowed to read this file (it runs without root rights): the administrator can "
                "fix that with `chmod a+r` on the file"
            ) from None
        if info.st_size > MAX_LINKED_BYTES:
            raise TooLarge(f"the file is larger than {MAX_LINKED_BYTES // (1024 * 1024)} MB")
        name, mime = corrected(real.name, mime_for(real.name), head)  # the extension must be an accepted one first
        return real, name, mime, info.st_size
