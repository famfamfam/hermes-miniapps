"""S0-4 (server half): an agent tool writes through MCP, the phone API reads the same store.

The server runs for real (uvicorn on a free port) and is driven by the official MCP client over
Streamable HTTP, i.e. the same wire protocol Hermes uses.
"""
import asyncio
import socket
import threading
import time

import httpx
import pytest
import uvicorn
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

from conftest import DEFINITIONS
from devserver import build_app
from mobile_surfaces_core import bundle as B

TOKEN = "test-token-123"
API = "/api/plugins/mobile-surfaces/v1"


@pytest.fixture
def server(tmp_path):
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    app = build_app(tmp_path / "home", TOKEN)
    cfg = uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning", lifespan="on")
    srv = uvicorn.Server(cfg)
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()
    deadline = time.time() + 10
    while not srv.started and time.time() < deadline:
        time.sleep(0.05)
    assert srv.started, "server did not start"
    yield f"http://127.0.0.1:{port}", tmp_path / "home"
    srv.should_exit = True
    thread.join(timeout=5)


def run(coro):
    return asyncio.run(coro)


async def call(base, name, args=None, token=TOKEN):
    async with streamablehttp_client(f"{base}/mcp", headers={"Authorization": f"Bearer {token}"}) as (r, w, _):
        async with ClientSession(r, w) as session:
            await session.initialize()
            return await session.call_tool(name, args or {})


def text(result):
    return "".join(c.text for c in result.content if getattr(c, "text", None))


def test_endpoint_requires_the_token(server):
    base, _ = server
    for headers in ({}, {"Authorization": "Bearer wrong"}, {"Authorization": "Basic abc"}):
        r = httpx.post(f"{base}/mcp", json={}, headers=headers)
        assert r.status_code == 401
    assert httpx.get(f"{base}{API}/health").status_code == 401  # the phone API is guarded too


def test_lists_the_author_tools_with_schemas(server):
    base, _ = server

    async def go():
        async with streamablehttp_client(f"{base}/mcp", headers={"Authorization": f"Bearer {TOKEN}"}) as (r, w, _):
            async with ClientSession(r, w) as s:
                init = await s.initialize()
                return init, await s.list_tools()

    init, tools = run(go())
    names = {t.name for t in tools.tools}
    assert names == {
        "reference", "app_list", "app_create", "data_read", "data_sql", "app_check_definitions",
        "file_list", "file_read", "file_path", "file_view", "file_import", "file_delete",
    }
    sql = next(t for t in tools.tools if t.name == "data_sql")
    assert set(sql.inputSchema["required"]) == {"app_id", "mode", "sql"}
    assert sql.inputSchema["properties"]["mode"]["enum"] == ["read", "write", "schema"]
    assert "own database" in (sql.description or "")
    assert "kopecks" in text(run(call(base, "reference")))


