"""Authoring: lint, isolated build, drafts, publish (ADR-007).

The lint tests are pure. The build tests run the real Node toolchain of templates/starter-app and
are skipped when its dependencies are not installed (`npm ci` in the template).
"""
import json
import shutil
from pathlib import Path

import pytest

from mobile_surfaces_core.authoring import Authoring
from mobile_surfaces_core.builder import Builder, check_writable_path, lint_sources, parse_tsc
from mobile_surfaces_core.store import Conflict, Store, StoreError

ROOT = Path(__file__).resolve().parents[2]
TEMPLATE = ROOT / "templates" / "starter-app"
SDK = ROOT / "packages" / "mobile-sdk" / "src"

SCREEN = """\
import { useQueryGroup } from "@hermes/mobile-sdk";
import { DataMeta, ListCard } from "./components";
import { money } from "./format";

interface Item {
  id: number;
  title: string;
  amount: number;
}

export function Overview() {
  const state = useQueryGroup([{ name: "items" }]);
  const items = (state.group?.results.items.data as Item[] | undefined) ?? [];
  return (
    <section>
      <h1>Список</h1>
      <ul className="list">
        {items.map((i) => (
          <ListCard key={i.id} title={i.title} amount={money(i.amount)} />
        ))}
      </ul>
      <DataMeta state={state} />
    </section>
  );
}
"""

DEFS = {"queries": {"items": {"sql": "SELECT id, title, amount FROM items ORDER BY id", "shape": "rows"}},
        "mutations": {}}


def messages(diags):
    return [d.message for d in diags]


# -- lint (no Node needed) ---------------------------------------------------------


def test_lint_flags_unsupported_apis_with_file_and_line():
    files = {
        "src/screens.tsx": (
            'import { x } from "lodash";\n'
            "export function A() {\n"
            '  fetch("/api");\n'
            "  eval('1');\n"
            '  localStorage.setItem("a", "b");\n'
            '  const u = "https://example.com/x";\n'
            "  return null;\n"
            "}\n"
        ),
        "src/styles.css": "@import url(https://fonts.example/x.css);\n.a { color: red; }\n",
    }
    found = {(d.file, d.line): d.message for d in lint_sources(files)}
    assert "package 'lodash' is not installed in this template" in found[("src/screens.tsx", 1)]
    assert "network access" in found[("src/screens.tsx", 3)]
    assert "eval" in found[("src/screens.tsx", 4)]
    assert "storage" in found[("src/screens.tsx", 5)]
    assert "external URLs" in found[("src/screens.tsx", 6)]
    assert ("src/styles.css", 1) in found


def test_lint_ignores_comments_and_allows_svg_namespace_and_local_imports():
    files = {
        "src/screens.tsx": (
            'import { useState } from "react";\n'
            'import { Tile } from "./components";\n'
            "// fetch(\"x\") and https://example.com are only mentioned here\n"
            "/* eval('x')\n   localStorage */\n"
            'export const svg = <svg xmlns="http://www.w3.org/2000/svg" />;\n'
        )
    }
    assert lint_sources(files) == []


def test_lint_checks_query_names_against_definitions():
    files = {"src/screens.tsx": 'const s = useQueryGroup([\n  { name: "items" },\n  { name: "ghost" },\n]);\n'}
    found = lint_sources(files, {"queries": {"items": {}, "unused": {}}})
    errors = [d for d in found if d.severity == "error"]
    assert [(d.file, d.line) for d in errors] == [("src/screens.tsx", 3)]
    assert "ghost" in errors[0].message
    warnings = [d for d in found if d.severity == "warning"]
    assert any("unused" in d.message for d in warnings)


def test_writable_paths_are_a_short_allow_list():
    for ok in ("definitions.json", "src/App.tsx", "src/my-screen.tsx", "src/styles.css"):
        assert check_writable_path(ok) == ok
    for bad in ("src/main.tsx", "package.json", "vite.config.ts", "src/sub/x.ts", "../x.ts", "src/x.js", "/etc/passwd"):
        with pytest.raises(ValueError):
            check_writable_path(bad)


def test_tsc_output_becomes_file_line_diagnostics(tmp_path):
    out = "src/screens.tsx(12,5): error TS2322: Type 'string' is not assignable to type 'number'.\nnoise\n"
    [d] = parse_tsc(out, tmp_path)
    assert (d.file, d.line, d.code) == ("src/screens.tsx", 12, "TS2322")


