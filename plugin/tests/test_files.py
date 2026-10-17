"""Files of an app: uploads from the phone, imports by the author, downloads through reviewed locators.

The page never names a path. What can leave the server is a stored file of the same app, or a file inside a
folder the administrator linked, reached by a named locator of the app's reviewed definitions.
"""
import asyncio
import errno
import hashlib
import json
import os
import sqlite3
import subprocess
from pathlib import Path
from urllib.parse import quote, unquote

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from mobile_surfaces.api import mount
from mobile_surfaces.mcp_server import create_mcp
from mobile_surfaces_core import bundle as B
from mobile_surfaces_core import files as F
from mobile_surfaces_core.errors import InsufficientStorage
from mobile_surfaces_core.store import Conflict, NotFound, Store, StoreError

BASE = "/api/plugins/mobile-surfaces/v1"
PDF = b"%PDF-1.4\n" + b"receipt " * 50
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64


def upload(client, app_id, name, data, **headers):
    return client.post(f"{BASE}/apps/{app_id}/files", content=data, headers={"X-File-Name": quote(name), **headers})


def leftovers(store, app_id):
    return sorted(p.name for p in (store.root / "apps" / app_id / "files").glob(".incoming-*"))


# ---------------------------------------------------------------------------------------------- stored files


def test_an_upload_comes_back_byte_for_byte_as_an_attachment(client):
    c, store, _built, _rev = client
    r = upload(c, "utilities", "Квитанция март.pdf", PDF)
    assert r.status_code == 200
    record = r.json()
    assert record["name"] == "Квитанция март.pdf" and record["mime"] == "application/pdf"
    assert record["size"] == len(PDF) and record["sha256"] == hashlib.sha256(PDF).hexdigest()
    assert record["source"] == "phone" and record["duplicate"] is False and record["fileId"].startswith("f_")

    got = c.get(f"{BASE}/apps/utilities/files/{record['fileId']}")
    assert got.status_code == 200 and got.content == PDF
    assert got.headers["content-type"] == "application/pdf"
    assert got.headers["content-disposition"].startswith("attachment")
    assert unquote(got.headers["x-file-name"]) == "Квитанция март.pdf"
    assert got.headers["x-content-type-options"] == "nosniff"
    assert got.headers["etag"] == f'"{record["sha256"]}"'
    assert [f["fileId"] for f in c.get(f"{BASE}/apps/utilities/files").json()["files"]] == [record["fileId"]]
    assert leftovers(store, "utilities") == []


def test_the_same_content_twice_is_one_file(client):
    c, _store, _built, _rev = client
    first = upload(c, "utilities", "a.pdf", PDF).json()
    again = upload(c, "utilities", "renamed.pdf", PDF).json()
    assert again["duplicate"] is True and again["fileId"] == first["fileId"]
    assert len(c.get(f"{BASE}/apps/utilities/files").json()["files"]) == 1


def test_the_name_is_reduced_to_a_plain_file_name(client):
    c, _store, _built, _rev = client
    name = upload(c, "utilities", "../../etc/passwd/..\\evil<>.pdf", PDF).json()["name"]
    assert "/" not in name and "\\" not in name and ".." not in name and "<" not in name
    assert name.endswith(".pdf")
    assert upload(c, "utilities", "x" * 300 + ".pdf", PDF + b"1").json()["name"].endswith(".pdf")
    assert len(upload(c, "utilities", "y" * 300 + ".pdf", PDF + b"2").json()["name"]) <= 120


@pytest.mark.parametrize("name", ["setup.exe", "run.sh", "page.html", "noextension", "photo.svg", "app.apk"])
def test_only_documents_pictures_and_archives_are_accepted(client, name):
    c, store, _built, _rev = client
    r = upload(c, "utilities", name, b"data")
    assert r.status_code == 400 and "not accepted" in r.json()["error"]
    assert store.files.list_files("utilities") == [] and leftovers(store, "utilities") == []


def test_the_type_comes_from_the_extension_not_from_what_the_sender_says(client):
    c, _store, _built, _rev = client
    record = upload(c, "utilities", "photo.png", PNG, **{"Content-Type": "text/html"}).json()
    assert record["mime"] == "image/png"
    assert c.get(f"{BASE}/apps/utilities/files/{record['fileId']}").headers["content-type"] == "image/png"


def test_an_empty_file_and_a_missing_name_are_refused(client):
    c, store, _built, _rev = client
    assert upload(c, "utilities", "empty.pdf", b"").status_code == 400
    assert c.post(f"{BASE}/apps/utilities/files", content=PDF).status_code == 400
    assert store.files.list_files("utilities") == [] and leftovers(store, "utilities") == []


