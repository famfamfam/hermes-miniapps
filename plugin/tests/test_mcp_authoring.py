"""The interface-authoring tools over real MCP (Streamable HTTP), the way Hermes calls them.

Needs the Node toolchain of templates/starter-app; skipped when it is not installed.
"""
import shutil
import socket
import threading
import time

import httpx
import pytest
import uvicorn
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

from devserver import build_app
from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.builder import Builder
from test_authoring import DEFS, SCREEN, SDK, TEMPLATE
from test_mcp import API, TOKEN, call, run, text

import json


@pytest.fixture
def server(tmp_path):
    builder = Builder(TEMPLATE, SDK, timeout_s=180)
    reason = builder.available()
    if reason or shutil.which("node") is None:
        pytest.skip(reason or "node is not installed")
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    app = build_app(tmp_path / "home", TOKEN, make_authoring=lambda store: Authoring(store, TEMPLATE, builder))
    srv = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=port, log_level="warning", lifespan="on"))
    thread = threading.Thread(target=srv.run, daemon=True)
    thread.start()
    deadline = time.time() + 10
    while not srv.started and time.time() < deadline:
        time.sleep(0.05)
    assert srv.started
    yield f"http://127.0.0.1:{port}"
    srv.should_exit = True
    thread.join(timeout=5)


def test_tools_are_listed_and_only_the_readers_are_marked_read_only(server):
    async def go():
        async with streamablehttp_client(f"{server}/mcp", headers={"Authorization": f"Bearer {TOKEN}"}) as (r, w, _):
            async with ClientSession(r, w) as s:
                await s.initialize()
                return await s.list_tools()

    import asyncio

    tools = {t.name: t for t in asyncio.run(go()).tools}
    assert set(tools) == {
        "reference", "app_list", "app_create", "data_read", "data_sql", "app_check_definitions",
        "app_source", "app_edit", "app_delete_file", "app_build", "app_publish", "app_reset_draft",
        "file_list", "file_read", "file_path", "file_view", "file_import", "file_delete",
    }
    # Only these skip Hermes's approval on an untrusted server; every other call asks. Importing or deleting a
    # file changes what the owner has, so those two ask.
    read_only = {n for n, t in tools.items() if t.annotations and t.annotations.readOnlyHint}
    assert read_only == {
        "reference", "app_list", "data_read", "app_check_definitions", "app_source", "file_list", "file_read",
        "file_path", "file_view",
    }
    assert "Building an interface" in text(run(call(server, "reference")))
    # The nudge toward delegating sits in the descriptions of the tools that start interface work.
    for name in ("app_create", "app_edit", "app_build", "app_publish"):
        assert "delegate_task" in (tools[name].description or ""), name
    assert "delegate_task" not in (tools["data_read"].description or "")


def test_data_read_looks_but_cannot_change_anything(server):
    run(call(server, "app_create", {"app_id": "peek", "title": "Peek"}))
    run(call(server, "data_sql", {"app_id": "peek", "mode": "schema", "sql": "CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)"}))
    run(call(server, "data_sql", {"app_id": "peek", "mode": "write", "sql": "INSERT INTO t(v) VALUES ('a')"}))
    ok = run(call(server, "data_read", {"app_id": "peek", "sql": "SELECT v FROM t"}))
    assert not ok.isError and ok.structuredContent["rows"] == [["a"]]
    for sql in ("DELETE FROM t", "DROP TABLE t", "INSERT INTO t(v) VALUES ('b')"):
        bad = run(call(server, "data_read", {"app_id": "peek", "sql": sql}))
        assert bad.isError, sql
    still = run(call(server, "data_read", {"app_id": "peek", "sql": "SELECT COUNT(*) FROM t"}))
    assert still.structuredContent["rows"] == [[1]]


def test_hermes_style_session_creates_builds_and_publishes_an_interface(server):
    run(call(server, "app_create", {"app_id": "items_app", "title": "Список"}))
    run(call(server, "data_sql", {"app_id": "items_app", "mode": "schema", "sql":
        "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, amount INTEGER NOT NULL)"}))
    run(call(server, "data_sql", {"app_id": "items_app", "mode": "write",
        "sql": "INSERT INTO items(title, amount) VALUES (?,?)", "rows": [["Вода", 119000], ["Газ", 79000]]}))

    listing = run(call(server, "app_source", {"app_id": "items_app"})).structuredContent
    assert {"src/App.tsx", "src/screens.tsx", "src/components.tsx", "definitions.json"} <= {
        f["path"] for f in listing["files"]
    }
    assert "src/main.tsx" not in {f["path"] for f in listing["files"]}

    # A first attempt with a type error: the tool call succeeds, the build reports file and line.
    bad = run(call(server, "app_edit", {"app_id": "items_app", "path": "src/screens.tsx",
                                         "content": SCREEN.replace("amount: number;", "amount: string;")}))
    assert not bad.isError
    # The body of definitions.json is a JSON *string* argument; it must arrive as text, not be decoded.
    defs = run(call(server, "app_edit", {"app_id": "items_app", "path": "definitions.json",
                                         "content": json.dumps(DEFS)}))
    assert not defs.isError, text(defs)
    assert json.loads(run(call(server, "app_source", {"app_id": "items_app", "path": "definitions.json"}))
                      .structuredContent["content"]) == DEFS
    failed = run(call(server, "app_build", {"app_id": "items_app"}))
    assert not failed.isError and failed.structuredContent["ok"] is False
    assert failed.structuredContent["stage"] == "types"
    first = failed.structuredContent["diagnostics"][0]
    assert first["file"] == "src/screens.tsx" and first["line"] > 0 and first["code"].startswith("TS")
    refused = run(call(server, "app_publish", {"app_id": "items_app"}))
    assert refused.isError and "no successful build" in text(refused)

    # The fix, then build and publish.
    run(call(server, "app_edit", {"app_id": "items_app", "path": "src/screens.tsx", "content": SCREEN}))
    built = run(call(server, "app_build", {"app_id": "items_app"})).structuredContent
    assert built["ok"] is True, json.dumps(built, ensure_ascii=False)
    assert built["queries"]["items"]["columns"] == ["id", "title", "amount"]
    published = run(call(server, "app_publish", {"app_id": "items_app"}))
    assert not published.isError and published.structuredContent["revision"] == 1

    auth = {"Authorization": f"Bearer {TOKEN}"}
    apps = httpx.get(f"{server}{API}/apps", headers=auth).json()["apps"]
    assert [a["appId"] for a in apps] == ["items_app"]
    data = httpx.post(f"{server}{API}/apps/items_app/data", headers=auth,
                      json={"revision": 1, "queries": [{"name": "items"}]}).json()
    assert [r["title"] for r in data["results"]["items"]["data"]] == ["Вода", "Газ"]