# -- real builds --------------------------------------------------------------------


@pytest.fixture(scope="module")
def builder():
    b = Builder(TEMPLATE, SDK, timeout_s=180)
    reason = b.available()
    if reason or shutil.which("node") is None:
        pytest.skip(reason or "node is not installed")
    return b


@pytest.fixture
def authoring(tmp_path, builder):
    store = Store(tmp_path / "home")
    store.create_app("items_app", "Список")
    store.agent_sql("items_app", "schema", "CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT NOT NULL, amount INTEGER NOT NULL)")
    store.agent_sql("items_app", "write", "INSERT INTO items(title, amount) VALUES (?,?)",
                    params_list=[("Вода", 119000), ("Газ", 79000)])
    return Authoring(store, TEMPLATE, builder), store


def author_screen(auth: Authoring, app_id: str = "items_app") -> None:
    auth.write(app_id, "src/screens.tsx", SCREEN)
    auth.write(app_id, "definitions.json", json.dumps(DEFS))


def test_author_cycle_edit_build_publish_and_the_phone_reads_it(authoring):
    auth, store = authoring
    start = auth.status("items_app")
    assert start["draftRev"] == 1 and start["baseRevision"] == 0
    assert "src/screens.tsx" in {f["path"] for f in start["files"]}

    author_screen(auth)
    built = auth.build("items_app")
    assert built["ok"] is True and built["stage"] == "done", built
    assert built["queries"]["items"]["columns"] == ["id", "title", "amount"]
    assert 20_000 < built["bundleBytes"] < 2_000_000

    published = auth.publish("items_app")
    assert published["revision"] == 1
    manifest = store.get_manifest("items_app")
    assert manifest["bundle"]["bundleId"] == published["bundleId"]
    out = store.run_queries("items_app", 1, [{"name": "items"}], device_id="t", tz_name=None)
    assert [r["title"] for r in out["results"]["items"]["data"]] == ["Вода", "Газ"]
    assert not list((TEMPLATE / ".work").glob("*"))  # throw-away build directories are removed


def test_type_errors_come_back_as_file_and_line(authoring):
    auth, _ = authoring
    broken = SCREEN.replace("export function Overview() {", "export function Overview() {\n  const n: number = 'text';")
    auth.write("items_app", "src/screens.tsx", broken)
    auth.write("items_app", "definitions.json", json.dumps(DEFS))
    result = auth.build("items_app")
    assert result["ok"] is False and result["stage"] == "types"
    first = result["diagnostics"][0]
    broken_line = broken.splitlines().index("  const n: number = 'text';") + 1
    assert first["file"] == "src/screens.tsx" and first["line"] == broken_line and first["code"] == "TS2322"
    with pytest.raises(StoreError, match="no successful build"):
        auth.publish("items_app")


def test_lint_errors_stop_before_the_compiler_runs(authoring):
    auth, _ = authoring
    auth.write("items_app", "src/screens.tsx", SCREEN.replace("<DataMeta state={state} />", "{void fetch('/x')}"))
    auth.write("items_app", "definitions.json", json.dumps(DEFS))
    result = auth.build("items_app")
    assert result["ok"] is False and result["stage"] == "lint"
    assert any("network access" in d["message"] for d in result["diagnostics"])


def test_bad_definitions_fail_with_sqlite_wording_and_nothing_is_published(authoring):
    auth, store = authoring
    auth.write("items_app", "src/screens.tsx", SCREEN)
    auth.write("items_app", "definitions.json", json.dumps(
        {"queries": {"items": {"sql": "SELECT nope FROM items", "shape": "rows"}}, "mutations": {}}))
    result = auth.build("items_app")
    assert result["ok"] is False
    assert any(d["file"] == "definitions.json" and "nope" in d["message"] for d in result["diagnostics"])
    assert store.list_apps() == []


def test_publish_requires_a_build_of_exactly_this_draft(authoring):
    auth, _ = authoring
    author_screen(auth)
    assert auth.build("items_app")["ok"]
    auth.write("items_app", "src/styles.css", ".extra { color: red; }\n")  # edited after the build
    with pytest.raises(Conflict, match="changed after the last build"):
        auth.publish("items_app")