def test_a_file_over_the_limit_is_refused_before_and_while_it_is_read(client, monkeypatch):
    c, store, _built, _rev = client
    monkeypatch.setattr(F, "MAX_FILE_BYTES", 100)
    announced = upload(c, "utilities", "big.pdf", b"x" * 101)
    assert announced.status_code == 413  # Content-Length says so; not one byte is written
    streamed = c.post(
        f"{BASE}/apps/utilities/files", headers={"X-File-Name": "big.pdf"},
        content=(b"y" * 60 for _ in range(3)),  # chunked: no Content-Length to go by
    )
    assert streamed.status_code == 413
    assert store.files.list_files("utilities") == [] and leftovers(store, "utilities") == []
    assert upload(c, "utilities", "ok.pdf", b"z" * 100).status_code == 200


def test_the_room_of_an_app_is_limited(client, monkeypatch):
    c, store, _built, _rev = client
    monkeypatch.setattr(F, "MAX_APP_FILES", 2)
    assert upload(c, "utilities", "1.pdf", b"one").status_code == 200
    assert upload(c, "utilities", "2.pdf", b"two").status_code == 200
    refused = upload(c, "utilities", "3.pdf", b"three")
    assert refused.status_code == 400 and "delete some" in refused.json()["error"]
    # the same content as an existing file costs nothing and is still answered
    assert upload(c, "utilities", "again.pdf", b"one").json()["duplicate"] is True

    monkeypatch.setattr(F, "MAX_APP_FILES", 200)
    monkeypatch.setattr(F, "MAX_APP_BYTES", 10)
    assert upload(c, "utilities", "4.pdf", b"x" * 8).status_code == 413
    assert leftovers(store, "utilities") == []


def test_the_room_of_the_whole_server_is_limited(client, monkeypatch):
    c, _store, _built, _rev = client
    monkeypatch.setattr(F, "MAX_TOTAL_BYTES", 5)
    r = upload(c, "utilities", "a.pdf", b"123456")
    assert r.status_code == 507


def test_a_full_disk_is_reported_as_such_and_leaves_nothing_behind(client, monkeypatch):
    c, store, _built, _rev = client

    def broken(self, chunk):
        raise F._storage_error(OSError(errno.ENOSPC, "No space left on device"))

    monkeypatch.setattr(F.Incoming, "write", broken)
    r = upload(c, "utilities", "a.pdf", PDF)
    assert r.status_code == 507 and "disk" in r.json()["error"]
    assert store.files.list_files("utilities") == [] and leftovers(store, "utilities") == []
    assert isinstance(F._storage_error(OSError(errno.ENOSPC, "x")), InsufficientStorage)
    assert not isinstance(F._storage_error(OSError(errno.EACCES, "x")), InsufficientStorage)


def test_a_file_belongs_to_its_app(client, tmp_path):
    c, store, _built, _rev = client
    store.create_app("other", "Other")
    mine = upload(c, "utilities", "a.pdf", PDF).json()["fileId"]
    assert c.get(f"{BASE}/apps/other/files/{mine}").status_code == 404
    assert c.delete(f"{BASE}/apps/other/files/{mine}").status_code == 404
    assert c.get(f"{BASE}/apps/other/files").json() == {"files": []}
    assert c.get(f"{BASE}/apps/utilities/files/{mine}").status_code == 200
    assert c.get(f"{BASE}/apps/nope_app/files").status_code == 404
    # the same bytes in another app are a file of that app, not a shared one
    assert upload(c, "other", "a.pdf", PDF).json()["fileId"] != mine


@pytest.mark.parametrize("file_id", ["f_xyz", "../../registry.db", "f_" + "0" * 16, "F_" + "a" * 16, "f_" + "a" * 17])
def test_only_ids_the_server_issued_open_a_file(client, file_id):
    c, _store, _built, _rev = client
    upload(c, "utilities", "a.pdf", PDF)
    assert c.get(f"{BASE}/apps/utilities/files/{file_id}").status_code in (404, 422)


def test_deleting_a_file_removes_it_and_tells_the_phones(client):
    c, store, _built, _rev = client
    record = upload(c, "utilities", "a.pdf", PDF).json()
    path = store.root / "apps" / "utilities" / "files" / record["fileId"]
    assert path.is_file()
    assert c.delete(f"{BASE}/apps/utilities/files/{record['fileId']}").json() == {"deleted": True}
    assert not path.exists() and c.get(f"{BASE}/apps/utilities/files/{record['fileId']}").status_code == 404
    events = store.events_since(0, None)
    events = store.events_since(0, events["epoch"])["events"]
    changes = [(e["payload"]["change"], e["payload"]["fileId"]) for e in events if e["type"] == "files.changed"]
    assert changes == [("added", record["fileId"]), ("deleted", record["fileId"])]
    assert all(e["appId"] == "utilities" for e in events if e["type"] == "files.changed")


