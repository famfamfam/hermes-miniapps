"""Command line of the server installer: `python -m mobile_surfaces.install [plan|apply|status|uninstall]`."""
from __future__ import annotations

import argparse
import sys
from dataclasses import replace
from pathlib import Path
from typing import Sequence

from .effects import Deps, default_deps
from .execute import execute, preflight
from .model import DEFAULT_MCP_NAME, DEFAULT_NAME, Exit, InstallError, Options, check_name, check_posix_dir, make_layout, resolve_limits
from .plan import Plan, is_ours, options_from_manifest, plan_install, plan_uninstall, read_manifest
from .report import final_report, format_plan
from .status import inspect

EPILOG = """\
commands:
  plan       (default) print exactly what `apply` would change; writes nothing, downloads nothing
  apply      do it; refuses when an install of this name already exists unless --upgrade is given
  status     inspect an install: files, unit, token permissions, systemd state; --health also probes loopback
  uninstall  remove the unit and the code; keeps databases and tokens unless --purge --yes

exit codes:
  0 ok   1 a step failed   2 bad command line   3 refused (nothing was changed)
  4 not installed   5 installed but degraded (status)

The installer never edits Hermes' own files unless --write-hermes-config is given.
"""


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="python -m mobile_surfaces.install",
        description="Install the Mobile Surfaces server (phone API + author MCP) as a systemd service.",
        epilog=EPILOG, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("command", nargs="?", default="plan", choices=["plan", "apply", "status", "uninstall"])
    g = p.add_argument_group("where")
    g.add_argument("--scope", choices=["system", "user"], help="system (root, DynamicUser, /opt /var/lib /etc) or user (no root, ~/.local); default: system when root, else user")
    g.add_argument("--name", help=f"install name, also the unit name (default {DEFAULT_NAME})")
    g.add_argument("--prefix", help="code/venv directory on the target host (default /opt/NAME or ~/.local/share/NAME)")
    g.add_argument("--root", type=Path, help="stage all files below DIR instead of the real filesystem; no venv, pip, npm or systemctl runs")
    g.add_argument("--source", type=Path, help="the repository checkout to install from (default: the checkout this file is in)")
    g.add_argument("--python", help="interpreter for the virtualenv (default: the one running the installer; 3.11+)")
    g = p.add_argument_group("network")
    g.add_argument("--host", help="bind address of the PHONE API (default 127.0.0.1). A non-loopback address serves plain HTTP: see docs. MCP is always loopback")
    g.add_argument("--api-port", type=int, help="phone API port (default 8787)")
    g.add_argument("--mcp-port", type=int, help="MCP port (default 8788)")
    g = p.add_argument_group("interface authoring (optional, needs Node.js)")
    g.add_argument("--with-authoring", dest="authoring", action="store_const", const=True, default=None, help="install the template and SDK and run `npm ci` once; the agent can then build interfaces")
    g.add_argument("--no-authoring", dest="authoring", action="store_const", const=False, help="data tools only (default on a fresh install)")
    g.add_argument("--node", help="node executable to use (default: node from PATH)")
    g.add_argument("--copy-node", action="store_const", const=True, default=None, help="use a private copy of the node binary (when node lives under /root or /home)")
    g.add_argument("--build-timeout", type=int, help="seconds allowed per interface build (default 150)")
    g.add_argument("--npm-cache", type=Path, help="offline npm cache DIR: `npm ci --offline --cache DIR`")
    g = p.add_argument_group("resources")
    g.add_argument("--limits", choices=["none", "small"], help="'small' writes a resource drop-in sized for a 2 GiB host (see docs); default none")
    g.add_argument("--memory-high", help="MemoryHigh, e.g. 320M")
    g.add_argument("--memory-max", help="MemoryMax, e.g. 450M (interface builds need about this much)")
    g.add_argument("--cpu-quota", help="CPUQuota, e.g. 100%%")
    g.add_argument("--user-sandbox", action="store_const", const=True, default=None, help="user scope: extra sandboxing (needs unprivileged user namespaces)")
    g = p.add_argument_group("offline installation")
    g.add_argument("--wheelhouse", type=Path, help="install from prebuilt wheels in DIR only (pip --no-index); no network")
    g = p.add_argument_group("service")
    g.add_argument("--enable", action="store_true", help="systemctl enable (start at boot/login)")
    g.add_argument("--start", action="store_true", help="systemctl restart after installing (default: do not start)")
    g.add_argument("--upgrade", action="store_true", help="refresh an existing install of this name (tokens and data are kept)")
    g.add_argument("--reuse-data", action="store_true", help="adopt a state/token directory left by an earlier uninstall")
    g.add_argument("--rotate-tokens", action="store_true", help="with --upgrade: replace both tokens (the old ones stop working)")
    g = p.add_argument_group("Hermes")
    g.add_argument("--hermes-user", help="system scope: user that runs Hermes; it will own the MCP token file")
    g.add_argument("--hermes-home", help="Hermes home directory on the target host (default $HERMES_HOME or ~/.hermes)")
    g.add_argument("--write-hermes-config", action="store_true", help="edit Hermes' config.yaml and .env (backup first, idempotent). Off by default")
    g.add_argument("--hermes-token-mode", choices=["env", "inline"], default=None, help="env (default): header uses ${%s} filled from Hermes' .env; inline: the token is written into config.yaml" % "MOBILE_SURFACES_MCP_TOKEN")
    g.add_argument("--mcp-name", help=f"name of the MCP server entry in Hermes (default {DEFAULT_MCP_NAME})")
    g = p.add_argument_group("other")
    g.add_argument("--dry-run", action="store_true", help="apply/uninstall: print the plan and stop (same as `plan`)")
    g.add_argument("--purge", action="store_true", help="uninstall: also delete databases and tokens (needs --yes)")
    g.add_argument("--yes", action="store_true", help="confirm --purge")
    g.add_argument("--health", action="store_true", help="status: probe the loopback endpoints with the tokens from their files")
    g.add_argument("--print-token-path", choices=["api", "mcp"], help="status: print only the path of that token file")
    return p