def test_a_draft_cannot_overwrite_a_version_published_after_it_started(authoring):
    auth, _ = authoring
    author_screen(auth)
    assert auth.build("items_app")["ok"]
    assert auth.publish("items_app")["revision"] == 1
    auth.write("items_app", "src/styles.css", ".a { color: red; }\n")
    assert auth.build("items_app")["ok"]
    # Someone publishes underneath this draft (e.g. a second author session on a stale base).
    state = json.loads((auth._draft("items_app") / "draft.json").read_text())
    state["baseRevision"] = 0
    (auth._draft("items_app") / "draft.json").write_text(json.dumps(state))
    with pytest.raises(Conflict, match="published .* after this draft started"):
        auth.publish("items_app")


def test_expected_draft_rev_detects_a_concurrent_edit(authoring):
    auth, _ = authoring
    rev = auth.status("items_app")["draftRev"]
    auth.write("items_app", "src/styles.css", ".a { color: red; }\n", expected_draft_rev=rev)
    with pytest.raises(Conflict, match="draft changed"):
        auth.write("items_app", "src/styles.css", ".b { color: blue; }\n", expected_draft_rev=rev)


def test_writes_outside_the_allow_list_and_oversize_files_are_refused(authoring):
    auth, _ = authoring
    for path in ("src/main.tsx", "package.json", "src/sub/x.ts", "../../escape.ts"):
        with pytest.raises(StoreError):
            auth.write("items_app", path, "x")
    with pytest.raises(StoreError, match="larger than"):
        auth.write("items_app", "src/big.ts", "x" * (70 * 1024))
    with pytest.raises(StoreError, match="valid JSON"):
        auth.write("items_app", "definitions.json", "{not json")
    with pytest.raises(StoreError, match="required"):
        auth.delete("items_app", "src/App.tsx")


def test_a_new_draft_starts_from_the_published_sources_and_reset_restores_them(authoring):
    auth, _ = authoring
    author_screen(auth)
    assert auth.build("items_app")["ok"] and auth.publish("items_app")["revision"] == 1
    auth.write("items_app", "src/screens.tsx", "garbage that is not even code")
    assert auth.reset("items_app")["draftRev"] == 1
    assert auth.read("items_app", "src/screens.tsx")["content"] == SCREEN


def test_build_works_with_a_separate_work_dir_and_a_read_only_template(authoring, builder, tmp_path):
    """The server layout: template read-only, throw-away projects in the service's state directory."""
    import os

    link_probe = tmp_path / "probe-link"
    try:
        os.symlink(TEMPLATE, link_probe, target_is_directory=True)
    except OSError:
        pytest.skip("symlinks are not permitted on this machine")
    auth, store = authoring
    work = tmp_path / "state" / "work"
    auth.builder = Builder(TEMPLATE, SDK, timeout_s=180, work_dir=work)
    author_screen(auth)
    result = auth.build("items_app")
    assert result["ok"] is True, result
    assert work.is_dir() and not list(work.iterdir())  # created, and emptied again
    assert auth.publish("items_app")["revision"] == 1


def test_a_build_over_the_time_limit_is_killed_and_reports_it(authoring, builder):
    auth, store = authoring
    slow = Builder(TEMPLATE, SDK, timeout_s=0.05)
    auth.builder = slow
    author_screen(auth)
    result = auth.build("items_app")
    assert result["ok"] is False
    assert any("time limit" in d["message"] for d in result["diagnostics"]) or "time limit" in result.get("log", "")
    assert store.list_apps() == []
    assert not list((TEMPLATE / ".work").glob("*"))


def test_linked_apps_can_have_interfaces_but_not_mutations(tmp_path, builder):
    import sqlite3

    foreign = tmp_path / "foreign.db"
    conn = sqlite3.connect(foreign)
    conn.execute("CREATE TABLE items (id INTEGER PRIMARY KEY, title TEXT, amount INTEGER)")
    conn.execute("INSERT INTO items(title, amount) VALUES ('A', 100)")
    conn.commit()
    conn.close()
    store = Store(tmp_path / "home")
    store.link_source("ext", "Внешняя", foreign)
    auth = Authoring(store, TEMPLATE, builder)
    auth.write("ext", "src/screens.tsx", SCREEN)
    auth.write("ext", "definitions.json", json.dumps(DEFS))
    assert auth.build("ext")["ok"] and auth.publish("ext")["revision"] == 1

    auth.write("ext", "definitions.json", json.dumps({**DEFS, "mutations": {
        "wipe": {"sql": "DELETE FROM items WHERE id = :id", "params": {"id": {"type": "integer"}}}}}))
    result = auth.build("ext")
    assert result["ok"] is False and any("read-only" in d["message"] for d in result["diagnostics"])