def test_the_health_answer_says_files_are_served(client):
    c, _store, _built, _rev = client
    assert c.get(f"{BASE}/health").json()["files"] is True


# ---------------------------------------------------------------------------------------------- linked folders


@pytest.fixture
def receipts(tmp_path):
    """An app over a foreign database whose rows name PDF paths of the machine the skill runs on; the folder
    holding them is what this service sees (mounted somewhere else), linked with the prefix to strip."""
    folder = tmp_path / "skill_files"
    (folder / "2026-09").mkdir(parents=True)
    (folder / "2026-09" / "gas.pdf").write_bytes(PDF)
    (folder / "2026-09" / "photo.png").write_bytes(PNG)
    (folder / "notes.exe").write_bytes(b"MZ")
    (folder / "big.pdf").write_bytes(b"x" * 64)
    outside = tmp_path / "secret"
    outside.mkdir()
    (outside / "passwd.pdf").write_bytes(b"outside")

    foreign = tmp_path / "foreign" / "zhkh.db"
    foreign.parent.mkdir()
    conn = sqlite3.connect(foreign)
    conn.execute("CREATE TABLE receipts (id INTEGER PRIMARY KEY, period TEXT, file_path TEXT)")
    prefix = "/root/.hermes/zhkh"
    conn.executemany(
        "INSERT INTO receipts(id, period, file_path) VALUES (?,?,?)",
        [
            (1, "2026-09", f"{prefix}/2026-09/gas.pdf"),
            (2, "2026-09", None),
            (3, "2026-09", f"{prefix}/../secret/passwd.pdf"),
            (4, "2026-09", f"{prefix}/2026-09/gone.pdf"),
            (5, "2026-09", "/etc/passwd"),
            (6, "2026-09", f"{prefix}/notes.exe"),
            (7, "2026-09", f"{prefix}/2026-09"),
            (8, "2026-09", "2026-09/gas.pdf"),
            (9, "2026-09", f"{prefix}/2026-09/photo.png"),
            (10, "2026-09", f"{prefix}/big.pdf"),
        ],
    )
    conn.commit()
    conn.close()

    store = Store(tmp_path / "home")
    store.link_source("zhkh", "Квитанции ЖКХ", foreign)
    store.files.link_root("zhkh", "receipts", folder, strip_prefix=prefix)
    definitions = {
        "queries": {"receipts": {"sql": "SELECT id, period FROM receipts ORDER BY id", "shape": "rows"}},
        "mutations": {},
        "files": {
            "receipt_file": {
                "sql": "SELECT file_path FROM receipts WHERE id = :id",
                "params": {"id": {"type": "integer"}},
                "root": "receipts",
            }
        },
    }
    dist = tmp_path / "dist"
    dist.mkdir()
    (dist / "index.html").write_text("<!doctype html><title>x</title>")
    norm = store.validate_definitions("zhkh", definitions)
    rev = store.publish("zhkh", B.build_bundle(dist, contract_hash=store.contract_hash(norm)), definitions)
    app = FastAPI()
    mount(app, store)
    return TestClient(app), store, rev, folder, tmp_path


def fetch(client, rev, receipt_id, name="receipt_file", **extra):
    body = {"revision": rev, "args": {"id": receipt_id}, **extra}
    return client.post(f"{BASE}/apps/zhkh/downloads/{name}", json=body)


def test_a_receipt_downloads_as_the_file_the_row_points_to(receipts):
    c, _store, rev, folder, _tmp = receipts
    r = fetch(c, rev, 1)
    assert r.status_code == 200 and r.content == PDF
    assert r.headers["content-type"] == "application/pdf"
    assert r.headers["content-disposition"].startswith("attachment") and "gas.pdf" in r.headers["content-disposition"]
    assert unquote(r.headers["x-file-name"]) == "gas.pdf"
    assert r.headers["cache-control"] == "private, no-store"
    picture = fetch(c, rev, 9)
    assert picture.status_code == 200 and picture.headers["content-type"] == "image/png"
    assert (folder / "2026-09" / "gas.pdf").read_bytes() == PDF  # read-only: untouched


def test_a_relative_value_and_an_absolute_value_under_the_folder_both_work(receipts):
    c, store, rev, folder, _tmp = receipts
    assert fetch(c, rev, 8).content == PDF  # relative to the folder
    path, name, mime, size = store.files.resolve("zhkh", "receipts", str(folder / "2026-09" / "gas.pdf"))
    assert (name, mime, size) == ("gas.pdf", "application/pdf", len(PDF))