def test_publish_over_mcp_only_submits_once_a_phone_is_paired(server, tmp_path):
    import base64

    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    from mobile_surfaces_core.store import Store

    run(call(server, "app_create", {"app_id": "items_app", "title": "Список"}))
    run(call(server, "data_sql", {"app_id": "items_app", "mode": "schema", "sql":
        "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, amount INTEGER NOT NULL)"}))
    run(call(server, "data_sql", {"app_id": "items_app", "mode": "write",
        "sql": "INSERT INTO items(title, amount) VALUES (?,?)", "rows": [["Вода", 119000]]}))
    run(call(server, "app_edit", {"app_id": "items_app", "path": "src/screens.tsx", "content": SCREEN}))
    run(call(server, "app_edit", {"app_id": "items_app", "path": "definitions.json", "content": json.dumps(DEFS)}))
    assert run(call(server, "app_build", {"app_id": "items_app"})).structuredContent["ok"] is True

    key = Ed25519PrivateKey.generate()
    public = base64.b64encode(
        key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
    Store(tmp_path / "home").register_approver("phone1", public)

    out = run(call(server, "app_publish", {"app_id": "items_app"}))
    assert not out.isError and out.structuredContent["status"] == "awaiting_review"
    auth = {"Authorization": f"Bearer {TOKEN}"}
    assert httpx.get(f"{server}{API}/apps", headers=auth).json()["apps"] == []  # nothing replaced
    reviews = httpx.get(f"{server}{API}/previews", headers=auth).json()["previews"]
    assert [r["appId"] for r in reviews] == ["items_app"]

    # Only the phone's signature publishes: the same token and the author tools cannot.
    ch = httpx.post(f"{server}{API}/previews/items_app/challenge", headers=auth).json()
    forged = httpx.post(f"{server}{API}/previews/items_app/approve", headers=auth,
                        json={"buildId": ch["buildId"], "nonce": ch["nonce"], "signature": "AAAA"})
    assert forged.status_code == 422
    # A failed attempt burns the one-time challenge: the phone asks again and signs the new one.
    ch = httpx.post(f"{server}{API}/previews/items_app/challenge", headers=auth).json()
    signed = base64.b64encode(key.sign(ch["message"].encode())).decode()
    ok = httpx.post(f"{server}{API}/previews/items_app/approve", headers=auth,
                    json={"buildId": ch["buildId"], "nonce": ch["nonce"], "signature": signed})
    assert ok.status_code == 200 and ok.json()["revision"] == 1


def test_edit_outside_the_allow_list_is_a_tool_error_with_the_reason(server):
    run(call(server, "app_create", {"app_id": "guarded", "title": "G"}))
    for path in ("src/main.tsx", "package.json", "vite.config.ts"):
        r = run(call(server, "app_edit", {"app_id": "guarded", "path": path, "content": "x"}))
        assert r.isError and ("cannot be changed" in text(r) or "path must be" in text(r))


def test_long_text_cells_are_cut_for_the_author_but_schema_listings_are_not(server):
    run(call(server, "app_create", {"app_id": "docs", "title": "Docs"}))
    run(call(server, "data_sql", {"app_id": "docs", "mode": "schema", "sql":
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, body TEXT NOT NULL DEFAULT '', "
        "other_long_column_name TEXT, yet_another_long_column_name TEXT, and_one_more_for_the_listing TEXT)"}))
    run(call(server, "data_sql", {"app_id": "docs", "mode": "write",
                                  "sql": "INSERT INTO notes(body) VALUES (?)", "params": None, "rows": [["x" * 1000]]}))
    rows = run(call(server, "data_sql", {"app_id": "docs", "mode": "read", "sql": "SELECT body FROM notes"})).structuredContent
    assert rows["clippedCells"] == 1 and len(rows["rows"][0][0]) < 400 and "more characters" in rows["rows"][0][0]
    ddl = run(call(server, "data_sql", {"app_id": "docs", "mode": "read",
                                        "sql": "SELECT sql FROM sqlite_master WHERE name = 'notes'"})).structuredContent
    assert "clippedCells" not in ddl and "and_one_more_for_the_listing" in ddl["rows"][0][0]