# -- review findings 10, 11, 14: lint, build output and the process tree ----------------------------


def lint_one(text, path="src/a.ts"):
    return lint_sources({path: text})


@pytest.mark.parametrize(
    "line",
    [
        'import raw from "../../../package.json?raw";',
        'import raw from "./a?raw";',
        'import u from "./a?url";',
        'import w from "./a?worker";',
        'import w from "./a#frag";',
        'import x from "../a";',
        'import x from "./sub/a";',
        'import x from "./a.json";',
        'import x from "/etc/passwd";',
        'import x from "file:///etc/passwd";',
        'import x from "data:text/javascript,alert(1)";',
        'import x from "react?raw";',
        'import "../../../x.css";',
        'import raw from"../../../package.json?raw";',
        'export * from "../a";',
        'export { y } from "./a?raw";',
        'import type { Y } from "../a";',
        'import x from "./a\\b";',
    ],
)
def test_lint_refuses_every_import_that_is_not_a_package_or_a_flat_project_file(line):
    found = lint_one(line + "\n")
    assert [d.line for d in found] == [1] and "import" in found[0].message


def test_lint_import_on_the_line_after_from_is_still_checked():
    found = lint_one('import raw from\n  "../../../package.json?raw";\n')
    assert [(d.line, "import" in d.message) for d in found] == [(2, True)]


@pytest.mark.parametrize(
    "line",
    [
        'import { useState } from "react";',
        'import { jsx } from "react/jsx-runtime";',
        'import { createRoot } from "react-dom/client";',
        'import { useQueryGroup } from "@hermes/mobile-sdk";',
        'import { Tile } from "./components";',
        'import { money } from "./format";',
        'import "./styles.css";',
        'import type { Item } from "./types.ts";',
        'import a from "./my-screen_2";',
    ],
)
def test_lint_accepts_packages_and_flat_project_files(line):
    assert lint_one(line + "\n") == []


@pytest.mark.parametrize(
    "line, fragment",
    [
        ('const m = import.meta.glob("../../../*.json", { query: "?raw", eager: true });', "import.meta"),
        ('const u = new URL("../../../package.json", import.meta.url);', "import.meta"),
        ("const k = import . meta . env;", "import.meta"),
        ('const r = require("../../../package.json");', "require"),
        ('import fs = require("fs");', "require"),
    ],
)
def test_lint_refuses_build_time_file_access(line, fragment):
    found = lint_one(line + "\n")
    assert found and all(fragment in d.message for d in found[:1])


def test_lint_mentions_of_those_apis_in_comments_and_strings_do_not_break_comments():
    assert lint_one('// import.meta.glob and require("x") are only mentioned\n/* import raw from "../a?raw" */\n') == []


@pytest.mark.parametrize(
    "css, fragment",
    [
        (".a { background: url(../../../x.png); }", "url()"),
        (".a { background: url('./x.png'); }", "url()"),
        (".a { background: url( \"x.svg\" ); }", "url()"),
        (".a { background: url(\n  ../../x.png\n); }", "url()"),
        ('@font-face { src: url(f.woff2) format("woff2"); }', "url()"),
        (".a { background: image-set(\"a.png\" 1x); }", "image-set"),
        (".a { background: -webkit-image-set(\"a.png\" 1x); }", "image-set"),
        (".a { background: url(https://evil.example/x.png); }", "external"),
        ("@IMPORT \"x.css\";", "@import"),
    ],
)
def test_lint_css_refuses_file_references(css, fragment):
    found = lint_sources({"src/a.css": css + "\n"})
    assert found and fragment in found[0].message, found


def test_lint_css_allows_inline_data_uris_fragments_and_the_svg_namespace():
    css = (
        ".a { background: url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'%3E%3C/svg%3E\"); }\n"
        ".b { background: url(data:image/png;base64,AAAA); }\n"
        ".c { fill: url(#gradient); }\n"
        '.d::before { content: "\\2022"; }\n'
    )
    assert lint_sources({"src/a.css": css}) == []