@pytest.mark.parametrize(
    "receipt_id, status, fragment",
    [
        (2, 404, "no file for these arguments"),            # the row holds NULL
        (99, 404, "no file for these arguments"),           # no such row
        (3, 400, "outside"),                                # .. leaves the folder
        (4, 404, "does not exist"),
        (5, 400, "outside"),                                # an absolute path elsewhere
        (6, 400, "not accepted"),                           # a program, not a document
        (7, 400, "not a file"),                             # a folder
        (10, 413, "larger"),
    ],
)
def test_what_may_not_leave_is_refused_with_a_reason(receipts, monkeypatch, receipt_id, status, fragment):
    c, _store, rev, _folder, _tmp = receipts
    monkeypatch.setattr(F, "MAX_LINKED_BYTES", 60)
    r = fetch(c, rev, receipt_id)
    assert r.status_code == status and fragment in r.json()["error"], r.text


def _link_out(link: Path, target: Path) -> bool:
    """A symbolic link (or, on Windows without the privilege, a directory junction) from inside the folder to a
    place outside it. False when this machine can make neither."""
    try:
        os.symlink(target, link, target_is_directory=target.is_dir())
        return True
    except (OSError, NotImplementedError):
        pass
    if os.name == "nt" and target.is_dir():
        done = subprocess.run(["cmd", "/c", "mklink", "/J", str(link), str(target)], capture_output=True)
        return done.returncode == 0
    return False


def _forbid_reading(monkeypatch, name):
    """Make opening the file called `name` fail the way a file with mode 600 does for the service user."""
    import builtins

    real = builtins.open

    def guarded(file, *args, **kwargs):
        if Path(str(file)).name == name:
            raise PermissionError(errno.EACCES, "Permission denied")
        return real(file, *args, **kwargs)

    monkeypatch.setattr(F, "open", guarded, raising=False)


def test_a_file_the_service_may_not_read_is_refused_with_a_reason_not_by_cutting_the_connection(receipts, monkeypatch):
    c, store, rev, _folder, _tmp = receipts
    _forbid_reading(monkeypatch, "gas.pdf")
    r = fetch(c, rev, 1)
    assert r.status_code == 400, r.status_code
    assert "not allowed to read" in r.json()["error"] and "gas.pdf" not in r.json()["error"]
    # the other receipts of the same folder are unaffected
    assert fetch(c, rev, 9).status_code == 200
    with pytest.raises(StoreError, match="not allowed to read"):
        store.files.import_from_root("zhkh", "receipts", "2026-09/gas.pdf")
    assert store.files.list_files("zhkh") == []


JPEG = b"\xff\xd8\xff\xe0\x00\x10JFIF" + b"\x00" * 64


def test_a_photo_saved_as_a_pdf_is_offered_as_the_photo_it_is(receipts):
    """The receipts skill saves photos of paper receipts under names ending in .pdf; as a PDF they cannot be opened."""
    c, store, rev, folder, tmp_path = receipts
    (folder / "2026-09" / "scan.pdf").write_bytes(JPEG)
    (folder / "2026-09" / "shot.jpg").write_bytes(PNG)           # the other way round, too
    (folder / "2026-09" / "noext_kept.txt").write_bytes(b"plain text")
    conn = sqlite3.connect(tmp_path / "foreign" / "zhkh.db")
    conn.execute("UPDATE receipts SET file_path = '/root/.hermes/zhkh/receipts/../scan' WHERE id = 99")  # no such row: harmless
    conn.execute("UPDATE receipts SET file_path = '/root/.hermes/zhkh/2026-09/scan.pdf' WHERE id = 2")
    conn.execute("UPDATE receipts SET file_path = '/root/.hermes/zhkh/2026-09/shot.jpg' WHERE id = 8")
    conn.commit()
    conn.close()
    scan = fetch(c, rev, 2)
    assert scan.status_code == 200 and scan.content == JPEG
    assert scan.headers["content-type"] == "image/jpeg"
    assert unquote(scan.headers["x-file-name"]) == "scan.jpg" and "scan.jpg" in scan.headers["content-disposition"]
    shot = fetch(c, rev, 8)
    assert shot.headers["content-type"] == "image/png" and unquote(shot.headers["x-file-name"]) == "shot.png"
    assert fetch(c, rev, 1).headers["content-type"] == "application/pdf"  # a real PDF is left alone
    assert unquote(fetch(c, rev, 1).headers["x-file-name"]) == "gas.pdf"
    # the author's import keeps the corrected name and type, so the file shows as a picture in the app
    imported = store.files.import_from_root("zhkh", "receipts", "2026-09/scan.pdf")
    assert (imported["name"], imported["mime"]) == ("scan.jpg", "image/jpeg")


