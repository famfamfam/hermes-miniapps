#!/usr/bin/env python3
"""End-to-end check of the server installer on a REAL Linux host with systemd. Not part of the pytest suite.

The unit tests fake systemctl, pip and the filesystem; this script is what proves the generated unit is
accepted by systemd and that the installed service really answers. It installs a throw-away copy under a
random name on random loopback ports, probes it, upgrades it (expecting "nothing to do"), and removes it
again with --purge. It needs network access for pip (PyPI) unless you pass --wheelhouse DIR.

    python3 tools/install/smoke_linux.py                     # user scope, no root
    sudo python3 tools/install/smoke_linux.py --scope system # system scope (DynamicUser, credentials, sandbox)
    python3 tools/install/smoke_linux.py --with-authoring    # also needs Node.js 20+ and npm (npm registry)

Exit status: 0 all checks passed, 1 a check failed, 2 not runnable here.
"""
from __future__ import annotations

import argparse
import json
import secrets
import shutil
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

INSTALL = Path(__file__).resolve().parent / "install.py"
API_HEALTH = "/api/plugins/mobile-surfaces/v1/health"
results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> bool:
    results.append((name, ok, detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}" + (f"\n         {detail}" if detail and not ok else ""))
    return ok


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def installer(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(INSTALL), *args], capture_output=True, text=True, timeout=1800)


def http(url: str, token: str | None = None, body: bytes | None = None) -> int | None:
    headers = {"Authorization": f"Bearer {token}"} if token else {}
    if body is not None:
        headers.update({"Content-Type": "application/json", "Accept": "application/json, text/event-stream"})
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=body, headers=headers), timeout=10) as response:
            return response.status
    except urllib.error.HTTPError as exc:
        return exc.code
    except OSError:
        return None


def read_token(common: list[str], which: str) -> str:
    out = installer("status", *common, "--print-token-path", which)
    return Path(out.stdout.strip()).read_text(encoding="utf-8").strip()


def probe(common: list[str], flags: list[str], extra: list[str], apply_out: subprocess.CompletedProcess[str], scope: str, name: str) -> None:
    api_port, mcp_port = flags[1], flags[3]
    status: subprocess.CompletedProcess[str] | None = None
    for _ in range(40):  # the first start imports FastAPI and opens two databases
        status = installer("status", *common, "--health")
        if status.returncode == 0:
            break
        time.sleep(1)
    check("status --health reaches exit 0 (service up, tokens accepted)", status is not None and status.returncode == 0,
          (status.stdout if status else "")[-700:])

    api_token, mcp_token = read_token(common, "api"), read_token(common, "mcp")
    base = f"http://127.0.0.1:{api_port}"
    check("phone API refuses a request without a token (401)", http(base + API_HEALTH) == 401)
    check("phone API accepts its token (200)", http(base + API_HEALTH, api_token) == 200)
    check("phone API refuses the MCP token (401)", http(base + API_HEALTH, mcp_token) == 401)
    mcp = f"http://127.0.0.1:{mcp_port}/mcp"
    init = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "smoke", "version": "0"}}}).encode()
    check("MCP refuses a request without a token (401)", http(mcp, None, init) == 401)
    check("MCP refuses the phone token (401)", http(mcp, api_token, init) == 401)
    check("MCP initialize with its own token succeeds (200)", http(mcp, mcp_token, init) == 200)

    verify = subprocess.run(
        ["systemd-analyze", *(["--user"] if scope == "user" else []), "verify", f"{name}.service"],
        capture_output=True, text=True, timeout=60,
    )
    check("systemd-analyze verify accepts the unit", verify.returncode == 0, verify.stderr[-700:])

    upgrade = installer("apply", *common, *flags, "--upgrade", *extra)
    check("apply --upgrade of an unchanged install has nothing to do", upgrade.returncode == 0 and "nothing to do" in upgrade.stdout,
          upgrade.stdout[-500:] + upgrade.stderr[-500:])
    everything = apply_out.stdout + apply_out.stderr + upgrade.stdout + upgrade.stderr
    check("no token value appears in the installer output", api_token not in everything and mcp_token not in everything)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--scope", choices=["user", "system"], default="user")
    parser.add_argument("--with-authoring", action="store_true")
    parser.add_argument("--wheelhouse", help="install from prebuilt wheels (no PyPI)")
    parser.add_argument("--keep", action="store_true", help="do not uninstall at the end (for inspection)")
    args = parser.parse_args()

    if not sys.platform.startswith("linux"):
        print("smoke_linux.py needs a Linux host with systemd; nothing was done.", file=sys.stderr)
        return 2
    if shutil.which("systemctl") is None:
        print("systemctl not found: this is not a systemd host; nothing was done.", file=sys.stderr)
        return 2

    name = "ms-smoke-" + secrets.token_hex(3)
    common = ["--scope", args.scope, "--name", name]
    flags = ["--api-port", str(free_port()), "--mcp-port", str(free_port())]
    extra = ["--with-authoring"] if args.with_authoring else []
    if args.wheelhouse:
        extra += ["--wheelhouse", args.wheelhouse]
    print(f"smoke install '{name}' ({args.scope} scope), phone API port {flags[1]}, MCP port {flags[3]}")
    try:
        plan = installer("plan", *common, *flags, *extra)
        check("plan exits 0 and says nothing is written", plan.returncode == 0 and "Nothing is written" in plan.stdout, plan.stderr[-400:])
        applied = installer("apply", *common, *flags, "--start", *extra)
        if check("apply exits 0", applied.returncode == 0, (applied.stderr or applied.stdout)[-900:]):
            again = installer("apply", *common, *flags, *extra)
            check("a second apply is refused (exit 3)", again.returncode == 3, str(again.returncode))
            probe(common, flags, extra, applied, args.scope, name)
    finally:
        if not args.keep:
            removed = installer("uninstall", *common, "--purge", "--yes")
            check("uninstall --purge --yes exits 0", removed.returncode == 0, (removed.stderr or removed.stdout)[-500:])
            gone = installer("status", *common)
            check("afterwards the install is gone (status exit 4)", gone.returncode == 4, str(gone.returncode))
    failed = [n for n, ok, _ in results if not ok]
    print(f"\n{len(results) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