# -- 11: the comment scanner must not let a lookalike hide code ------------------------------------


@pytest.mark.parametrize(
    "source, line, fragment",
    [
        ('const g = "/*";\nfetch("x");\n', 2, "network"),
        ("const g = '/*';\nfetch('x');\n", 2, "network"),
        ("const g = `/* ${1 + 1}`;\nfetch('x');\n", 2, "network"),
        ("const g = `a ${`/*`} b`;\neval('1');\n", 2, "eval"),
        ('// see /* here\neval("1");\n', 2, "eval"),
        ('const s = "a//b"; fetch("x");\n', 1, "network"),
        ("const s = 'http://x'; fetch('y');\n", 1, "network"),
        ('const r = s.replace(/\\/*$/, "");\nfetch("x");\n', 2, "network"),
        ('const r = /[/*]/.test(s);\nfetch("x");\n', 2, "network"),
        ('const r = x ? /\\/\\*/ : 1;\nfetch("x");\n', 2, "network"),
        ('const g = "a\\"/*";\nfetch("x");\n', 2, "network"),
        ('const g = "line \\\n/*";\nfetch("x");\n', 3, "network"),
        ('const a = 1; /* one */ fetch("x"); /* two */\n', 1, "network"),
        ('/* multi\n   line */ fetch("x");\n', 2, "network"),
        ('/* a */ /* b */\n\nfetch("x");\n', 3, "network"),
        ('return /\\/*/.test(s) && fetch("x");\n', 1, "network"),
    ],
)
def test_lint_a_comment_marker_inside_a_literal_does_not_hide_the_rest(source, line, fragment):
    found = lint_one(source)
    assert any(d.line == line and fragment in d.message for d in found), found


@pytest.mark.parametrize(
    "source",
    [
        '// fetch("x") and https://example.com are only mentioned here\n',
        "/* eval('x')\n   localStorage */\n",
        'const a = 1; // fetch("x")\n',
        'const a = 1; /* fetch("x") */ const b = 2;\n',
        '/* "unbalanced quote\nfetch("x") */\n',
        "/* ` backtick */ const a = 1;\n",
        "const half = total / 2; // eval('x')\n",
        "const pct = (a / b) * 100; /* fetch('x') */\n",
        'const s = "// not a comment"; // eval(1)\n',
    ],
)
def test_lint_real_comments_are_still_ignored(source):
    assert lint_one(source) == []


def test_lint_line_numbers_survive_multi_line_comments_and_templates():
    source = "/* one\n two\n three */\nconst t = `a\nb ${1}\nc`;\nfetch('x');\n"
    assert [d.line for d in lint_one(source) if "network" in d.message] == [7]


@pytest.mark.parametrize(
    "source",
    [
        "const a: Array<object> = [];\n",
        "const m = new Map<object, string>();\n",
        "const s = useState<object>({});\n",
        "const p: Promise<object | null> = x;\n",
        "const l: Set<link> = x;\n",
        "const n: Array<Array<object>> = x;\n",
        "for (let i = 0; i<link.length; i++) {}\n",
        "type T = Array<\n  object>;\n",
    ],
)
def test_lint_types_and_comparisons_are_not_markup(source):
    assert [d for d in lint_one(source, "src/a.tsx") if "element" in d.message] == []


@pytest.mark.parametrize(
    "source",
    [
        'export const f = () => <object data="x" />;\n',
        "export const f = () => <div><iframe src=\"x\" /></div>;\n",
        "export const f = () => { return<object/>; };\n",
        "export const f = () => <p>text<object/></p>;\n",
        "export const f = () => <p>text<embed src='x'/></p>;\n",
        "export const f = () => <p>Привет<object data='x'></object></p>;\n",
        "export const f = () => <p>text<object></object></p>;\n",
        "export const f = () => (\n  <link rel=\"stylesheet\" href=\"x\" />\n);\n",
        "export const f = () => cond ? <script /> : null;\n",
        "export const f = () => <Script />;\n",
    ],
)
def test_lint_real_markup_elements_are_still_refused(source):
    assert any("element" in d.message for d in lint_one(source, "src/a.tsx"))