@pytest.mark.parametrize(
    "head, expected",
    [
        (b"%PDF-1.7", ("application/pdf", "pdf")), (b"\xff\xd8\xff\xdb", ("image/jpeg", "jpg")),
        (b"\x89PNG\r\n\x1a\n", ("image/png", "png")), (b"GIF89a", ("image/gif", "gif")), (b"GIF87a", ("image/gif", "gif")),
        (b"RIFF\x10\x00\x00\x00WEBPVP8 ", ("image/webp", "webp")),
        (b"RIFF\x10\x00\x00\x00WAVEfmt ", None), (b"PK\x03\x04", None), (b"", None), (b"%PD", None),
    ],
)
def test_the_type_is_read_from_the_first_bytes(head, expected):
    assert F.sniff_type(head) == expected


def test_a_name_without_a_dot_or_with_the_right_extension_is_not_renamed():
    assert F.corrected("scan.jpeg", "image/jpeg", JPEG) == ("scan.jpeg", "image/jpeg")
    assert F.corrected("a.PDF", "application/pdf", PDF) == ("a.PDF", "application/pdf")
    assert F.corrected("report.pdf", "application/pdf", JPEG) == ("report.jpg", "image/jpeg")
    assert F.corrected("report.v2.pdf", "application/pdf", JPEG) == ("report.v2.jpg", "image/jpeg")
    assert F.corrected("data.csv", "text/csv", b"a,b\n1,2\n") == ("data.csv", "text/csv")  # unknown bytes: the name decides


def _fake_modes(monkeypatch, modes):
    monkeypatch.setattr(
        F, "_mode", lambda path: modes.get(Path(str(path)).name, 0o040755 if os.path.isdir(path) else 0o100644)
    )


def test_files_the_service_cannot_read_are_found_by_the_others_bits(tmp_path, monkeypatch):
    root = tmp_path / "skill"
    (root / "2026-09").mkdir(parents=True)
    (root / "private").mkdir()
    for name in ("2026-09/a.pdf", "2026-09/strict.pdf", "2026-09/also.jpg", "2026-09/notes.exe", "private/in_private.pdf"):
        (root / name).write_bytes(b"x")
    _fake_modes(monkeypatch, {
        "strict.pdf": 0o100600, "also.jpg": 0o100640, "notes.exe": 0o100600,   # an unserved type is not reported
        "private": 0o040700,                                                      # a folder others cannot enter
    })
    found = F.not_readable_by_service(root, check_modes=True)
    assert (found["files"], found["folders"], found["truncated"]) == (2, 1, False)
    assert sorted(found["examples"]) == ["2026-09/also.jpg", "2026-09/strict.pdf", "private/"]
    _fake_modes(monkeypatch, {})
    assert F.not_readable_by_service(root, check_modes=True)["files"] == 0
    assert F.not_readable_by_service(root, check_modes=False) == {
        "files": 0, "folders": 0, "examples": [], "truncated": False, "checked": False}


def test_a_large_folder_is_not_walked_forever(tmp_path, monkeypatch):
    for i in range(12):
        (tmp_path / f"f{i}.pdf").write_bytes(b"x")
    _fake_modes(monkeypatch, {f"f{i}.pdf": 0o100600 for i in range(12)})
    found = F.not_readable_by_service(tmp_path, check_modes=True, limit=5)
    assert found["truncated"] is True and found["files"] == 5


def test_the_administrator_is_told_how_to_fix_it_when_linking_and_listing(receipts, monkeypatch, capsys):
    import ms_admin

    c, store, rev, folder, tmp_path = receipts
    (folder / "2026-09" / "strict.pdf").write_bytes(b"x")
    _fake_modes(monkeypatch, {"strict.pdf": 0o100600})
    monkeypatch.setattr(F, "CHECK_MODES", True)
    code = ms_admin.main(["--home", str(store.root.parent), "link-files", "zhkh", "second", str(folder)])
    out = capsys.readouterr().out
    assert code == 0
    assert "warning: folder 'second': 1 file(s) the service is not allowed to read" in out and "2026-09/strict.pdf" in out
    assert "chmod a+r" in out and "umask 022" in out
    ms_admin.main(["--home", str(store.root.parent), "files", "zhkh"])
    err = capsys.readouterr().err
    assert "folder 'receipts'" in err and "folder 'second'" in err and "chmod a+r" in err


def test_the_author_sees_the_warning_in_file_list(receipts, monkeypatch):
    _c, store, _rev, folder, _tmp = receipts
    (folder / "2026-09" / "strict.pdf").write_bytes(b"x")
    _fake_modes(monkeypatch, {"strict.pdf": 0o100600})
    monkeypatch.setattr(F, "CHECK_MODES", True)
    listed = call(create_mcp(store), "file_list", {"app_id": "zhkh"})[1]
    assert listed["roots"] == ["receipts"] and len(listed["warnings"]) == 1
    warning = listed["warnings"][0]
    assert "1 file(s) the service is not allowed to read" in warning and "chmod a+r" in warning
    assert "strict.pdf" not in warning and str(folder) not in warning  # no host path or file name goes to the model

