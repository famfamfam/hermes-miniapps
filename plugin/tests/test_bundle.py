import hashlib
import io
import json
import lzma
import zipfile
import zlib

import pytest

from mobile_surfaces_core import bundle as B
from mobile_surfaces_core.bundle import BundleError
from mobile_surfaces_core.store import StoreError


@pytest.fixture
def dist(tmp_path):
    d = tmp_path / "dist"
    (d / "assets").mkdir(parents=True)
    (d / "index.html").write_text("<!doctype html><script src=assets/app.js></script>")
    (d / "assets" / "app.js").write_text("console.log(1)")
    return d


def make_zip(entries, manifest=None, manifest_bytes=None):
    """Hand-roll an archive, optionally hostile."""
    files = []
    for name, data in entries.items():
        files.append({"path": name, "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)})
    if manifest_bytes is None:
        manifest = manifest or {"format": 1, "entrypoint": "index.html", "sdkMajor": 1, "capabilities": [], "files": files}
        manifest_bytes = json.dumps(manifest).encode()
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("bundle.json", manifest_bytes)
        for name, data in entries.items():
            zf.writestr(name, data)
    return buf.getvalue(), B.digest_bytes(manifest_bytes)


def test_roundtrip(dist):
    built = B.build_bundle(dist)
    manifest = B.verify_bundle(built.data, expected_id=built.bundle_id)
    assert manifest["entrypoint"] == "index.html"
    assert {f["path"] for f in manifest["files"]} == {"index.html", "assets/app.js"}
    assert built.bundle_id.startswith("sha256:")


@pytest.mark.parametrize("compression", [
    zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED, zipfile.ZIP_LZMA, zipfile.ZIP_BZIP2,
], ids=["stored", "deflate", "lzma", "bzip2"])
def test_valid_archive_compression_remains_supported(dist, compression):
    built = B.build_bundle(dist)
    buf = io.BytesIO()
    with zipfile.ZipFile(io.BytesIO(built.data)) as original, zipfile.ZipFile(buf, "w", compression) as rebuilt:
        for info in original.infolist():
            rebuilt.writestr(info.filename, original.read(info.filename))
    assert B.verify_bundle(buf.getvalue(), expected_id=built.bundle_id) == built.manifest


@pytest.mark.parametrize("error", [MemoryError, KeyboardInterrupt, SystemExit])
def test_archive_member_memory_and_process_interrupts_are_not_normalized(dist, monkeypatch, error):
    built = B.build_bundle(dist)

    def interrupted_read(*args, **kwargs):
        raise error("synthetic interruption")

    monkeypatch.setattr(zipfile.ZipFile, "read", interrupted_read)
    with pytest.raises(error):
        B.verify_bundle(built.data, expected_id=built.bundle_id)


def test_bundle_id_is_stable_for_same_content(dist):
    assert B.build_bundle(dist).bundle_id == B.build_bundle(dist).bundle_id


def test_content_change_changes_id(dist):
    a = B.build_bundle(dist).bundle_id
    (dist / "assets" / "app.js").write_text("console.log(2)")
    assert B.build_bundle(dist).bundle_id != a


def test_wrong_expected_id_rejected(dist):
    built = B.build_bundle(dist)
    with pytest.raises(BundleError, match="digest"):
        B.verify_bundle(built.data, expected_id="sha256:" + "0" * 64)


@pytest.mark.parametrize(
    "name",
    ["../evil.js", "/abs.js", "a/../../b.js", "a\\b.js", "a//b.js", "./x.js", "bundle.json", "sp ace.js", "a/.", "x\x00.js"],
)
def test_bad_paths_rejected(name):
    with pytest.raises(BundleError):
        B.check_path(name)


def test_traversal_entry_in_archive_rejected():
    data, bid = make_zip({"index.html": b"x", "../evil.js": b"y"})
    with pytest.raises(BundleError):
        B.verify_bundle(data, expected_id=bid)


def test_hash_mismatch_rejected():
    files = [{"path": "index.html", "sha256": "0" * 64, "size": 1}]
    data, bid = make_zip({"index.html": b"x"}, manifest={"format": 1, "entrypoint": "index.html", "sdkMajor": 1, "capabilities": [], "files": files})
    with pytest.raises(BundleError, match="mismatch"):
        B.verify_bundle(data, expected_id=bid)


def test_unlisted_file_rejected():
    entries = {"index.html": b"x"}
    data, bid = make_zip(entries)
    buf = io.BytesIO(data)
    with zipfile.ZipFile(buf, "a") as zf:
        zf.writestr("sneaky.js", b"alert(1)")
    with pytest.raises(BundleError, match="unlisted"):
        B.verify_bundle(buf.getvalue(), expected_id=bid)


def test_listed_but_missing_rejected():
    files = [{"path": "index.html", "sha256": hashlib.sha256(b"x").hexdigest(), "size": 1}]
    data, bid = make_zip({}, manifest={"format": 1, "entrypoint": "index.html", "sdkMajor": 1, "capabilities": [], "files": files})
    with pytest.raises(BundleError, match="missing"):
        B.verify_bundle(data, expected_id=bid)


def test_case_colliding_names_rejected():
    data, bid = make_zip({"index.html": b"x", "Index.html": b"y"})
    with pytest.raises(BundleError, match="case"):
        B.verify_bundle(data, expected_id=bid)


def test_unsupported_format_rejected():
    data, bid = make_zip({"index.html": b"x"}, manifest={"format": 99, "entrypoint": "index.html", "files": []})
    with pytest.raises(BundleError, match="format"):
        B.verify_bundle(data, expected_id=bid)


@pytest.mark.parametrize("value", [True, False, 1.0, "1", [1], None], ids=repr)
def test_format_must_be_the_integer_one(value):
    # True == 1 and 1.0 == 1 in Python; the Dart verifier and the shared fixtures require an integer.
    entries = {"index.html": b"x"}
    files = [{"path": "index.html", "sha256": hashlib.sha256(b"x").hexdigest(), "size": 1}]
    data, bid = make_zip(entries, manifest={"format": value, "entrypoint": "index.html", "sdkMajor": 1,
                                            "capabilities": [], "files": files})
    with pytest.raises(BundleError, match="unsupported bundle format"):
        B.verify_bundle(data, expected_id=bid)


def test_symlink_entry_rejected():
    manifest = {"format": 1, "entrypoint": "index.html",
                "files": [{"path": "index.html", "sha256": hashlib.sha256(b"x").hexdigest(), "size": 1}]}
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("bundle.json", json.dumps(manifest))
        zf.writestr("index.html", b"x")
        link = zipfile.ZipInfo("link.js")
        link.external_attr = 0o120777 << 16
        zf.writestr(link, "index.html")
    with pytest.raises(BundleError, match="symlink"):
        B.verify_bundle(buf.getvalue())


def test_unpacked_size_limit(monkeypatch, dist):
    monkeypatch.setattr(B, "MAX_UNPACKED", 10)
    with pytest.raises(BundleError, match="unpacked"):
        B.build_bundle(dist)


def test_file_count_limit(monkeypatch, dist):
    monkeypatch.setattr(B, "MAX_FILES", 1)
    with pytest.raises(BundleError, match="too many"):
        B.build_bundle(dist)


def test_missing_entrypoint(dist):
    with pytest.raises(BundleError, match="entrypoint"):
        B.build_bundle(dist, entrypoint="nope.html")


def test_garbage_is_not_a_bundle():
    with pytest.raises(BundleError):
        B.verify_bundle(b"not a zip")


@pytest.mark.parametrize("member", ["bundle.json", "index.html"])
@pytest.mark.parametrize("damage", ["crc", "deflate", "lzma", "bzip2"])
def test_damaged_member_with_valid_central_directory_is_a_bundle_error(dist, damage_bundle_member, member, damage):
    built = B.build_bundle(dist)
    damaged = damage_bundle_member(built.data, member, damage)
    with zipfile.ZipFile(io.BytesIO(damaged)) as archive:
        assert member in archive.namelist()  # Opening/listing alone does not expose the damage.
        error = {"crc": zipfile.BadZipFile, "deflate": zlib.error, "lzma": lzma.LZMAError, "bzip2": OSError}[damage]
        with pytest.raises(error):
            archive.read(member)
    with pytest.raises(BundleError, match="member"):
        B.verify_bundle(damaged, expected_id=built.bundle_id)


@pytest.mark.parametrize("member", ["bundle.json", "index.html"])
@pytest.mark.parametrize("damage", ["crc", "deflate", "lzma", "bzip2"])
def test_store_refuses_damaged_members_without_registry_advancement(store, dist, damage_bundle_member, member, damage):
    store.create_app("broken", "Broken")
    defs = {"queries": {}, "mutations": {}}
    built = B.build_bundle(dist, contract_hash=store.contract_hash(defs))
    corrupted = B.BuiltBundle(built.bundle_id, damage_bundle_member(built.data, member, damage), built.manifest)
    with pytest.raises(StoreError, match="bundle rejected"):
        store.publish("broken", corrupted, defs)
    assert store._row("broken")["revision"] == 0 and store.list_apps() == []
    assert not (store.app_dir("broken") / "bundles").exists()
