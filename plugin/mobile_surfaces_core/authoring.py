"""Drafts of an app's interface: editable sources, build, review, publish (ADR-007 §3-5).

One draft per app, kept on disk next to the app's data:

    apps/<id>/draft/draft.json        draftRev, baseRevision
    apps/<id>/draft/files/...         definitions.json and src/*  (what the author edits)
    apps/<id>/draft/dist/             output of the last successful build
    apps/<id>/draft/build.json        which draftRev that build belongs to
    apps/<id>/draft/review.json       a build submitted for the user's approval (+ review-*.json/.zip)
    apps/<id>/source/...              sources of the published revision (start point of the next draft)
    apps/<id>/pending-publication.json   one prepared publication, reconciled under the authoring lock
    apps/<id>/source.pending/            frozen sources prepared before the registry commit
    apps/<id>/source.previous/           old sources until finalization completes

Editing never touches what phones run. Submission/direct publication needs a successful build of
exactly the current draft, an unchanged base revision and definitions that validate right now.
Approval publishes the saved submitted bundle and contract, not a later unsent rebuild.

Review: once a device is paired as approver (`Store.register_approver`), `publish` no longer replaces
what the user runs. It *submits* the build; the phone shows it in preview and the user's device signs
an approval (`approval.py`), and only that publishes. Any edit after submission withdraws it.
"""
from __future__ import annotations

import json
import logging
import os
import shutil
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from . import approval
from . import bundle as B
from .builder import (
    DEFINITIONS_FILE, PROTECTED_FILES, SOURCE_FILE, BuildResult, Builder, Diagnostic, check_file_set,
    check_writable_path,
)
from .store import Conflict, ApprovalRefused, NotFound, Store, StoreError

_EMPTY_DEFINITIONS = '{\n  "queries": {},\n  "mutations": {}\n}\n'


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def _exists(path: Path) -> bool:
    """Only ENOENT means absent; transient I/O errors must not masquerade as completed cleanup."""
    try:
        path.stat()
    except FileNotFoundError:
        return False
    return True