def test_a_link_pointing_out_of_the_folder_is_refused(receipts):
    c, store, rev, folder, tmp_path = receipts
    if not _link_out(folder / "escape", tmp_path / "secret"):
        pytest.skip("this machine can make neither symbolic links nor junctions")
    conn = sqlite3.connect(tmp_path / "foreign" / "zhkh.db")
    conn.execute("UPDATE receipts SET file_path = '/root/.hermes/zhkh/escape/passwd.pdf' WHERE id = 2")
    conn.commit()
    conn.close()
    r = fetch(c, rev, 2)
    assert r.status_code == 400 and "outside" in r.json()["error"], r.text
    with pytest.raises(StoreError, match="outside"):
        store.files.import_from_root("zhkh", "receipts", "escape/passwd.pdf")
    assert store.files.list_files("zhkh") == []


def test_the_page_cannot_choose_the_path_or_the_query(receipts):
    c, _store, rev, _folder, _tmp = receipts
    assert fetch(c, rev, 1, name="no_such_locator").status_code == 400
    extra = c.post(f"{BASE}/apps/zhkh/downloads/receipt_file", json={"revision": rev, "args": {"id": 1, "path": "/etc/passwd"}})
    assert extra.status_code == 400 and "unknown arguments" in extra.json()["error"]
    missing = c.post(f"{BASE}/apps/zhkh/downloads/receipt_file", json={"revision": rev, "args": {}})
    assert missing.status_code == 400
    wrong_type = c.post(f"{BASE}/apps/zhkh/downloads/receipt_file", json={"revision": rev, "args": {"id": "1 OR 1=1"}})
    assert wrong_type.status_code == 400
    # a locator is not a way to reach the stored files, nor the other way round
    assert c.post(f"{BASE}/apps/zhkh/downloads/f_0123456789abcdef", json={"revision": rev}).status_code == 400


def test_an_old_revision_is_refused_like_a_stale_query(receipts):
    c, _store, rev, _folder, _tmp = receipts
    r = fetch(c, rev - 1, 1)
    assert r.status_code == 409 and "stale" in r.json()["error"]


def test_an_unpublished_app_serves_no_files(receipts):
    c, store, _rev, _folder, _tmp = receipts
    store.create_app("draft_app", "Draft")
    assert c.post(f"{BASE}/apps/draft_app/downloads/receipt_file", json={"revision": 0}).status_code == 404


def test_locators_are_checked_when_the_app_is_published(receipts):
    _c, store, _rev, _folder, _tmp = receipts

    def defs(**locator):
        base = {"sql": "SELECT file_path FROM receipts WHERE id = :id", "params": {"id": {"type": "integer"}}, "root": "receipts"}
        return {"queries": {}, "mutations": {}, "files": {"receipt_file": {**base, **locator}}}

    store.validate_definitions("zhkh", defs())
    with pytest.raises(StoreError, match="no linked folder named 'invoices'"):
        store.validate_definitions("zhkh", defs(root="invoices"))
    with pytest.raises(StoreError, match="exactly one column"):
        store.validate_definitions("zhkh", defs(sql="SELECT file_path, period FROM receipts WHERE id = :id"))
    with pytest.raises(StoreError, match="declared but not used"):
        store.validate_definitions("zhkh", defs(sql="SELECT file_path FROM receipts WHERE id = 1"))
    with pytest.raises(StoreError, match="expected an object"):
        store.validate_definitions("zhkh", defs(command="rm -rf /"))
    with pytest.raises(StoreError, match="bad operation name"):
        store.validate_definitions("zhkh", {"queries": {}, "mutations": {}, "files": {"Bad-Name": defs()["files"]["receipt_file"]}})
    with pytest.raises(StoreError):  # a statement that is not a SELECT cannot be a locator
        store.validate_definitions("zhkh", defs(sql="DELETE FROM receipts WHERE id = :id"))


def test_the_contract_of_an_app_without_files_is_what_it_always_was(seeded):
    store, _built, _rev = seeded
    from conftest import DEFINITIONS

    norm = store.validate_definitions("utilities", DEFINITIONS)
    assert "files" not in norm
    old = "sha256:" + hashlib.sha256(
        json.dumps({"queries": norm["queries"], "mutations": norm["mutations"]}, sort_keys=True).encode()
    ).hexdigest()
    assert store.contract_hash(norm) == old
    assert "files" not in store.get_manifest("utilities")


