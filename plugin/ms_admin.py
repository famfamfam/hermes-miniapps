"""Stage 0 admin CLI: stands in for the agent tools until the plugin runs inside Hermes.

  python ms_admin.py create-app utilities "Utilities"
  python ms_admin.py link-source receipts "Receipts" /path/to/receipts.db   # read-only, never written
  python ms_admin.py allow-writes receipts [--revoke]   # let reviewed buttons of a linked app write into the foreign file
  python ms_admin.py link-files receipts scans /srv/receipts --strip-prefix /home/me/.hermes/receipts   # PDFs the app may offer
  python ms_admin.py sql utilities write "INSERT INTO bills(...) VALUES (...)"
  python ms_admin.py publish utilities --dist ../templates/react-app/dist --defs ../templates/react-app/definitions.json
  python ms_admin.py demo --dist ../templates/react-app/dist --defs ../templates/react-app/definitions.json
  python ms_admin.py install plan                  # install the server as a systemd service (README.md)
  python ms_admin.py pair-code [--public-url https://host/<prefix>/ms] [--token-file F]   # one-time line for the phone app
  python ms_admin.py trash | restore-app NAME | purge-trash [--days N] | delete-app ID  # deleted apps (30 days in the trash)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path

from mobile_surfaces_core import bundle as B
from mobile_surfaces_core import pairing
from mobile_surfaces_core.store import Store, StoreError

DEMO_SCHEMA = (
    "CREATE TABLE bills (id INTEGER PRIMARY KEY, supplier TEXT NOT NULL, period TEXT NOT NULL, "
    "amount INTEGER NOT NULL, status TEXT NOT NULL DEFAULT 'unpaid', created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)"
)
# Amounts are integers in minor units (kopecks), as the authoring conventions require (ADR-003 §9).
DEMO_ROWS = [
    ("Water", "2026-05-01", 118000, "paid"), ("Electricity", "2026-05-01", 436000, "paid"),
    ("Gas", "2026-05-01", 92000, "paid"), ("Water", "2026-06-01", 121000, "paid"),
    ("Electricity", "2026-06-01", 398000, "paid"), ("Gas", "2026-06-01", 87000, "paid"),
    ("Water", "2026-07-01", 125000, "paid"), ("Electricity", "2026-07-01", 512000, "paid"),
    ("Gas", "2026-07-01", 81000, "paid"), ("Water", "2026-08-01", 130000, "paid"),
    ("Electricity", "2026-08-01", 547000, "paid"), ("Water", "2026-09-01", 127000, "paid"),
    ("Electricity", "2026-09-01", 471000, "unpaid"), ("Gas", "2026-09-01", 79000, "unpaid"),
    ("Internet", "2026-09-01", 55000, "paid"), ("Water", "2026-10-01", 119000, "unpaid"),
]


def publish(store: Store, app_id: str, dist: Path, defs_path: Path) -> int:
    definitions = json.loads(defs_path.read_text(encoding="utf-8"))
    normalised = store.validate_definitions(app_id, definitions)
    built = B.build_bundle(dist, contract_hash=store.contract_hash(normalised))
    return store.publish(app_id, built, definitions)


def resolve_public_url(given: str | None, token_file: Path | None) -> str | None:
    """The address the phone reaches: the option, else $MOBILE_SURFACES_PUBLIC_URL, else a one-line file `public-url`
    next to the token files. The last one lets Hermes hand out a connection line without being told the address
    each time; the file is as private as the tokens beside it (the address carries the edge's secret prefix)."""
    if given:
        return given
    env = os.environ.get("MOBILE_SURFACES_PUBLIC_URL", "").strip()
    if env:
        return env
    if token_file is not None:
        try:
            text = (token_file.parent / "public-url").read_text(encoding="utf-8").strip()
        except OSError:
            text = ""
        if text:
            return text
    return None


NO_PUBLIC_URL = ("error: no address for the phone: pass --public-url, set MOBILE_SURFACES_PUBLIC_URL, or write the "
                 "address into a one-line file named public-url next to the token files")


def unreadable_advice(app_id: str, files, only: str | None = None) -> list[str]:
    """Lines telling the administrator which files of a linked folder the service cannot read, and how to fix it. The
    service runs as its own user without root rights, so a file the skill saved with mode 600 is refused by it."""
    lines: list[str] = []
    for w in files.readability_warnings(app_id):
        if only is not None and w["root"] != only:
            continue
        parts = []
        if w["files"]:
            parts.append(f"{w['files']} file(s)")
        if w["folders"]:
            parts.append(f"{w['folders']} folder(s)")
        more = " (first ones only, the folder is large)" if w["truncated"] else ""
        examples = ", ".join(w["examples"])
        lines.append(f"warning: folder {w['root']!r}: {' and '.join(parts)} the service is not allowed to read{more}, e.g. {examples}")
    if lines:
        lines += [
            "  The service has no rights of its own, so it reads what other users may read. Fix it on the host, in the folder that is linked:",
            "    find <folder> -type f ! -perm -o=r -exec chmod a+r {} +",
            "    find <folder> -type d ! -perm -o=rx -exec chmod a+rx {} +",
            "  and make the program that saves the files use mode 0644 (umask 022), or the next one will be refused again.",
        ]
    return lines

def writes_advice(app_id: str, path: Path) -> list[str]:
    """What switching writing on means and what the host must allow. The service cannot be asked from here: it runs
    as another user, and only it can tell whether it may write, which it does when a definition is checked."""
    folder = path.parent
    return [
        f"writing is now allowed for {app_id!r}: its reviewed buttons (mutations) may change {path}",
        "  The program that owns this database does not know about those changes and its own checks do not run:",
        "  every button that writes is reviewed and signed on the phone, but keep to changes the program tolerates.",
        "  The service has no rights of its own, and SQLite also creates files next to the database. Both must hold:",
        f"    1. the folder is mounted writable for the service: in its systemd drop-in use BindPaths={folder} instead of",
        f"       BindReadOnlyPaths=, with ReadWritePaths={folder}; then daemon-reload and restart the service;",
        "    2. the file and its folder are writable for the service's user. It is a dynamic user, so either put it in a group:",
        f"       SupplementaryGroups=<group> in the same drop-in, then chgrp <group> {path} {folder} && chmod g+w {path} {folder};",
        f"       or, on a host that only you use, let everyone write: chmod o+w {path} {folder}",
        "  Until then a save answers that the service is not allowed to write; nothing is damaged. Undo: allow-writes --revoke.",
    ]


def pair_code_from_service(public_url: str, api_url: str, token_file: Path) -> int:
    """Ask the running service for a code. Its databases belong to the service's own user, so a second
    process must not open them; the service issues the code itself and only needs the phone token."""
    token = token_file.read_text(encoding="utf-8").strip()
    request = urllib.request.Request(
        api_url.rstrip("/") + "/api/plugins/mobile-surfaces/v1/admin/pair-code",
        data=b"{}", method="POST",
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=10) as response:
            code = json.load(response)["code"]
        print(pairing.encode(public_url, code))
    except urllib.error.HTTPError as exc:
        print(f"error: the service answered {exc.code}", file=sys.stderr)
        return 1
    except (OSError, ValueError, KeyError, pairing.ConnectionStringError) as exc:
        print(f"error: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    print("one use, valid for 15 minutes", file=sys.stderr)
    return 0


def main(argv: list[str] | None = None) -> int:
    raw = list(sys.argv[1:] if argv is None else argv)
    if raw[:1] == ["install"]:
        # Server installer (systemd unit, venv, tokens): stdlib only, own argument parser and exit codes.
        from mobile_surfaces.install.cli import main as install_main

        return install_main(raw[1:])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--home", type=Path, default=Path(".devhome"))
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("install", help="install, upgrade or remove the server as a service: ms_admin install --help")
    c = sub.add_parser("create-app"); c.add_argument("app_id"); c.add_argument("title"); c.add_argument("--icon")
    k = sub.add_parser("link-source", help="app over an existing SQLite database, opened read-only")
    k.add_argument("app_id"); k.add_argument("title"); k.add_argument("path", type=Path)
    k.add_argument("--icon"); k.add_argument("--brief")
    lf = sub.add_parser(
        "link-files",
        help="let an app's file locators point into a host folder (read-only), e.g. the receipts a skill keeps on disk",
    )
    lf.add_argument("app_id"); lf.add_argument("name", help="folder name used in definitions.json (\"root\")")
    lf.add_argument("path", type=Path)
    lf.add_argument("--strip-prefix", help="the part of the paths stored in the app's data that this folder replaces, "
                    "e.g. /root/.hermes/zhkh")
    aw = sub.add_parser(
        "allow-writes",
        help="let the reviewed buttons of a linked app write into the foreign database (--revoke: read-only again)",
    )
    aw.add_argument("app_id"); aw.add_argument("--revoke", action="store_true")
    uf = sub.add_parser("unlink-files", help="remove a linked folder from an app"); uf.add_argument("app_id"); uf.add_argument("name")
    fs = sub.add_parser("files", help="files and linked folders of an app"); fs.add_argument("app_id")
    s = sub.add_parser("sql"); s.add_argument("app_id"); s.add_argument("mode", choices=["read", "write", "schema"]); s.add_argument("sql")
    p = sub.add_parser("publish"); p.add_argument("app_id"); p.add_argument("--dist", type=Path, required=True); p.add_argument("--defs", type=Path, required=True)
    d = sub.add_parser("demo"); d.add_argument("--dist", type=Path, required=True); d.add_argument("--defs", type=Path, required=True)
    sub.add_parser("list")
    a = sub.add_parser("approvers", help="show or forget the device paired to approve publications")
    a.add_argument("--clear", action="store_true", help="forget the paired device (re-pair from the phone)")
    q = sub.add_parser(
        "pair-code",
        help="print a one-time connection string for the phone app (valid 15 minutes, one use)",
    )
    q.add_argument("--public-url", help="base address the PHONE reaches, e.g. https://host:8443/<secret>/ms "
                   "(default: $MOBILE_SURFACES_PUBLIC_URL, else the file `public-url` next to --token-file)")
    q.add_argument("--token-file", type=Path, help="ask the RUNNING service (needs its phone token file) instead of opening the database")
    q.add_argument("--api-url", default="http://127.0.0.1:8787", help="with --token-file: where the service listens for this process")
    sub.add_parser("trash", help="list deleted apps that can still be restored")
    r = sub.add_parser("restore-app", help="bring a deleted app back (name from `trash`)"); r.add_argument("name")
    g = sub.add_parser("purge-trash", help="erase deleted apps older than N days for good")
    g.add_argument("--days", type=float, default=30.0)
    x = sub.add_parser("delete-app", help="administrator deletion without a phone signature (the app goes to the trash)")
    x.add_argument("app_id")
    args = parser.parse_args(argv)
    if args.cmd == "pair-code":
        args.public_url = resolve_public_url(args.public_url, args.token_file)
        if args.public_url is None:
            print(NO_PUBLIC_URL, file=sys.stderr)
            return 2
        if args.token_file is not None:
            return pair_code_from_service(args.public_url, args.api_url, args.token_file)
    store = Store(args.home)
    try:
        if args.cmd == "create-app":
            store.create_app(args.app_id, args.title, icon=args.icon)
        elif args.cmd == "link-source":
            store.link_source(args.app_id, args.title, args.path, icon=args.icon, brief=args.brief)
            print(f"linked {args.app_id} -> {args.path} (read-only; the file is not modified)")
        elif args.cmd == "allow-writes":
            source = store.source_path(args.app_id)
            store.set_source_writable(args.app_id, not args.revoke)
            if args.revoke:
                print(f"{args.app_id}: read-only again; reviewed buttons can no longer write into {source}")
            else:
                for line in writes_advice(args.app_id, source):
                    print(line)
        elif args.cmd == "link-files":
            real = store.files.link_root(args.app_id, args.name, args.path, args.strip_prefix)
            print(f"linked {args.app_id}/{args.name} -> {real} (read-only; nothing in it is modified)")
            for line in unreadable_advice(args.app_id, store.files, only=args.name):
                print(line)
        elif args.cmd == "unlink-files":
            store.files.unlink_root(args.app_id, args.name)
            print(f"unlinked {args.app_id}/{args.name}")
        elif args.cmd == "files":
            print(json.dumps({"files": store.files.list_files(args.app_id), "roots": store.files.roots(args.app_id)},
                             ensure_ascii=False, indent=2))
            for line in unreadable_advice(args.app_id, store.files):
                print(line, file=sys.stderr)
        elif args.cmd == "sql":
            print(json.dumps(store.agent_sql(args.app_id, args.mode, args.sql), ensure_ascii=False, indent=2))
        elif args.cmd == "publish":
            print("published revision", publish(store, args.app_id, args.dist, args.defs))
        elif args.cmd == "demo":
            try:
                store.create_app("utilities", "Utilities", icon="receipt")
                store.agent_sql("utilities", "schema", DEMO_SCHEMA)
                store.agent_sql("utilities", "write",
                                "INSERT INTO bills(supplier, period, amount, status) VALUES (?,?,?,?)", params_list=DEMO_ROWS)
            except StoreError as exc:
                print(f"(demo data already present: {exc})")
            print("published revision", publish(store, "utilities", args.dist, args.defs))
        elif args.cmd == "list":
            print(json.dumps(store.list_apps(), ensure_ascii=False, indent=2))
        elif args.cmd == "approvers":
            if args.clear:
                print(f"forgot {store.clear_approvers()} paired device(s); the next phone to pair becomes the approver")
            else:
                print(f"paired approver devices: {store.approver_count()}")
        elif args.cmd == "pair-code":
            print(pairing.encode(args.public_url, store.issue_pair_code()))
            print("one use, valid for 15 minutes", file=sys.stderr)
        elif args.cmd == "trash":
            print(json.dumps(store.trash_list(), ensure_ascii=False, indent=2))
        elif args.cmd == "restore-app":
            print(f"restored {store.trash_restore(args.name)}")
        elif args.cmd == "purge-trash":
            print(f"erased {store.trash_purge(args.days)} deleted app(s)")
        elif args.cmd == "delete-app":
            print(f"moved to the trash as {store.delete_app(args.app_id)} (restore with: restore-app)")
    except (StoreError, B.BundleError, pairing.ConnectionStringError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
