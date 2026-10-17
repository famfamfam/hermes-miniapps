"""Immutable web bundle: zip with bundle.json (ADR-005, section 3).

bundleId = "sha256:" + SHA-256 of the exact bytes of bundle.json. bundle.json holds
the per-file hashes but not its own digest, so there is no self-reference and no
need for canonical JSON on the verifying side: hash the bytes as served.
"""
from __future__ import annotations

import hashlib
import io
import json
import lzma
import posixpath
import re
import zipfile
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

FORMAT = 1
MANIFEST_NAME = "bundle.json"
MAX_FILES = 1000
MAX_COMPRESSED = 10 * 1024 * 1024
MAX_UNPACKED = 30 * 1024 * 1024
_SEGMENT = re.compile(r"^[A-Za-z0-9._@~+-]+$")


class BundleError(ValueError):
    """Bundle failed validation; never install or serve it."""


@dataclass(frozen=True)
class BuiltBundle:
    bundle_id: str
    data: bytes
    manifest: dict[str, Any]


def check_path(path: str) -> None:
    """Reject absolute paths, traversal, backslashes, odd segments and reserved names."""
    if not path or path.startswith("/") or "\\" in path or "\x00" in path:
        raise BundleError(f"bad path: {path!r}")
    if path == MANIFEST_NAME:
        raise BundleError("bundle.json cannot be listed as a file")
    for seg in path.split("/"):
        if seg in ("", ".", "..") or not _SEGMENT.match(seg):
            raise BundleError(f"bad path segment in {path!r}")
    if posixpath.normpath(path) != path:
        raise BundleError(f"non-normalised path: {path!r}")


def _is_int(value: object) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def digest_bytes(data: bytes) -> str:
    return "sha256:" + hashlib.sha256(data).hexdigest()


def build_bundle(
    dist_dir: Path,
    *,
    entrypoint: str = "index.html",
    sdk_major: int = 1,
    capabilities: list[str] | None = None,
    contract_hash: str | None = None,
) -> BuiltBundle:
    dist_dir = dist_dir.resolve()
    entries: list[dict[str, Any]] = []
    blobs: dict[str, bytes] = {}
    for file in sorted(p for p in dist_dir.rglob("*") if p.is_file()):
        if file.is_symlink():
            raise BundleError(f"symlink in dist: {file}")
        rel = file.relative_to(dist_dir).as_posix()
        check_path(rel)
        data = file.read_bytes()
        blobs[rel] = data
        entries.append({"path": rel, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    if entrypoint not in blobs:
        raise BundleError(f"entrypoint {entrypoint!r} missing from dist")
    manifest = {
        "format": FORMAT,
        "entrypoint": entrypoint,
        "sdkMajor": sdk_major,
        "capabilities": sorted(capabilities or []),
        "contractHash": contract_hash,
        "files": entries,
    }
    manifest_bytes = json.dumps(manifest, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(_info(MANIFEST_NAME), manifest_bytes)
        for rel, data in blobs.items():
            zf.writestr(_info(rel), data)
    built = buf.getvalue()
    verify_bundle(built, expected_id=digest_bytes(manifest_bytes))
    return BuiltBundle(bundle_id=digest_bytes(manifest_bytes), data=built, manifest=manifest)


def _info(name: str) -> zipfile.ZipInfo:
    info = zipfile.ZipInfo(name, date_time=(2020, 1, 1, 0, 0, 0))
    info.compress_type = zipfile.ZIP_DEFLATED
    info.external_attr = 0o644 << 16
    return info


def _read_member(zf: zipfile.ZipFile, name: str) -> bytes:
    # A valid central directory says nothing about a member's local header, CRC or compression stream.
    try:
        return zf.read(name)
    except (zipfile.BadZipFile, zlib.error, lzma.LZMAError, OSError, EOFError,
            RuntimeError, NotImplementedError, UnicodeError) as exc:
        raise BundleError(f"invalid archive member {name!r}: {exc}") from None


def verify_bundle(data: bytes, *, expected_id: str | None = None) -> dict[str, Any]:
    """Validate zip structure, limits, paths and hashes. Returns the parsed bundle.json."""
    if len(data) > MAX_COMPRESSED:
        raise BundleError("bundle exceeds compressed size limit")
    try:
        zf = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile as exc:
        raise BundleError(f"not a zip: {exc}") from None
    with zf:
        infos = zf.infolist()
        if len(infos) > MAX_FILES + 1:
            raise BundleError("too many files")
        names = [i.filename for i in infos]
        if len(set(n.lower() for n in names)) != len(names):
            raise BundleError("duplicate or case-colliding names")
        if sum(i.file_size for i in infos) > MAX_UNPACKED:
            raise BundleError("bundle exceeds unpacked size limit")
        for i in infos:
            if i.is_dir() or (i.external_attr >> 16) & 0o170000 == 0o120000:
                raise BundleError(f"directory or symlink entry: {i.filename!r}")
        if MANIFEST_NAME not in names:
            raise BundleError("bundle.json missing")
        manifest_bytes = _read_member(zf, MANIFEST_NAME)
        if expected_id is not None and digest_bytes(manifest_bytes) != expected_id:
            raise BundleError("bundle.json digest does not match bundleId")
        try:
            manifest = json.loads(manifest_bytes)
        except json.JSONDecodeError as exc:
            raise BundleError(f"bundle.json is not JSON: {exc}") from None
        # Everything below is attacker-shaped JSON: check types before use, so malformed input is
        # always a BundleError and never an AttributeError/TypeError (the Dart verifier does the same).
        if not isinstance(manifest, dict):
            raise BundleError("bundle.json is not an object")
        if not _is_int(manifest.get("format")) or manifest.get("format") != FORMAT:
            raise BundleError(f"unsupported bundle format: {manifest.get('format')!r}")
        if not _is_int(manifest.get("sdkMajor")):
            raise BundleError("bundle.json: sdkMajor must be an integer")
        caps = manifest.get("capabilities")
        if not isinstance(caps, list) or not all(isinstance(c, str) for c in caps):
            raise BundleError("bundle.json: capabilities must be a list of strings")
        if not isinstance(manifest.get("entrypoint"), str):
            raise BundleError("bundle.json: entrypoint must be a string")
        listed = manifest.get("files")
        if not isinstance(listed, list) or not listed:
            raise BundleError("bundle.json lists no files")
        seen: set[str] = set()
        for entry in listed:
            if not isinstance(entry, dict):
                raise BundleError("bundle.json: file entry is not an object")
            path, digest, size = entry.get("path"), entry.get("sha256"), entry.get("size")
            if not isinstance(path, str) or not isinstance(digest, str) or not _is_int(size):
                raise BundleError("bundle.json: file entry needs string path, string sha256, integer size")
            check_path(path)
            if path in seen:
                raise BundleError(f"duplicate entry: {path}")
            seen.add(path)
            if path not in names:
                raise BundleError(f"listed file missing from archive: {path}")
            blob = _read_member(zf, path)
            if len(blob) != size or hashlib.sha256(blob).hexdigest() != digest:
                raise BundleError(f"hash or size mismatch: {path}")
        extra = set(names) - seen - {MANIFEST_NAME}
        if extra:
            raise BundleError(f"unlisted files in archive: {sorted(extra)}")
        if manifest["entrypoint"] not in seen:
            raise BundleError("entrypoint is not a listed file")
        return manifest