def test_tool_writes_and_phone_route_reads_the_same_store(server, tmp_path):
    base, home = server
    run(call(base, "app_create", {"app_id": "utilities", "title": "Коммуналка", "brief": "Квитанции ЖКХ"}))
    run(call(base, "data_sql", {"app_id": "utilities", "mode": "schema", "sql":
        "CREATE TABLE bills (id INTEGER PRIMARY KEY, supplier TEXT NOT NULL, period TEXT NOT NULL, "
        "amount INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'unpaid', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"}))
    wrote = run(call(base, "data_sql", {"app_id": "utilities", "mode": "write", "sql":
        "INSERT INTO bills(supplier, period, amount) VALUES (?,?,?)",
        "rows": [["Вода", "2026-10-01", 119000], ["Газ", "2026-10-05", 79000]]}))
    assert not wrote.isError and wrote.structuredContent["rowcount"] >= 1

    # Publish through the same store the server uses, then read from the phone route.
    from mobile_surfaces_core.store import Store
    store = Store(home)
    dist = tmp_path / "dist"
    dist.mkdir()
    (dist / "index.html").write_text("x")
    norm = store.validate_definitions("utilities", DEFINITIONS)
    rev = store.publish("utilities", B.build_bundle(dist, contract_hash=store.contract_hash(norm)), DEFINITIONS)

    auth = {"Authorization": f"Bearer {TOKEN}"}
    q = {"revision": rev, "queries": [{"name": "bills"}, {"name": "month_total"}]}
    out = httpx.post(f"{base}{API}/apps/utilities/data", json=q, headers=auth).json()
    assert [b["supplier"] for b in out["results"]["bills"]["data"]] == ["Газ", "Вода"]

    # A later write by the agent is visible to the next phone query, and announced as an event.
    start = httpx.get(f"{base}{API}/events", headers=auth).json()
    run(call(base, "data_sql", {"app_id": "utilities", "mode": "write", "sql":
        "UPDATE bills SET status = 'paid' WHERE supplier = :s", "params": {"s": "Вода"}}))
    after = httpx.post(f"{base}{API}/apps/utilities/data", json=q, headers=auth).json()
    assert after["dataRev"] > out["dataRev"]
    ev = httpx.get(f"{base}{API}/events", params={"since": start["seq"], "epoch": start["epoch"]}, headers=auth).json()
    assert [e["type"] for e in ev["events"]] == ["data.changed"]


def test_sql_errors_come_back_as_tool_errors_with_the_message(server):
    base, _ = server
    run(call(base, "app_create", {"app_id": "errs", "title": "Errs"}))
    bad = run(call(base, "data_sql", {"app_id": "errs", "mode": "read", "sql": "SELECT * FROM nope"}))
    assert bad.isError and "no such table" in text(bad)
    reserved = run(call(base, "data_sql", {"app_id": "errs", "mode": "read", "sql": "SELECT * FROM _ms_meta"}))
    assert reserved.isError
    pragma = run(call(base, "data_sql", {"app_id": "errs", "mode": "read", "sql": "PRAGMA table_info(x)"}))
    assert pragma.isError
    unknown = run(call(base, "data_sql", {"app_id": "ghost", "mode": "read", "sql": "SELECT 1"}))
    assert unknown.isError and "unknown app" in text(unknown)


def test_invalid_arguments_are_refused_before_the_store(server):
    base, _ = server
    wrong_mode = run(call(base, "data_sql", {"app_id": "x", "mode": "drop", "sql": "SELECT 1"}))
    assert wrong_mode.isError
    bad_id = run(call(base, "app_create", {"app_id": "../etc", "title": "T"}))
    assert bad_id.isError and "appId" in text(bad_id)


def test_definitions_check_reports_columns_and_destructive_flags(server):
    base, _ = server
    run(call(base, "app_create", {"app_id": "defs", "title": "Defs"}))
    run(call(base, "data_sql", {"app_id": "defs", "mode": "schema", "sql": "CREATE TABLE t (id INTEGER PRIMARY KEY, x TEXT)"}))
    ok = run(call(base, "app_check_definitions", {"app_id": "defs", "definitions": {
        "queries": {"all_t": {"sql": "SELECT id, x FROM t", "shape": "rows"}},
        "mutations": {"wipe": {"sql": "DELETE FROM t WHERE id = :id", "params": {"id": {"type": "integer"}}}},
    }}))
    assert not ok.isError
    data = ok.structuredContent
    assert data["queries"]["all_t"]["columns"] == ["id", "x"]
    assert data["mutations"]["wipe"]["destructive"] is True
    bad = run(call(base, "app_check_definitions", {"app_id": "defs", "definitions": {
        "queries": {"broken": {"sql": "SELECT nope FROM t", "shape": "rows"}}}}))
    assert bad.isError and "nope" in text(bad)


def test_app_list_includes_unpublished_apps(server):
    base, _ = server
    run(call(base, "app_create", {"app_id": "draft1", "title": "Draft"}))
    listed = run(call(base, "app_list"))
    apps = listed.structuredContent["result"]
    assert any(a["appId"] == "draft1" and a["published"] is False for a in apps)
    # ...while the phone's list never shows it
    auth = {"Authorization": f"Bearer {TOKEN}"}
    assert httpx.get(f"{base}{API}/apps", headers=auth).json()["apps"] == []