def test_lint_stays_quiet_on_the_starter_template_sources():
    files = {
        f"src/{p.name}": p.read_text(encoding="utf-8")
        for p in (TEMPLATE / "src").glob("*") if p.is_file() and p.name != "main.tsx"
    }
    assert [d for d in lint_sources(files) if d.severity == "error"] == []


def test_check_dist_flags_stray_files_and_exempts_the_svg_namespace_in_css(tmp_path):
    dist = tmp_path / "dist"
    (dist / "assets").mkdir(parents=True)
    (dist / "index.html").write_text("<!doctype html>")
    (dist / "assets" / "a.js").write_text('const n = "http://www.w3.org/2000/svg";')
    (dist / "assets" / "a.css").write_text(".i{background:url(\"data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg'%3E\")}")
    assert Builder._check_dist(dist) == []
    (dist / "assets" / "leak.json").write_text("{}")
    (dist / "assets" / "b.css").write_text(".i{background:url(https://evil.example/x.png)}")
    found = {d.file: d.message for d in Builder._check_dist(dist)}
    assert "unexpected file" in found["assets/leak.json"] and "external URL" in found["assets/b.css"]


def test_a_project_pulling_a_file_with_raw_fails_at_lint_and_builds_nothing(authoring, tmp_path):
    auth, store = authoring
    auth.write("items_app", "src/leak.ts", 'import raw from "../../../package.json?raw";\nexport const leaked: string = raw;\n')
    auth.write("items_app", "src/screens.tsx", 'import "./leak";\n' + SCREEN)
    auth.write("items_app", "definitions.json", json.dumps(DEFS))
    result = auth.build("items_app")
    assert result["ok"] is False and result["stage"] == "lint"
    assert any(d["file"] == "src/leak.ts" and d["line"] == 1 and "import" in d["message"] for d in result["diagnostics"])
    assert not (TEMPLATE / ".work").exists() or not list((TEMPLATE / ".work").glob("*"))
    with pytest.raises(StoreError, match="no successful build"):
        auth.publish("items_app")


# -- 14: the build runs in its own process group where the platform has one ------------------------


def test_builds_get_their_own_process_group_only_on_posix():
    from mobile_surfaces_core import builder as builder_module

    assert builder_module._session_kwargs("win32") == {}
    assert builder_module._session_kwargs("linux") == {"start_new_session": True}
    assert builder_module._session_kwargs("darwin") == {"start_new_session": True}


def test_posix_kill_signals_the_group_and_falls_back_to_the_child(monkeypatch):
    """Decision logic only: Windows has no killpg, so a stand-in records the call. Real group-kill
    behaviour is not exercised here."""
    import signal

    from mobile_surfaces_core import builder as builder_module

    class Proc:
        pid = 4242
        killed = False

        def kill(self):
            self.killed = True

        def wait(self, timeout=None):
            return 0

    calls = []
    monkeypatch.setattr(builder_module.os, "killpg", lambda pgid, sig: calls.append((pgid, sig)), raising=False)
    monkeypatch.setattr(builder_module.signal, "SIGKILL", getattr(signal, "SIGKILL", 9), raising=False)
    proc = Proc()
    builder_module._kill_tree(proc, platform="linux")
    assert calls == [(4242, signal.SIGKILL if hasattr(signal, "SIGKILL") else 9)] and not proc.killed

    def gone(pgid, sig):
        raise ProcessLookupError

    monkeypatch.setattr(builder_module.os, "killpg", gone, raising=False)
    proc = Proc()
    builder_module._kill_tree(proc, platform="linux")
    assert proc.killed


def test_systemd_run_prefix_without_a_runtime_limit_is_warned_about(caplog):
    import logging

    for prefix, expect_warning in (
        (["systemd-run", "--pipe", "--wait", "-p", "MemoryMax=400M"], True),
        (["/usr/bin/systemd-run", "--pipe", "--wait"], True),
        (["systemd-run", "--pipe", "--wait", "-p", "RuntimeMaxSec=130"], False),
        (["nice", "-n", "10"], False),
        ([], False),
    ):
        caplog.clear()
        with caplog.at_level(logging.WARNING, logger="mobile_surfaces_core.builder"):
            Builder(TEMPLATE, SDK, command_prefix=prefix)
        assert bool(caplog.records) is expect_warning, prefix