def test_locators_change_the_contract_and_show_in_the_manifest_without_their_sql(receipts):
    _c, store, _rev, _folder, _tmp = receipts
    manifest = store.get_manifest("zhkh")
    assert manifest["files"] == {"receipt_file": {"params": {"id": {"type": "integer"}}}}
    assert "file_path" not in json.dumps(manifest) and "receipts" not in json.dumps(manifest["files"])
    norm = store.validate_definitions("zhkh", json.loads(json.dumps({
        "queries": {"receipts": {"sql": "SELECT id, period FROM receipts ORDER BY id", "shape": "rows"}},
        "mutations": {},
    })))
    with_files = {**norm, "files": {"receipt_file": {"sql": "SELECT 1", "params": {}, "root": "receipts"}}}
    assert store.contract_hash(with_files) != store.contract_hash(norm)


def test_link_root_checks_what_it_is_given(receipts, tmp_path):
    _c, store, _rev, folder, _tmp = receipts
    ok = tmp_path / "other_folder"
    ok.mkdir()
    for args, message in [
        (("zhkh", "receipts", ok), "already has"),                      # the name is taken
        (("zhkh", "Bad-Name", ok), "root name"),
        (("zhkh", "second", Path("relative/dir")), "absolute"),
        (("zhkh", "second", tmp_path / "missing"), "does not exist"),
        (("zhkh", "second", folder / "2026-09" / "gas.pdf"), "not a folder"),
        (("zhkh", "second", store.root), "storage"),
        (("zhkh", "second", store.root / "apps"), "storage"),
        (("zhkh", "second", tmp_path), "storage"),                     # a folder that contains the service's own storage
    ]:
        with pytest.raises((StoreError, Conflict), match=message):
            store.files.link_root(*args)
    with pytest.raises(StoreError, match="prefix"):
        store.files.link_root("zhkh", "second", ok, strip_prefix="relative")
    with pytest.raises(StoreError, match="prefix"):
        store.files.link_root("zhkh", "second", ok, strip_prefix="/a/../b")
    with pytest.raises(NotFound):
        store.files.link_root("nope_app", "second", ok)
    store.files.link_root("zhkh", "second", ok)
    assert store.files.root_names("zhkh") == {"receipts", "second"}
    store.files.unlink_root("zhkh", "second")
    with pytest.raises(NotFound):
        store.files.unlink_root("zhkh", "second")


# ---------------------------------------------------------------------------------------------- the author's tools


def call(mcp, name, args):
    return asyncio.run(mcp.call_tool(name, args))


def test_the_author_imports_a_file_from_a_linked_folder(receipts):
    _c, store, _rev, folder, _tmp = receipts
    mcp = create_mcp(store)
    listed = call(mcp, "file_list", {"app_id": "zhkh"})[1]
    assert listed == {"files": [], "roots": ["receipts"]}

    imported = call(mcp, "file_import", {"app_id": "zhkh", "root": "receipts", "path": "2026-09/photo.png"})[1]
    assert imported["source"] == "import" and imported["mime"] == "image/png" and imported["duplicate"] is False
    again = call(mcp, "file_import", {"app_id": "zhkh", "root": "receipts", "path": "2026-09/photo.png"})[1]
    assert again["fileId"] == imported["fileId"] and again["duplicate"] is True

    for bad_root, path in [("nope", "2026-09/photo.png"), ("receipts", "../secret/passwd.pdf"), ("receipts", "notes.exe")]:
        with pytest.raises(Exception, match="folder|outside|not accepted"):
            call(mcp, "file_import", {"app_id": "zhkh", "root": bad_root, "path": path})
    assert [f["fileId"] for f in store.files.list_files("zhkh")] == [imported["fileId"]]
    assert (folder / "2026-09" / "photo.png").read_bytes() == PNG  # the original stays where it was


def test_an_import_that_does_not_fit_leaves_nothing_behind(receipts, monkeypatch):
    _c, store, _rev, _folder, _tmp = receipts
    monkeypatch.setattr(F, "MAX_APP_FILES", 0)
    with pytest.raises(StoreError, match="delete some"):
        store.files.import_from_root("zhkh", "receipts", "2026-09/gas.pdf")
    assert store.files.list_files("zhkh") == [] and leftovers(store, "zhkh") == []


