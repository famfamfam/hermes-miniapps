"""Human-readable output. Everything printed here is derived from paths and options, never from token values."""
from __future__ import annotations

from .hermes import Snippets
from .model import DEFAULT_NAME, Layout, Options
from .plan import Plan

API_HEALTH_PATH = "/api/plugins/mobile-surfaces/v1/health"


def _indent(text: str, pad: str = "    ") -> list[str]:
    return [pad + line if line else line for line in text.rstrip("\n").splitlines()]


def summary_lines(plan: Plan) -> list[str]:
    layout, opts = plan.layout, plan.opts
    bind = f"{opts.host}:{opts.api_port}" + ("" if opts.loopback_only else "   <-- NOT loopback")
    limits = ", ".join(opts.limits.lines()) if opts.limits else "none (the unit sets no resource ceilings)"
    return [
        f"  name / scope   {layout.name} / {layout.scope}",
        f"  code + venv    {layout.prefix}",
        f"  data           {layout.state_dir}",
        f"  tokens         {layout.secrets_dir}  (files api-token, mcp-token)",
        f"  unit           {layout.unit}",
        f"  phone API      {bind}",
        f"  author MCP     127.0.0.1:{opts.mcp_port}  (always loopback)",
        f"  authoring      {'on (template, SDK and Node build tools)' if opts.authoring else 'off (data tools only)'}",
        f"  limits         {limits}",
        f"  start/enable   {'start' if opts.start else 'do not start'}, {'enable' if opts.enable else 'do not enable'}",
    ]


def format_plan(plan: Plan, *, dry: bool) -> list[str]:
    title = {"install": "install", "uninstall": "uninstall"}[plan.command]
    lines = [f"PLAN: {title} '{plan.layout.name}'. " + ("Nothing is written." if dry else "These steps will run.")]
    lines += summary_lines(plan) if plan.command == "install" else [f"  name / scope   {plan.layout.name} / {plan.layout.scope}"]
    if plan.refusals:
        lines += ["", "REFUSED (apply would change nothing):", *[f"  - {r}" for r in plan.refusals]]
    if plan.warnings:
        lines += ["", "Warnings:", *[f"  - {w}" for w in plan.warnings]]
    if plan.steps:
        changing = len(plan.changes)
        lines += ["", f"Steps ({changing} would change, {len(plan.steps) - changing} already in place):"]
        for step in plan.steps:
            label = "ok" if step.state == "unchanged" else step.state
            extra = f"   [{step.note}]" if step.note else ""
            lines.append(f"  {label:<9}{step.action.describe()}{extra}")
    if plan.command == "install":
        lines += ["", "Network access made by `apply`:"]
        lines += [f"  - {n}" for n in plan.network] or ["  - none (nothing is downloaded)"]
        enforced = plan.layout.scope == "system" and plan.opts.loopback_only
        lines += ["  - the service itself makes no outgoing connection; it only listens on the addresses above"
                  + (" (enforced by IPAddressDeny=any in the unit)" if enforced else "")]
    if plan.notes:
        lines += ["", "Notes:", *[f"  - {n}" for n in plan.notes]]
    if plan.command == "install" and plan.snippets is not None and not plan.opts.write_hermes_config:
        lines += ["", *hermes_section(plan.layout, plan.opts, plan.snippets, applied=False)]
    return lines


def hermes_section(layout: Layout, opts: Options, snip: Snippets, *, applied: bool) -> list[str]:
    lines = ["Hermes configuration " + ("(written by --write-hermes-config; shown for reference)" if applied else
             "(NOT applied: Hermes' own files are never edited without --write-hermes-config)")]
    local = {"0.0.0.0": "127.0.0.1", "::": "[::1]"}.get(opts.host, opts.host)
    if ":" in local and not local.startswith("["):
        local = f"[{local}]"  # an IPv6 literal in a URL needs brackets
    api_url = "" if (local, opts.api_port) == ("127.0.0.1", 8787) else f" --api-url http://{local}:{opts.api_port}"
    lines += [
        "",
        "  FIRST pair your phone as the approver (the first device to pair wins). Until a",
        "  device is paired, the agent's app_publish publishes WITHOUT review. Connect Hermes only after that.",
        "  With the service running, print a one-time connection line (valid 15 minutes) and paste it in the phone app",
        "  (Apps > Paste connection code); it pairs the phone and hands it the token without typing:",
        f"       sudo {layout.python} -I -m ms_admin pair-code --public-url <address the phone reaches> \\",
        f"            --token-file {layout.api_token}{api_url}",
        f"  (Write that address once into {layout.secrets_dir}/public-url, mode 0600, and --public-url can be left out;",
        "  the connect-phone skill then lets Hermes send the line from a chat without asking for it.)",
    ]
    lines += ["", f"  1. MCP server, in {snip.hermes_home_display}/config.yaml:", *_indent(snip.mcp_yaml, "       ")]
    if snip.token_env_command:
        lines += ["", f"  2. The token, kept out of config.yaml. Run on this host (the value is not printed):",
                  f"       {snip.token_env_command}",
                  "     If your Hermes version does not expand ${...} in headers, use --hermes-token-mode inline instead."]
    else:
        lines += ["", f"  2. Replace the placeholder after Bearer with the contents of {layout.mcp_token}."]
    lines += ["", f"  3. Optional, the official Hermes API server for the mobile chat, in {snip.hermes_home_display}/.env:",
              *_indent(snip.api_env, "       "),
              "     Generate the key yourself, for example: python3 -c \"import secrets; print(secrets.token_hex(32))\"",
              "     The API server exposes all agent tools: keep it on loopback and reach it through an SSH tunnel or VPN.",
              "",
              "  4. Optional, the interface author skill (restart or start a new Hermes session afterwards):",
              *_indent(snip.skills_yaml or "", "       ")]
    lines += ["", "  Then reload MCP in Hermes (`/reload-mcp` in a chat) and check with `hermes mcp test " + opts.mcp_name + "`."]
    return lines


def final_report(plan: Plan) -> list[str]:
    layout, opts = plan.layout, plan.opts
    ctl = " ".join(layout.systemctl)
    sudo = "sudo " if layout.scope == "system" else ""
    lines = [
        "",
        f"Installed '{layout.name}' ({layout.scope} scope).",
        "",
        "Token files (values are not shown; read them with cat when you need them):",
        f"  phone API   {layout.api_token}",
        f"  MCP         {layout.mcp_token}",
        "",
        "Next:",
    ]
    if not opts.start:
        lines.append(f"  {sudo}{ctl} start {layout.unit_name}")
    probe_host = "127.0.0.1" if opts.host in ("0.0.0.0", "::") or opts.loopback_only else opts.host
    # `sudo` goes inside $(...): the calling shell would otherwise try to read a root-only file itself.
    flags = f" --scope {layout.scope}" + ("" if layout.name == DEFAULT_NAME else f" --name {layout.name}")
    lines += [
        f"  curl -s -H \"Authorization: Bearer $({sudo}cat {layout.api_token})\" http://{probe_host}:{opts.api_port}{API_HEALTH_PATH}",
        f"  {sudo}{layout.python} -m mobile_surfaces.install status --health{flags}",
        "",
    ]
    notes = [n for n in plan.notes if "is not started by this install" not in n]  # "Next:" already says it
    if notes:
        lines += ["Notes:", *[f"  - {n}" for n in notes], ""]
    if plan.snippets is not None:
        lines += hermes_section(layout, opts, plan.snippets, applied=opts.write_hermes_config)
    return lines