def _atomic_write(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # All callers hold the authoring lock; a fixed temporary name also bounds crash leftovers.
    tmp = path.with_name(path.name + ".part")
    try:
        tmp.write_text(text, encoding="utf-8", newline="\n")
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink(missing_ok=True)
        except OSError:
            pass


@contextmanager
def _file_lock(path: Path) -> Iterator[None]:
    """Cross-process exclusive lock: the MCP process (author) and the phone API process (approval)
    both touch a draft."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR)
    try:
        if os.name == "nt":
            import msvcrt

            msvcrt.locking(fd, msvcrt.LK_LOCK, 1)
        else:
            import fcntl

            fcntl.flock(fd, fcntl.LOCK_EX)
        yield
    finally:
        try:
            if os.name == "nt":
                import msvcrt

                os.lseek(fd, 0, os.SEEK_SET)
                msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
            else:
                import fcntl

                fcntl.flock(fd, fcntl.LOCK_UN)
        finally:
            os.close(fd)


class Authoring:
    def __init__(self, store: Store, template_dir: Path, builder: Builder | None = None) -> None:
        self.store = store
        self.template_dir = template_dir.resolve()
        self.builder = builder
        self._locks: dict[str, threading.Lock] = {}
        self._locks_guard = threading.Lock()

    # -- paths and state --------------------------------------------------------

    @contextmanager
    def _lock(self, app_id: str) -> Iterator[None]:
        with self._locks_guard:
            thread_lock = self._locks.setdefault(app_id, threading.Lock())
        with thread_lock, _file_lock(self.store.app_dir(app_id) / ".authoring.lock"):
            self._recover_publication(app_id)
            yield

    def _draft(self, app_id: str) -> Path:
        return self.store.app_dir(app_id) / "draft"

    def _state(self, app_id: str) -> dict[str, Any]:
        return json.loads((self._draft(app_id) / "draft.json").read_text(encoding="utf-8"))

    def _save_state(self, app_id: str, state: dict[str, Any]) -> None:
        _atomic_write(self._draft(app_id) / "draft.json", json.dumps(state, indent=2))

    def _files(self, app_id: str) -> dict[str, str]:
        root = self._draft(app_id) / "files"
        return {
            p.relative_to(root).as_posix(): p.read_text(encoding="utf-8")
            for p in sorted(root.rglob("*")) if p.is_file()
        }

    def _ensure(self, app_id: str) -> dict[str, Any]:
        """Create the draft from the published sources, or from the starter template, if missing."""
        draft = self._draft(app_id)
        if (draft / "draft.json").is_file():
            return self._state(app_id)
        base = self.store._row(app_id)["revision"]
        published = self.store.app_dir(app_id) / "source"
        files = draft / "files"
        if files.exists():
            shutil.rmtree(files)
        if published.is_dir():
            shutil.copytree(published, files)
        else:
            (files / "src").mkdir(parents=True)
            for path in sorted((self.template_dir / "src").glob("*")):
                if path.is_file() and f"src/{path.name}" not in PROTECTED_FILES and SOURCE_FILE.match(f"src/{path.name}"):
                    shutil.copyfile(path, files / "src" / path.name)
            template_defs = self.template_dir / DEFINITIONS_FILE
            _atomic_write(
                files / DEFINITIONS_FILE,
                template_defs.read_text(encoding="utf-8") if template_defs.is_file() else _EMPTY_DEFINITIONS,
            )
        state = {"draftRev": 1, "baseRevision": base, "startedAt": _now()}
        self._save_state(app_id, state)
        return state

    def _view(self, app_id: str, state: dict[str, Any]) -> dict[str, Any]:
        build = self._build_record(app_id)
        files = self._files(app_id)
        review = self._review(app_id, state)
        return {
            "appId": app_id,
            "draftRev": state["draftRev"],
            "baseRevision": state["baseRevision"],
            "files": [{"path": p, "bytes": len(t.encode("utf-8"))} for p, t in files.items()],
            "build": (
                {"ok": build["ok"], "current": build["draftRev"] == state["draftRev"], "draftRev": build["draftRev"]}
                if build else None
            ),
            "review": (
                {"status": "awaiting_review", "buildId": review["buildId"], "submittedAt": review["submittedAt"]}
                if review else None
            ),
        }

    def _build_record(self, app_id: str) -> dict[str, Any] | None:
        path = self._draft(app_id) / "build.json"
        return json.loads(path.read_text(encoding="utf-8")) if path.is_file() else None

    # -- reading and editing ----------------------------------------------------

    def status(self, app_id: str) -> dict[str, Any]:
        with self._lock(app_id):
            return self._view(app_id, self._ensure(app_id))

    def read(self, app_id: str, path: str) -> dict[str, Any]:
        with self._lock(app_id):
            state = self._ensure(app_id)
            files = self._files(app_id)
            if path not in files and path not in PROTECTED_FILES:
                raise NotFound(f"no such file in the draft: {path}")
            text = files[path] if path in files else (self.template_dir / path).read_text(encoding="utf-8")
            return {"path": path, "draftRev": state["draftRev"], "content": text}

    def write(self, app_id: str, path: str, content: str, expected_draft_rev: int | None = None) -> dict[str, Any]:
        try:
            check_writable_path(path)
        except ValueError as exc:
            raise StoreError(str(exc)) from None
        if not isinstance(content, str) or "\x00" in content:
            raise StoreError("content must be text")
        if path == DEFINITIONS_FILE:
            try:
                parsed = json.loads(content)
            except json.JSONDecodeError as exc:
                raise StoreError(f"definitions.json is not valid JSON: {exc}") from None
            if not isinstance(parsed, dict):
                raise StoreError("definitions.json must be an object with queries and mutations")
        with self._lock(app_id):
            state = self._ensure(app_id)
            if expected_draft_rev is not None and expected_draft_rev != state["draftRev"]:
                raise Conflict(f"draft changed: expected draftRev {expected_draft_rev}, now {state['draftRev']}")
            files = self._files(app_id)
            files[path] = content
            try:
                check_file_set(files)
            except ValueError as exc:
                raise StoreError(str(exc)) from None
            _atomic_write(self._draft(app_id) / "files" / path, content)
            state["draftRev"] += 1
            self._save_state(app_id, state)
            self._withdraw_review(app_id)
            return self._view(app_id, state)

    def delete(self, app_id: str, path: str) -> dict[str, Any]:
        try:
            check_writable_path(path)
        except ValueError as exc:
            raise StoreError(str(exc)) from None
        if path in (DEFINITIONS_FILE, "src/App.tsx"):
            raise StoreError(f"{path} is required")
        with self._lock(app_id):
            state = self._ensure(app_id)
            target = self._draft(app_id) / "files" / path
            if not target.is_file():
                raise NotFound(f"no such file in the draft: {path}")
            target.unlink()
            state["draftRev"] += 1
            self._save_state(app_id, state)
            self._withdraw_review(app_id)
            return self._view(app_id, state)

    def reset(self, app_id: str) -> dict[str, Any]:
        """Throw the draft away; the next edit starts again from the published sources."""
        with self._lock(app_id):
            self.store._row(app_id)
            draft = self._draft(app_id)
            had_review = (draft / "review.json").is_file()
            if draft.exists():
                shutil.rmtree(draft)
            if had_review:
                self.store.emit("review.changed", app_id, {"status": "withdrawn"})
            return self._view(app_id, self._ensure(app_id))

    # -- build ------------------------------------------------------------------

    def build(self, app_id: str) -> dict[str, Any]:
        if self.builder is None:
            raise StoreError("interface builds are not configured on this server")
        with self._lock(app_id):
            state = self._ensure(app_id)
            files = self._files(app_id)
            draft_rev = state["draftRev"]
        definitions, problems = self._definitions(app_id, files)
        queries: dict[str, Any] = {}
        if definitions is not None:
            try:
                checked = self.store.validate_definitions(app_id, definitions)
                queries = {
                    name: {"columns": q["columns"], "shape": q["shape"], "completeness": q["completeness"]}
                    for name, q in checked["queries"].items()
                }
            except StoreError as exc:
                problems.append(Diagnostic(DEFINITIONS_FILE, 1, str(exc)))
        out_dir = self._draft(app_id) / "dist"
        result = self.builder.build(files, definitions, out_dir)
        diagnostics = problems + result.diagnostics
        definitions_ok = not any(d.severity == "error" for d in problems)
        ok = result.ok and definitions_ok
        stage = result.stage if not result.ok else ("done" if definitions_ok else "definitions")
        merged = BuildResult(ok, stage, diagnostics, result.log, result.seconds, result.dist_dir, result.size)
        with self._lock(app_id):
            record = {"ok": ok, "draftRev": draft_rev, "at": _now(), "size": result.size}
            if ok:
                record["buildId"] = "build_" + uuid.uuid4().hex[:10]
            _atomic_write(self._draft(app_id) / "build.json", json.dumps(record))
            current = self._state(app_id)["draftRev"] == draft_rev
        summary = merged.summary()
        summary.update({"draftRev": draft_rev, "current": current, "queries": queries})
        if ok:
            summary["buildId"] = record["buildId"]
        return summary

    # -- publish and review -----------------------------------------------------

    def _checked_build(self, app_id: str, state: dict[str, Any]) -> dict[str, Any]:
        record = self._build_record(app_id)
        if not record or not record["ok"]:
            raise StoreError("there is no successful build of this draft; run app_build first")
        if record["draftRev"] != state["draftRev"]:
            raise Conflict("the draft changed after the last build; run app_build again")
        self._check_base(app_id, state)
        return record

    def _check_base(self, app_id: str, state: dict[str, Any]) -> None:
        current = self.store._row(app_id)["revision"]
        if current != state["baseRevision"]:
            raise Conflict(
                f"the app was published (revision {current}) after this draft started from revision "
                f"{state['baseRevision']}; reset the draft or rebuild on top of the published version"
            )

    def publish(self, app_id: str) -> dict[str, Any]:
        """With an approver paired this submits the build for review; otherwise it publishes."""
        with self._lock(app_id):
            state = self._ensure(app_id)
            record = self._checked_build(app_id, state)
            receipt = state.get("publishedBuild")
            if receipt and (receipt["buildId"], receipt["draftRev"]) == (record["buildId"], state["draftRev"]):
                return self._publication_result(receipt)
            if self.store.approver_count() > 0:
                return self._submit_locked(app_id, state, record)
            return self._publish_locked(app_id, state)

    def _build_bundle(self, app_id: str) -> tuple[dict[str, Any], dict[str, Any], B.BuiltBundle]:
        files = self._files(app_id)
        definitions = json.loads(files[DEFINITIONS_FILE])
        normalised = self.store.validate_definitions(app_id, definitions)  # against the data as it is now
        try:
            built = B.build_bundle(self._draft(app_id) / "dist", contract_hash=self.store.contract_hash(normalised))
        except B.BundleError as exc:
            raise StoreError(f"bundle rejected: {exc}") from None
        return definitions, normalised, built

    def _reviewed_bundle(self, app_id: str, info: dict[str, Any]) -> B.BuiltBundle:
        path = self._draft(app_id) / "review-bundle.zip"
        try:
            if path.stat().st_size > B.MAX_COMPRESSED:
                raise B.BundleError("bundle exceeds compressed size limit")
            data = path.read_bytes()
            manifest = B.verify_bundle(data, expected_id=info["bundleId"])
        except OSError:
            raise StoreError("review bundle unavailable; submit the build again") from None
        except B.BundleError as exc:
            raise StoreError(f"review bundle rejected: {exc}") from None
        if manifest.get("contractHash") != self.store.contract_hash(info["definitions"]):
            raise StoreError("review bundle has a different query/action contract")
        return B.BuiltBundle(info["bundleId"], data, manifest)

    def _publish_locked(
        self, app_id: str, state: dict[str, Any], *, review: dict[str, Any] | None = None
    ) -> dict[str, Any]:
        if review is None:
            definitions, _, built = self._build_bundle(app_id)
        else:
            built = self._reviewed_bundle(app_id, review)
            definitions = review["definitions"]
        revision = state["baseRevision"] + 1
        receipt = {
            "buildId": review["buildId"] if review else self._build_record(app_id)["buildId"],
            "draftRev": state["draftRev"], "revision": revision,
            "bundleId": built.bundle_id, "bundleBytes": len(built.data),
        }
        pending = {
            "version": 1, "appId": app_id, "epoch": self.store.epoch(),
            "baseRevision": state["baseRevision"], "revision": revision,
            "bundleId": built.bundle_id, "contractHash": built.manifest["contractHash"],
            "state": {**state, "baseRevision": revision, "publishedBuild": receipt},
        }
        try:
            self._snapshot_sources(app_id)
            _atomic_write(self._publication_path(app_id), json.dumps(pending, indent=2))
        except OSError:
            try:
                self._discard_publication(app_id)
            except OSError:
                pass  # The next operation clears an interrupted, uncommitted preparation.
            raise StoreError("could not prepare publication sources; nothing was published; retry the publication") from None
        try:
            revision = self.store.publish(app_id, built, definitions)
        except Exception:
            # Even a failure reported at the Store boundary can follow its registry COMMIT. Never
            # replay publish: the exact registry identity decides whether to finish or discard.
            try:
                committed = self._publication_committed(app_id, pending)
            except Exception:
                raise Conflict("publication outcome could not be reconciled; pending record retained for recovery") from None
            if not committed:
                try:
                    self._discard_publication(app_id)
                except OSError:
                    pass
                raise
            revision = pending["revision"]
        result = self._publication_result({**receipt, "revision": revision})
        try:
            if revision != pending["revision"]:
                # Plain Store publishers do not participate in this lock. Record the returned
                # revision if one raced us; an interrupted update is refused rather than guessed.
                pending["revision"] = pending["state"]["baseRevision"] = receipt["revision"] = revision
                _atomic_write(self._publication_path(app_id), json.dumps(pending, indent=2))
            if not self._publication_committed(app_id, pending):
                raise Conflict("registry no longer identifies the committed publication")
            self._finish_publication(app_id, pending)
        except Exception:
            logging.getLogger(__name__).warning(
                "Publication of %s at revision %s committed; authoring finalization is pending",
                app_id, revision, exc_info=True,
            )
            result["finalizationPending"] = True
        return result

    @staticmethod
    def _publication_result(receipt: dict[str, Any]) -> dict[str, Any]:
        return {"status": "published", **{k: receipt[k] for k in ("revision", "bundleId", "bundleBytes")}}

    def _publication_path(self, app_id: str) -> Path:
        return self.store.app_dir(app_id) / "pending-publication.json"

    def _publication_committed(self, app_id: str, pending: dict[str, Any]) -> bool:
        """Reconcile, never replay. An unrelated registry change must not acquire these sources."""
        if pending["appId"] != app_id or pending["epoch"] != self.store.epoch():
            raise Conflict("pending publication belongs to another registry identity; manual recovery required")
        row = self.store._row(app_id)
        if row["revision"] == pending["baseRevision"]:
            return False
        if (row["revision"] == pending["revision"] and row["bundle_id"] == pending["bundleId"]
                and self.store.contract_hash(json.loads(row["definitions"])) == pending["contractHash"]):
            return True
        raise Conflict("registry changed while a publication awaited finalization; manual recovery required")

    def _discard_publication(self, app_id: str) -> None:
        prepared = self.store.app_dir(app_id) / "source.pending"
        if _exists(prepared):
            shutil.rmtree(prepared)
        self._publication_path(app_id).unlink(missing_ok=True)

    def _recover_publication(self, app_id: str) -> None:
        """Lazy recovery under the cooperative authoring lock, also after a process restart."""
        path = self._publication_path(app_id)
        try:
            has_record = _exists(path)
        except OSError:
            raise Conflict("pending publication record is unavailable; retry authoring after repair") from None
        if not has_record:
            # A crash during copying, before the journal was written, cannot have published.
            try:
                prepared = path.parent / "source.pending"
                if _exists(prepared):
                    shutil.rmtree(prepared)
            except OSError:
                raise Conflict("unfinished publication preparation could not be cleared; retry authoring after repair") from None
            return
        try:
            if path.stat().st_size > 64 * 1024:
                raise ValueError("oversized publication record")
            pending = json.loads(path.read_text(encoding="utf-8"))
            state, receipt = pending["state"], pending["state"]["publishedBuild"]
            if (pending["version"] != 1 or state["baseRevision"] != pending["revision"]
                    or receipt["revision"] != pending["revision"] or receipt["bundleId"] != pending["bundleId"]
                    or receipt["draftRev"] != state["draftRev"] or not isinstance(receipt["buildId"], str)):
                raise ValueError("invalid publication record")
            self._publication_result(receipt)  # All response fields must be available before finalizing.
            committed = self._publication_committed(app_id, pending)
        except Conflict:
            raise
        except Exception:
            raise Conflict("pending publication record cannot be reconciled; record retained for recovery after repair") from None
        try:
            if committed:
                self._finish_publication(app_id, pending)
            else:
                self._discard_publication(app_id)
        except Exception:
            if committed:
                raise Conflict(
                    f"publication revision {pending['revision']} is committed; authoring finalization is pending; "
                    "retry authoring after repair"
                ) from None
            raise Conflict("uncommitted publication preparation could not be cleared; retry authoring after repair") from None

    def _finish_publication(self, app_id: str, pending: dict[str, Any]) -> None:
        root = self.store.app_dir(app_id)
        prepared, target, previous = root / "source.pending", root / "source", root / "source.previous"
        if _exists(prepared):
            if not prepared.is_dir():
                raise OSError("prepared publication sources are not a directory")
            if _exists(target):
                if _exists(previous):
                    shutil.rmtree(previous)
                os.replace(target, previous)
            os.replace(prepared, target)
        elif not target.is_dir():
            raise OSError("prepared publication sources are missing")
        # Missing prepared + present target means promotion already completed. The journal remains
        # until all remaining steps succeed, so every directory/save/unlink step can be retried.
        self._save_state(app_id, pending["state"])
        self._withdraw_review(app_id, announce=False)
        if _exists(previous):
            shutil.rmtree(previous)
        # Notifications are at-least-once across a crash between emit and journal deletion;
        # registry publication events are already committed by Store.publish and are not replayed.
        self.store.emit("review.changed", app_id, {"status": "published", "revision": pending["revision"]})
        self._publication_path(app_id).unlink()

    def _submit_locked(self, app_id: str, state: dict[str, Any], record: dict[str, Any]) -> dict[str, Any]:
        definitions, normalised, built = self._build_bundle(app_id)
        row = self.store._row(app_id)
        draft = self._draft(app_id)
        info = {
            "buildId": record["buildId"],
            "draftRev": state["draftRev"],
            "baseRevision": state["baseRevision"],
            "bundleId": built.bundle_id,
            "bundleBytes": len(built.data),
            "bundleManifest": built.manifest,
            "title": row["title"],
            "icon": row["icon"],
            "isNew": row["bundle_id"] is None,
            "submittedAt": _now(),
            "definitions": normalised,
        }
        (draft / "review-bundle.zip").write_bytes(built.data)
        _atomic_write(draft / "review.json", json.dumps(info))
        self.store.emit("review.changed", app_id, {"status": "awaiting_review", "buildId": record["buildId"]})
        return {
            "status": "awaiting_review",
            "buildId": record["buildId"],
            "draftRev": state["draftRev"],
            "message": "The build is waiting for the user's approval on the phone (Preview). "
                       "Nothing has been published; tell the user to open the preview.",
        }

    def _review(self, app_id: str, state: dict[str, Any] | None = None) -> dict[str, Any] | None:
        """The submitted build if it still belongs to the current draft, else None."""
        path = self._draft(app_id) / "review.json"
        if not path.is_file():
            return None
        info = json.loads(path.read_text(encoding="utf-8"))
        state = state or self._state(app_id)
        if info["draftRev"] != state["draftRev"] or info["baseRevision"] != self.store._row(app_id)["revision"]:
            return None
        return info

    def _withdraw_review(self, app_id: str, announce: bool = True) -> None:
        draft = self._draft(app_id)
        existed = (draft / "review.json").is_file()
        for name in ("review.json", "review-bundle.zip"):
            (draft / name).unlink(missing_ok=True)
        if existed and announce:
            self.store.emit("review.changed", app_id, {"status": "withdrawn"})

    # -- what the phone sees and does ---------------------------------------------

    def _nothing_to_review_or_recover(self, app_id: str) -> bool:
        """True when no submitted build and no unfinished publication exist for the app, so the phone's
        poll can skip the cross-process lock. Without these three paths `_review` finds nothing and
        `_recover_publication` has nothing to do. Any doubt (an unreadable path) means "take the lock"."""
        root = self.store._app_dir(app_id)
        try:
            return not any(
                _exists(path)
                for path in (root / "draft" / "review.json", root / "pending-publication.json", root / "source.pending")
            )
        except OSError:
            return False

    def reviews(self) -> list[dict[str, Any]]:
        out = []
        for app in self.store.all_apps():
            app_id = app["appId"]
            if self._nothing_to_review_or_recover(app_id):
                continue
            # Recovery may still be pending after review.json was removed. Take the lock before
            # checking for a review, so unavailable journal metadata cannot be mistaken for absence.
            with self._lock(app_id):
                info = self._review(app_id)
            if info:
                out.append({
                    "appId": app_id, "title": info["title"], "icon": info["icon"], "draftRev": info["draftRev"],
                    "buildId": info["buildId"], "baseRevision": info["baseRevision"], "isNew": info["isNew"],
                    "submittedAt": info["submittedAt"], "bundleBytes": info["bundleBytes"],
                })
        return sorted(out, key=lambda r: r["submittedAt"], reverse=True)

    def _require_review(self, app_id: str) -> dict[str, Any]:
        info = self._review(app_id) if (self._draft(app_id) / "review.json").is_file() else None
        if info is None:
            raise NotFound("nothing is awaiting review for this app")
        return info

    def review_manifest(self, app_id: str) -> dict[str, Any]:
        with self._lock(app_id):
            info = self._require_review(app_id)
        bundle = info["bundleManifest"]
        defs = info["definitions"]
        return {
            "appId": app_id,
            "title": info["title"],
            "icon": info["icon"],
            "revision": info["draftRev"],
            "epoch": self.store.epoch(),
            "bundle": {
                "bundleId": info["bundleId"],
                "size": info["bundleBytes"],
                "format": bundle["format"],
                "sdkMajor": bundle["sdkMajor"],
                "capabilities": bundle["capabilities"],
                "contractHash": bundle["contractHash"],
            },
            "queries": {
                name: {"params": q.get("params", {}), "shape": q["shape"], "maxRows": q["maxRows"],
                       "columns": q["columns"], "completeness": q["completeness"]}
                for name, q in defs["queries"].items()
            },
            "mutations": self.store.mutations_manifest(defs),
            **({"files": {name: {"params": f.get("params", {})} for name, f in defs["files"].items()}}
               if defs.get("files") else {}),
            "preview": {
                "buildId": info["buildId"], "baseRevision": info["baseRevision"],
                "isNew": info["isNew"], "submittedAt": info["submittedAt"],
            },
        }

    def review_bundle_path(self, app_id: str, bundle_id: str) -> Path:
        with self._lock(app_id):
            info = self._require_review(app_id)
        path = self._draft(app_id) / "review-bundle.zip"
        if bundle_id != info["bundleId"] or not path.is_file():
            raise NotFound("unknown bundle")
        return path

    def review_query(
        self, app_id: str, revision: int, calls: list[dict[str, Any]], *, device_id: str, tz_name: str | None
    ) -> dict[str, Any]:
        with self._lock(app_id):
            info = self._require_review(app_id)
        if revision != info["draftRev"]:
            raise Conflict("stale revision")
        return self.store.run_queries_with(
            app_id, info["definitions"]["queries"], revision, calls, device_id=device_id, tz_name=tz_name
        )

    def challenge(self, app_id: str) -> dict[str, Any]:
        """A one-time message for the phone to sign: it names exactly what it would publish."""
        with self._lock(app_id):
            info = self._require_review(app_id)
        if self.store.approver_count() == 0:
            raise StoreError("no device is paired as approver")
        nonce = self.store.issue_nonce(app_id, info["buildId"], info["draftRev"])
        return {
            "appId": app_id,
            "buildId": info["buildId"],
            "draftRev": info["draftRev"],
            "bundleId": info["bundleId"],
            "baseRevision": info["baseRevision"],
            "nonce": nonce,
            "message": approval.canonical_message(
                app_id, info["buildId"], info["draftRev"], info["bundleId"], info["baseRevision"], nonce
            ),
        }

    def approve(self, app_id: str, *, build_id: str, nonce: str, signature: str) -> dict[str, Any]:
        """Publish the reviewed build if, and only if, the paired device signed this very build."""
        with self._lock(app_id):
            info = self._require_review(app_id)
            if info["buildId"] != build_id:
                raise Conflict("the build under review changed; open the preview again")
            self.store.consume_nonce(nonce, app_id, build_id, info["draftRev"])
            message = approval.canonical_message(
                app_id, build_id, info["draftRev"], info["bundleId"], info["baseRevision"], nonce
            )
            if not any(approval.verify(key, message, signature) for key in self.store.approver_keys()):
                raise ApprovalRefused("the approval is not signed by the paired device")
            state = self._state(app_id)
            self._check_base(app_id, state)
            return self._publish_locked(app_id, state, review=info)

    def reject(self, app_id: str, *, expected_build_id: str | None = None) -> dict[str, Any]:
        """Withdraw this review; trusted direct/admin callers may omit the expected build."""
        with self._lock(app_id):
            info = self._require_review(app_id)
            if expected_build_id is not None and info["buildId"] != expected_build_id:
                raise Conflict("the build under review changed; open the preview again")
            self._withdraw_review(app_id, announce=False)
            self.store.emit("review.changed", app_id, {"status": "rejected"})
        return {"status": "rejected"}

    # -- deletion, decided by the paired device ----------------------------------

    def _deletable(self, app_id: str) -> Any:
        row = self.store._row(app_id)
        if row["bundle_id"] is None:
            raise NotFound("app is not published")
        if self.store.approver_count() == 0:
            raise StoreError("no device is paired as approver")
        root = self.store._app_dir(app_id)
        if _exists(root / "pending-publication.json") or _exists(root / "source.pending") or self._review(app_id):
            raise Conflict("a preview of this app is waiting for a decision; approve or reject it first")
        return row

    def delete_challenge(self, app_id: str) -> dict[str, Any]:
        """A one-time message for the phone to sign: it names exactly the published revision it would delete."""
        with self._lock(app_id):
            row = self._deletable(app_id)
        nonce = self.store.issue_nonce(app_id, f"delete:{row['bundle_id']}", row["revision"])
        return {
            "appId": app_id,
            "revision": row["revision"],
            "bundleId": row["bundle_id"],
            "nonce": nonce,
            "message": approval.canonical_delete_message(app_id, row["revision"], row["bundle_id"], nonce),
        }

    def delete_app(self, app_id: str, *, nonce: str, signature: str) -> dict[str, Any]:
        """Delete (to the trash) a published app if, and only if, the paired device signed this very revision."""
        with self._lock(app_id):
            row = self._deletable(app_id)
            self.store.consume_nonce(nonce, app_id, f"delete:{row['bundle_id']}", row["revision"])
            message = approval.canonical_delete_message(app_id, row["revision"], row["bundle_id"], nonce)
            if not any(approval.verify(key, message, signature) for key in self.store.approver_keys()):
                raise ApprovalRefused("the deletion is not signed by the paired device")
            slot = self.store.unregister_app(app_id)
        # After the lock file is released: a held file inside the directory would block the move on Windows.
        self.store.move_to_trash(app_id, slot)
        return {"status": "deleted", "appId": app_id}

    # -- helpers ------------------------------------------------------------------

    @staticmethod
    def _definitions(app_id: str, files: dict[str, str]) -> tuple[dict[str, Any] | None, list[Diagnostic]]:
        try:
            parsed = json.loads(files.get(DEFINITIONS_FILE, _EMPTY_DEFINITIONS))
        except json.JSONDecodeError as exc:
            return None, [Diagnostic(DEFINITIONS_FILE, exc.lineno, f"not valid JSON: {exc.msg}")]
        if not isinstance(parsed, dict):
            return None, [Diagnostic(DEFINITIONS_FILE, 1, "must be an object with queries and mutations")]
        return parsed, []

    def _snapshot_sources(self, app_id: str) -> None:
        """Freeze sources before any registry commit; finalization promotes this exact directory."""
        staging = self.store.app_dir(app_id) / "source.pending"
        if _exists(staging):
            shutil.rmtree(staging)
        shutil.copytree(self._draft(app_id) / "files", staging)
