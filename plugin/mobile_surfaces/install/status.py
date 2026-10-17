"""`status`: reads the install record and the host, reports problems, never prints a token."""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import PurePosixPath

from .effects import Deps
from .model import Exit, Layout, Options, make_layout
from .plan import is_ours, options_from_manifest, read_manifest
from .render import render_dropin, render_unit

API_PREFIX = "/api/plugins/mobile-surfaces/v1"


@dataclass
class StatusReport:
    code: Exit
    lines: list[str] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)
    layout: Layout | None = None


def inspect(opts: Options, deps: Deps, *, health: bool = False) -> StatusReport:
    layout = make_layout(opts, deps.host.home, deps.host.environ)
    fs = deps.fs
    manifest = read_manifest(deps, layout)
    report = StatusReport(Exit.OK, layout=layout)
    say = report.lines.append
    if manifest is None:
        others = [p for p in (layout.prefix, layout.unit, *layout.data_paths()) if fs.exists(p)]
        say(f"'{layout.name}' ({layout.scope} scope): not installed")
        if others:
            say(f"  note: {', '.join(map(str, others))} exist without an install record")
        report.code = Exit.NOT_INSTALLED
        return report
    if not is_ours(manifest, layout):
        report.problems.append(f"{layout.manifest} does not describe an install named '{layout.name}' in {layout.scope} scope")
        report.code = Exit.DEGRADED
        say(f"'{layout.name}' ({layout.scope} scope): unrecognised install record")
        return report

    recorded = options_from_manifest(manifest, opts)
    node_dir = manifest.get("options", {}).get("nodeDir")
    problems = report.problems
    package = manifest.get("package", {})
    commit = (manifest.get("source") or {}).get("commit")
    say(f"'{layout.name}' ({layout.scope} scope): {'installed' if manifest.get('complete') else 'INCOMPLETE'}")
    say(f"  package        mobile-surfaces {package.get('version', '?')}" + (f" (source commit {commit[:12]})" if commit else ""))
    say(f"  phone API      http://{recorded.host}:{recorded.api_port}   (token file: {layout.api_token})")
    say(f"  author MCP     http://127.0.0.1:{recorded.mcp_port}/mcp   (token file: {layout.mcp_token})")
    say(f"  authoring      {'on' if recorded.authoring else 'off (data tools only)'}")
    if not manifest.get("complete"):
        problems.append("the install did not finish; re-run `apply --upgrade` to resume or `uninstall` to remove it")

    expected_unit = render_unit(layout, recorded, PurePosixPath(node_dir) if node_dir else None)
    actual_unit = fs.read_text(layout.unit)
    if actual_unit is None:
        problems.append(f"unit file {layout.unit} is missing")
    elif actual_unit != expected_unit:
        problems.append(f"unit file {layout.unit} differs from what the installer renders (edited by hand, or an upgrade is pending)")
    else:
        say(f"  unit           {layout.unit}  (matches)")
    expected_dropin = render_dropin(layout, recorded)
    actual_dropin = fs.read_text(layout.dropin)
    if expected_dropin is not None and actual_dropin != expected_dropin:
        problems.append(f"drop-in {layout.dropin} is missing or differs from the installer's rendering")
    if not deps.staging:  # a staged tree has no virtualenv or node_modules by design: those steps are live-only
        if not fs.exists(layout.python):
            problems.append(f"virtualenv python {layout.python} is missing")
        if recorded.authoring and not fs.is_dir(layout.templates / "node_modules"):
            problems.append(f"authoring is on but {layout.templates}/node_modules is missing (run `apply --upgrade`)")

    for label, path in (("phone API token", layout.api_token), ("MCP token", layout.mcp_token)):
        mode = fs.mode(path)
        if not fs.exists(path):
            problems.append(f"{label} file {path} is missing")
        elif mode is not None and mode & 0o077:
            problems.append(f"{label} file {path} is accessible to others (mode {mode:04o}); fix with chmod 600")

    _systemd(report, deps, layout)
    if health:
        _health(report, deps, layout, recorded)
    for problem in problems:
        say(f"  PROBLEM: {problem}")
    if problems:
        report.code = Exit.DEGRADED
    return report


def _systemd(report: StatusReport, deps: Deps, layout: Layout) -> None:
    if deps.staging or not deps.host.is_linux:
        report.lines.append("  systemd        not checked (not a live Linux host)")
        return
    ctl = layout.systemctl
    active = deps.runner.run([*ctl, "is-active", layout.unit_name], timeout=15).stdout.strip() or "unknown"
    enabled = deps.runner.run([*ctl, "is-enabled", layout.unit_name], timeout=15).stdout.strip() or "unknown"
    report.lines.append(f"  systemd        {active}, {enabled}")
    if active == "failed":
        report.problems.append(f"the service has failed: {' '.join(ctl)} status {layout.unit_name} / journalctl")


def _read_token(deps: Deps, path: PurePosixPath) -> str | None:
    text = deps.fs.read_text(path)
    return text.strip() if text else None


def _health(report: StatusReport, deps: Deps, layout: Layout, opts: Options) -> None:
    """Loopback requests only; the tokens are read from their files and used as headers, never printed."""
    say = report.lines.append
    if deps.staging:
        say("  health         not checked (staging root)")
        return
    host = {"0.0.0.0": "127.0.0.1", "::": "[::1]"}.get(opts.host, opts.host)
    mapped = host != opts.host
    if ":" in host and not host.startswith("["):
        host = f"[{host}]"  # an IPv6 literal in a URL needs brackets (--host ::1)
    if not opts.loopback_only and not mapped:
        say(f"  health         phone API is bound to {opts.host}: not probed (only loopback is contacted)")
    else:
        token = _read_token(deps, layout.api_token)
        code = None if token is None else deps.http_status(f"http://{host}:{opts.api_port}{API_PREFIX}/health", {"Authorization": f"Bearer {token}"})
        say(f"  health         phone API /health: {code if code is not None else 'no answer'}")
        if code != 200:
            report.problems.append("the phone API did not answer 200 on /health with its token (is the service running?)")
    token = _read_token(deps, layout.mcp_token)
    code = None if token is None else deps.http_status(f"http://127.0.0.1:{opts.mcp_port}/mcp", {"Authorization": f"Bearer {token}"})
    # The MCP endpoint wants a POST with a JSON-RPC body, so a GET is rejected with 4xx; what matters is that
    # the token is accepted (anything but 401) and that something answers.
    say(f"  health         MCP /mcp with token: {code if code is not None else 'no answer'}" + ("" if code in (None, 401) else " (reachable, token accepted)"))
    if code is None or code == 401:
        report.problems.append("the MCP endpoint did not answer, or rejected its own token")