def resolve_options(args: argparse.Namespace, deps: Deps) -> Options:
    """Command line over the install record (for upgrade/status/uninstall) over built-in defaults."""
    host = deps.host
    base = Options(
        scope=args.scope or ("system" if host.is_root else "user"),
        name=check_name(args.name or DEFAULT_NAME),
        prefix=check_posix_dir(args.prefix, "--prefix") if args.prefix else None,
    )
    if base.scope not in ("system", "user"):
        raise InstallError(f"--scope {base.scope!r}: use 'system' or 'user'")
    layout = make_layout(base, host.home, host.environ)
    record = read_manifest(deps, layout)
    if (args.command in ("status", "uninstall") or args.upgrade) and is_ours(record, layout):
        base = options_from_manifest(record, base)  # type: ignore[arg-type]

    def pick(value, current):  # noqa: ANN001
        return current if value is None else value

    authoring = bool(pick(args.authoring, base.authoring))
    limits = base.limits
    if any(v is not None for v in (args.limits, args.memory_high, args.memory_max, args.cpu_quota)):
        limits = resolve_limits(args.limits, authoring, args.memory_high, args.memory_max, args.cpu_quota, base.limits)
    return replace(
        base,
        host=pick(args.host, base.host), api_port=pick(args.api_port, base.api_port), mcp_port=pick(args.mcp_port, base.mcp_port),
        authoring=authoring, node=args.node, copy_node=bool(pick(args.copy_node, base.copy_node)),
        build_timeout=pick(args.build_timeout, base.build_timeout), limits=limits,
        user_sandbox=bool(pick(args.user_sandbox, base.user_sandbox)),
        hermes_user=pick(args.hermes_user, base.hermes_user),
        hermes_home=check_posix_dir(args.hermes_home, "--hermes-home") if args.hermes_home else None,
        write_hermes_config=args.write_hermes_config,
        hermes_token_mode=args.hermes_token_mode or "env", mcp_name=pick(args.mcp_name, base.mcp_name),
        wheelhouse=args.wheelhouse.resolve() if args.wheelhouse else None,
        npm_cache=args.npm_cache.resolve() if args.npm_cache else None,
        enable=args.enable, start=args.start, upgrade=args.upgrade, reuse_data=args.reuse_data,
        rotate_tokens=args.rotate_tokens, python=args.python, purge=args.purge, yes=args.yes,
    ).validate()


