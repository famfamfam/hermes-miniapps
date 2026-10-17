import io
import zipfile

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient

from mobile_surfaces.api import mount
from mobile_surfaces_core import bundle as B
from mobile_surfaces_core.store import Store

BASE = "/api/plugins/mobile-surfaces/v1"

DEFINITIONS = {
    "queries": {
        "bills": {
            "sql": "SELECT id, supplier, period, amount, status FROM bills "
                   "WHERE (:status IS NULL OR status = :status) ORDER BY period DESC",
            "params": {"status": {"type": "enum", "values": ["paid", "unpaid"], "nullable": True}},
            "shape": "rows",
            "maxRows": 200,
        },
        "month_total": {
            "sql": "SELECT COALESCE(SUM(amount), 0) AS total FROM bills WHERE substr(period, 1, 7) = substr(:today, 1, 7)",
            "shape": "value",
        },
    },
    "mutations": {
        "mark_paid": {
            "sql": "UPDATE bills SET status = 'paid' WHERE id = :id",
            "params": {"id": {"type": "integer"}},
        },
        "delete_bill": {
            "sql": "DELETE FROM bills WHERE id = :id",
            "params": {"id": {"type": "integer"}},
        },
    },
}


@pytest.fixture
def damage_bundle_member():
    """Damage one member's payload, keeping the ZIP central directory valid and unchanged."""
    def damage(data, member, kind):
        compression = {
            "crc": zipfile.ZIP_STORED, "deflate": zipfile.ZIP_DEFLATED,
            "lzma": zipfile.ZIP_LZMA, "bzip2": zipfile.ZIP_BZIP2,
        }[kind]
        buf = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(data)) as original, zipfile.ZipFile(buf, "w", compression) as rebuilt:
            for info in original.infolist():
                rebuilt.writestr(info.filename, original.read(info.filename))
        clean = buf.getvalue()
        with zipfile.ZipFile(io.BytesIO(clean)) as archive:
            info = archive.getinfo(member)
            central_offset = archive.start_dir
        header = info.header_offset
        name_size = int.from_bytes(clean[header + 26:header + 28], "little")
        extra_size = int.from_bytes(clean[header + 28:header + 30], "little")
        payload = header + 30 + name_size + extra_size
        damaged = bytearray(clean)
        if kind == "crc":
            damaged[payload] ^= 0xFF
        elif kind == "deflate":
            # Deflate BTYPE=3 is reserved, so decompression itself raises zlib.error.
            damaged[payload] = (damaged[payload] & ~0x06) | 0x06
        elif kind == "lzma":
            # ZIP LZMA has a four-byte header followed by filter properties. An invalid first
            # property byte raises lzma.LZMAError before decompression can finish or CRC is checked.
            damaged[payload + 4] = 0xFF
        else:
            # Break the BZh magic to force BZ2Decompressor's OSError, not a later CRC mismatch.
            assert clean[payload:payload + 3] == b"BZh"
            damaged[payload] ^= 0xFF
        assert damaged[central_offset:] == clean[central_offset:]
        return bytes(damaged)

    return damage


@pytest.fixture
def review_decision_snapshot():
    """Capture review/draft metadata and registry events without pumping synthetic data outboxes."""
    def snapshot(auth, app_id="items_app"):
        draft = auth._draft(app_id)
        conn = auth.store._registry()
        try:
            events = [tuple(row) for row in conn.execute("SELECT * FROM events ORDER BY seq")]
        finally:
            conn.close()
        return {
            "files": {
                name: (draft / name).read_bytes() if (draft / name).is_file() else None
                for name in ("draft.json", "build.json", "review.json", "review-bundle.zip")
            },
            "revision": auth.store._row(app_id)["revision"], "events": events,
        }

    return snapshot


@pytest.fixture
def store(tmp_path):
    return Store(tmp_path / "home")


@pytest.fixture
def seeded(store, tmp_path):
    """An app with schema, rows and a published bundle."""
    store.create_app("utilities", "Коммуналка", icon="receipt")
    store.agent_sql("utilities", "schema",
        "CREATE TABLE bills (id INTEGER PRIMARY KEY, supplier TEXT NOT NULL, period TEXT NOT NULL, "
        "amount INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'unpaid')")
    store.agent_sql("utilities", "write",
        "INSERT INTO bills(supplier, period, amount, status) VALUES (?,?,?,?)",
        params_list=[("Water", "2026-09-01", 120000, "paid"),
                     ("Power", "2026-10-01", 450000, "unpaid"),
                     ("Gas", "2026-10-05", 90000, "unpaid")])
    dist = tmp_path / "dist"
    dist.mkdir()
    (dist / "index.html").write_text("<!doctype html><title>x</title>")
    norm = store.validate_definitions("utilities", DEFINITIONS)
    built = B.build_bundle(dist, contract_hash=store.contract_hash(norm))
    rev = store.publish("utilities", built, DEFINITIONS)
    return store, built, rev


@pytest.fixture
def client(seeded):
    store, built, rev = seeded
    app = FastAPI()
    mount(app, store)
    return TestClient(app), store, built, rev
