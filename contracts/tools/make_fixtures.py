"""Generate bundle fixtures shared by the server (pytest) and the Flutter host (flutter test).

  python contracts/tools/make_fixtures.py

Writes contracts/fixtures/bundles/*.zip and index.json. Every case lists whether a verifier
must accept it; both implementations are tested against the same list.
"""
from __future__ import annotations

import hashlib
import io
import json
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "plugin"))

from mobile_surfaces_core.bundle import digest_bytes  # noqa: E402

OUT = ROOT / "contracts" / "fixtures" / "bundles"
INDEX_HTML = b"<!doctype html><title>fixture</title><script type=module src=app.js></script>"
APP_JS = b"document.title = 'ok';"

# Optional "error" in index.json: a substring BOTH verifiers' messages must contain, so a case is
# proven to be rejected by the rule it exists for and not by some other check that happens first.
ERRORS = {
    "symlink": "symlink entry",
    "symlink_listed": "symlink entry",
    "symlink_listed_unix": "symlink entry",
    "bad_format": "unsupported bundle format",
    "format_true": "unsupported bundle format",
    "format_float": "unsupported bundle format",
}


def entry(path: str, data: bytes) -> dict:
    return {"path": path, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}


def manifest_for(content: dict[str, bytes], **override) -> dict:
    m = {"format": 1, "entrypoint": "index.html", "sdkMajor": 1, "capabilities": [], "contractHash": None,
         "files": [entry(p, d) for p, d in content.items()]}
    m.update(override)
    return m


CREATE_WINDOWS = 0  # "version made by" host system FAT/NTFS: what zipfile writes on Windows
CREATE_UNIX = 3


def info_for(name: str, create_system: int = CREATE_WINDOWS) -> zipfile.ZipInfo:
    # Pin the host system byte: ZipInfo defaults it from the platform that runs this script, which
    # would make the committed fixtures differ between machines.
    info = zipfile.ZipInfo(name, (2020, 1, 1, 0, 0, 0))
    info.create_system = create_system
    return info


def build(files: dict[str, bytes], manifest: dict | None = None, extra=None, symlink: str | None = None,
          linked: dict[str, int] | None = None):
    """`symlink` adds an UNLISTED link entry. `linked` maps names in `files` (so LISTED, with correct
    hash and size) to the create_system byte of an entry whose mode bits say "symbolic link"."""
    mbytes = json.dumps(manifest or manifest_for(files), sort_keys=True, separators=(",", ":")).encode()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(info_for("bundle.json"), mbytes)
        for name, data in files.items():
            info = info_for(name, (linked or {}).get(name, CREATE_WINDOWS))
            if linked and name in linked:
                info.external_attr = 0o120777 << 16
            zf.writestr(info, data)
        for name, data in (extra or {}).items():
            zf.writestr(info_for(name), data)
        if symlink:
            info = info_for(symlink)
            info.external_attr = 0o120777 << 16
            zf.writestr(info, "index.html")
    return buf.getvalue(), digest_bytes(mbytes)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    good = {"index.html": INDEX_HTML, "app.js": APP_JS, "assets/style.css": b"body{margin:0}"}
    cases: dict[str, tuple[bytes, str, bool, str]] = {}

    data, bid = build(good)
    cases["good"] = (data, bid, True, "valid bundle with a nested asset")

    traversal = {"index.html": INDEX_HTML, "../evil.js": b"x"}
    data, bid = build(traversal)
    cases["traversal"] = (data, bid, False, "path escapes the bundle root")

    data, bid = build({"index.html": INDEX_HTML}, manifest_for({"index.html": INDEX_HTML}, files=[
        {"path": "index.html", "sha256": "0" * 64, "size": len(INDEX_HTML)}]))
    cases["hash_mismatch"] = (data, bid, False, "file content does not match its listed hash")

    data, bid = build({"index.html": INDEX_HTML}, extra={"sneaky.js": b"alert(1)"})
    cases["unlisted_file"] = (data, bid, False, "archive carries a file that bundle.json does not list")

    data, bid = build({"index.html": INDEX_HTML}, symlink="link.js")
    cases["symlink"] = (data, bid, False, "symlink entry")

    # A symlink that bundle.json LISTS, so no unlisted-file rule can reject it first. The mode bits
    # alone say "link"; zipfile on Windows writes create_system=0, which the Dart archive package
    # does not treat as Unix, so both host systems are covered.
    linked_files = {"index.html": INDEX_HTML, "link.js": b"index.html"}
    data, bid = build(linked_files, linked={"link.js": CREATE_WINDOWS})
    cases["symlink_listed"] = (data, bid, False, "listed symlink entry, written by a non-Unix host")
    data, bid = build(linked_files, linked={"link.js": CREATE_UNIX})
    cases["symlink_listed_unix"] = (data, bid, False, "listed symlink entry, written by a Unix host")

    data, bid = build({"index.html": INDEX_HTML}, manifest_for({"index.html": INDEX_HTML}, format=99))
    cases["bad_format"] = (data, bid, False, "unsupported bundle format")

    # JSON true == 1 and 1.0 == 1 in Python or Dart: format must be a strict integer in both.
    for name, value, why in (("format_true", True, "format is JSON true, not the integer 1"),
                             ("format_float", 1.0, "format is the float 1.0, not the integer 1")):
        data, bid = build({"index.html": INDEX_HTML}, manifest_for({"index.html": INDEX_HTML}, format=value))
        cases[name] = (data, bid, False, why)

    data, bid = build({"index.html": INDEX_HTML, "Index.html": b"y"})
    cases["case_collision"] = (data, bid, False, "names collide on case-insensitive filesystems")

    data, bid = build({"index.html": INDEX_HTML}, manifest_for({"index.html": INDEX_HTML}, entrypoint="missing.html"))
    cases["missing_entrypoint"] = (data, bid, False, "entrypoint is not a listed file")

    data, _ = build(good)
    cases["wrong_bundle_id"] = (data, "sha256:" + "0" * 64, False, "served bytes do not match the announced bundleId")

    # bundle.json that parses as JSON but has the wrong shape: both verifiers must say "invalid",
    # never crash with a type error.
    only = {"index.html": INDEX_HTML}
    ok = manifest_for(only)
    shapes = {
        "manifest_not_object": (["not", "an", "object"], "bundle.json is a JSON array"),
        "files_not_objects": ({**ok, "files": ["index.html"]}, "files entries are strings, not objects"),
        "size_not_integer": ({**ok, "files": [{**ok["files"][0], "size": "1"}]}, "size is a string"),
        "capabilities_not_list": ({**ok, "capabilities": "camera"}, "capabilities is a string"),
        "capabilities_not_strings": ({**ok, "capabilities": [1]}, "capabilities holds a number"),
        "sdk_major_missing": ({k: v for k, v in ok.items() if k != "sdkMajor"}, "no sdkMajor"),
        "entrypoint_not_string": ({**ok, "entrypoint": ["index.html"]}, "entrypoint is a list"),
    }
    for name, (manifest, why) in shapes.items():
        data, bid = build(only, manifest)
        cases[name] = (data, bid, False, why)

    index = {}
    for name, (blob, bundle_id, valid, why) in cases.items():
        (OUT / f"{name}.zip").write_bytes(blob)
        index[name] = {"file": f"{name}.zip", "bundleId": bundle_id, "valid": valid, "why": why}
        if name in ERRORS:
            index[name]["error"] = ERRORS[name]
    (OUT / "index.json").write_text(json.dumps(index, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(f"wrote {len(cases)} cases to {OUT}")


if __name__ == "__main__":
    main()