def test_the_author_reads_text_and_looks_at_pictures(client):
    c, store, _built, _rev = client
    mcp = create_mcp(store)
    note = upload(c, "utilities", "note.txt", "Показания: 123".encode()).json()["fileId"]
    pdf = upload(c, "utilities", "a.pdf", PDF).json()["fileId"]
    picture = upload(c, "utilities", "p.png", PNG).json()["fileId"]

    assert call(mcp, "file_read", {"app_id": "utilities", "file_id": note})[1]["text"] == "Показания: 123"
    assert "text" not in call(mcp, "file_read", {"app_id": "utilities", "file_id": pdf})[1]

    content = call(mcp, "file_view", {"app_id": "utilities", "file_id": picture})
    image = content[0] if isinstance(content, (list, tuple)) and not isinstance(content[0], dict) else content
    assert any(getattr(item, "type", "") == "image" for item in (image if isinstance(image, list) else [image]))
    with pytest.raises(Exception, match="not a picture"):
        call(mcp, "file_view", {"app_id": "utilities", "file_id": pdf})
    store.create_app("other_app", "Other")
    with pytest.raises(Exception, match="unknown file"):
        call(mcp, "file_read", {"app_id": "other_app", "file_id": note})  # a file of another app is not there


def test_the_author_can_find_a_file_on_the_host_but_only_its_own_apps(client):
    c, store, _built, _rev = client
    mcp = create_mcp(store)
    fid = upload(c, "utilities", "Квитанция март.pdf", PDF).json()["fileId"]
    out = call(mcp, "file_path", {"app_id": "utilities", "file_id": fid})[1]
    assert out["name"] == "Квитанция март.pdf" and out["mime"] == "application/pdf" and out["size"] == len(PDF)
    assert Path(out["path"]).read_bytes() == PDF
    assert Path(out["path"]).is_relative_to(store.root / "apps" / "utilities" / "files")
    store.create_app("other_app", "Other")
    with pytest.raises(Exception, match="unknown file"):
        call(mcp, "file_path", {"app_id": "other_app", "file_id": fid})
    with pytest.raises(Exception, match="unknown file"):
        call(mcp, "file_path", {"app_id": "utilities", "file_id": "../../registry.db"})


def test_the_author_deletes_a_file(client):
    c, store, _built, _rev = client
    mcp = create_mcp(store)
    fid = upload(c, "utilities", "a.pdf", PDF).json()["fileId"]
    assert call(mcp, "file_delete", {"app_id": "utilities", "file_id": fid})[1] == {"deleted": True, "fileId": fid}
    assert store.files.list_files("utilities") == []


# ---------------------------------------------------------------------------------------------- deleting an app


def test_deleting_and_restoring_an_app_keeps_its_files_and_folders(receipts):
    c, store, rev, folder, _tmp = receipts
    mine = upload(c, "zhkh", "a.pdf", PDF).json()["fileId"]
    name = store.delete_app("zhkh")
    conn = store._registry()
    try:
        assert conn.execute("SELECT COUNT(*) FROM app_files").fetchone()[0] == 0
        assert conn.execute("SELECT COUNT(*) FROM app_file_roots").fetchone()[0] == 0
    finally:
        conn.close()
    assert store.trash_restore(name) == "zhkh"
    assert [f["fileId"] for f in store.files.list_files("zhkh")] == [mine]
    assert store.files.get("zhkh", mine)[0].read_bytes() == PDF
    assert store.files.root_names("zhkh") == {"receipts"}
    assert fetch(c, rev, 1).content == PDF

# ---------------------------------------------------------------------------------------------- what the author is told


ROOT = Path(__file__).resolve().parents[2]


def test_what_the_author_is_told_about_files_exists_in_the_template_and_the_sdk():
    from mobile_surfaces.mcp_server import AUTHORING_REFERENCE

    components = (ROOT / "templates" / "starter-app" / "src" / "components.tsx").read_text(encoding="utf-8")
    sdk = "".join(p.read_text(encoding="utf-8") for p in (ROOT / "packages" / "mobile-sdk" / "src").glob("*.ts"))
    skill = (ROOT / "plugin" / "skills" / "surfaces-author" / "SKILL.md").read_text(encoding="utf-8")
    for name in ("FilePicker", "DownloadButton", "FileThumb"):
        assert name in AUTHORING_REFERENCE and f"export function {name}" in components, name
        assert name in skill, name
    for call in ("askHermes", "fileUrl", "useFiles"):
        assert call in AUTHORING_REFERENCE, call
    for call in ("askHermes", "fileUrl", "useFiles", "pickFile", "saveFile"):  # the kit is built on these
        assert call in sdk, call
    assert "link-files" in AUTHORING_REFERENCE and "link-files" in skill
    assert "file_import" in AUTHORING_REFERENCE and "file_import" in skill
    # the sizes the author is promised are the ones the server enforces
    assert f"{F.MAX_FILE_BYTES // (1024 * 1024)} MB" in AUTHORING_REFERENCE
    assert f"{F.MAX_LINKED_BYTES // (1024 * 1024)} MB" in AUTHORING_REFERENCE