def _show(plan: Plan, deps: Deps, *, dry: bool) -> None:
    for line in format_plan(plan, dry=dry):
        deps.out(line)


def run(args: argparse.Namespace, deps: Deps) -> int:
    opts = resolve_options(args, deps)
    command = args.command
    source = args.source.resolve() if args.source else None
    if args.print_token_path and command != "status":
        raise InstallError("--print-token-path belongs to `status`", Exit.USAGE)

    if command == "status":
        report = inspect(opts, deps, health=args.health)
        if args.print_token_path and report.layout is not None:
            path = report.layout.api_token if args.print_token_path == "api" else report.layout.mcp_token
            if report.code == Exit.NOT_INSTALLED:
                deps.err(f"error: '{report.layout.name}' is not installed in {report.layout.scope} scope")
                return int(Exit.NOT_INSTALLED)
            deps.out(str(path))
            return int(Exit.OK)
        for line in report.lines:
            deps.out(line)
        if report.code == Exit.NOT_INSTALLED:
            other = "user" if opts.scope == "system" else "system"
            deps.out(f"  hint: this looked in {opts.scope} scope; use --scope {other} to look in the other one")
        return int(report.code)

    if command == "uninstall":
        plan = plan_uninstall(opts, deps)
        if args.dry_run:
            _show(plan, deps, dry=True)
            return int(Exit.NOT_INSTALLED if plan.not_installed else Exit.REFUSED if plan.refusals else Exit.OK)
        if plan.refusals:
            _show(plan, deps, dry=True)
            return int(Exit.NOT_INSTALLED if plan.not_installed else Exit.REFUSED)
        _show(plan, deps, dry=False)
        execute(plan, deps)
        deps.out("")
        deps.out(f"Uninstalled '{plan.layout.name}'.")
        return int(Exit.OK)

    plan = plan_install(opts, deps, source)
    if command == "plan" or args.dry_run:
        _show(plan, deps, dry=True)
        return int(Exit.REFUSED if plan.refusals else Exit.OK)
    if not plan.changes and not plan.refusals:
        deps.out(f"'{plan.layout.name}' ({plan.layout.scope} scope) is already up to date; nothing to do.")
        return int(Exit.OK)
    preflight(plan, deps)
    for warning in plan.warnings:
        deps.err(f"warning: {warning}")
    deps.out(f"Installing '{plan.layout.name}' ({plan.layout.scope} scope){' [staging root]' if deps.staging else ''}:")
    execute(plan, deps)
    for line in final_report(plan):
        deps.out(line)
    return int(Exit.OK)


def main(argv: Sequence[str] | None = None, *, deps: Deps | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(list(argv) if argv is not None else None)
    deps = deps or default_deps(args.root)
    try:
        return run(args, deps)
    except InstallError as exc:
        deps.err(f"error: {exc}")
        return int(exc.code)
    except ValueError as exc:  # a refused probe or bad value: one line, not a traceback
        deps.err(f"error: {exc}")
        return int(Exit.FAILED)
    except OSError as exc:  # a permission or disk problem: say which path, without a traceback
        where = f" ({exc.filename})" if exc.filename else ""
        deps.err(f"error: {exc.strerror or type(exc).__name__}{where}. The install may be incomplete: "
                 "fix the cause and re-run with --upgrade, or run `uninstall`.")
        return int(Exit.FAILED)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