def test_linked_app_is_listed_readable_and_refuses_writes_over_mcp(server, tmp_path):
    import sqlite3

    from mobile_surfaces_core.store import Store

    base, home = server
    foreign = tmp_path / "foreign.db"
    conn = sqlite3.connect(foreign)
    conn.execute("CREATE TABLE t (id INTEGER PRIMARY KEY, v REAL)")
    conn.execute("INSERT INTO t(v) VALUES (1.5)")
    conn.commit()
    conn.close()
    Store(home).link_source("ext", "External", foreign)

    listed = run(call(base, "app_list")).structuredContent["result"]
    assert any(a["appId"] == "ext" and a["linked"] is True for a in listed)
    ok = run(call(base, "data_sql", {"app_id": "ext", "mode": "read", "sql": "SELECT v FROM t"}))
    assert not ok.isError and ok.structuredContent["rows"] == [[1.5]]
    for mode, sql in (("write", "UPDATE t SET v = 0"), ("schema", "DROP TABLE t")):
        bad = run(call(base, "data_sql", {"app_id": "ext", "mode": mode, "sql": sql}))
        assert bad.isError and "read-only" in text(bad)
    assert sqlite3.connect(foreign).execute("SELECT v FROM t").fetchone() == (1.5,)


def test_phone_api_and_mcp_run_as_separate_apps_with_separate_tokens(tmp_path):
    """main() serves them on different listeners: the phone API may be public, MCP must not be."""
    from fastapi.testclient import TestClient

    home = tmp_path / "split"
    phone = build_app(home, "phone-tok", serve_mcp=False)
    mcp_only = build_app(home, "phone-tok", serve_api=False, mcp_token="mcp-tok")
    local = {"Host": "127.0.0.1:8788"}
    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "t", "version": "0"}}}
    mcp_headers = {"Accept": "application/json, text/event-stream", **local}

    with TestClient(phone) as c:
        ok = c.get(f"{API}/health", headers={"Authorization": "Bearer phone-tok"})
        assert ok.status_code == 200
        # the write tools are simply not there
        assert c.post("/mcp", json=init, headers={"Authorization": "Bearer phone-tok", **mcp_headers}).status_code == 404

    with TestClient(mcp_only) as c:
        assert c.get(f"{API}/health", headers={"Authorization": "Bearer phone-tok"}).status_code == 404
        # the phone's token does not open the author tools, the MCP token does
        bad = c.post("/mcp", json=init, headers={"Authorization": "Bearer phone-tok", **mcp_headers})
        assert bad.status_code == 401
        good = c.post("/mcp", json=init, headers={"Authorization": "Bearer mcp-tok", **mcp_headers})
        assert good.status_code == 200 and good.json()["result"]["serverInfo"]["name"] == "mobile-surfaces"


def test_token_files_are_separate_per_purpose(tmp_path, monkeypatch):
    from devserver import load_token

    monkeypatch.delenv("MS_DEV_TOKEN", raising=False)
    monkeypatch.delenv("MS_MCP_TOKEN", raising=False)
    phone, mcp = load_token(tmp_path), load_token(tmp_path, "mcp-token")
    assert phone != mcp and len(phone) >= 24 and len(mcp) >= 24
    assert load_token(tmp_path) == phone and load_token(tmp_path, "mcp-token") == mcp  # stable
    monkeypatch.setenv("MS_MCP_TOKEN", "from-env")
    assert load_token(tmp_path, "mcp-token") == "from-env" and load_token(tmp_path) == phone


def test_foreign_host_header_is_refused(server):
    base, _ = server
    r = httpx.post(f"{base}/mcp", json={}, headers={"Authorization": f"Bearer {TOKEN}", "Host": "evil.example"})
    assert r.status_code in (400, 403, 421)
