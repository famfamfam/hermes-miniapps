"""Renders the systemd unit, the resource drop-in and the install manifest. Pure functions."""
from __future__ import annotations

import hashlib
import json
import re
from importlib import resources
from pathlib import PurePosixPath
from typing import Any, Mapping

from .model import LOOPBACK, SCHEMA, SMALL_DATA_ONLY, SMALL_WITH_BUILDS, Layout, Limits, Options

_PLACEHOLDER = re.compile(r"@@([A-Z_]+)@@")
_FORBIDDEN = re.compile(r"[\x00-\x08\x0b-\x1f%$]")  # control characters; `%` and `$` are expanded by systemd
_CPU_QUOTA = re.compile(r"CPUQuota=[1-9][0-9]{0,3}%")
DEFAULT_PATH = ("/usr/local/sbin", "/usr/local/bin", "/usr/sbin", "/usr/bin", "/sbin", "/bin")


def load_template(name: str) -> str:
    return (resources.files("mobile_surfaces.install") / "templates" / name).read_text(encoding="utf-8")


def render_template(template: str, values: Mapping[str, str]) -> str:
    """Fill `@@NAME@@` placeholders. A placeholder alone on its line whose value is empty removes the line.

    Unknown placeholders, unused values and characters that systemd would expand are errors, so a typo
    cannot silently produce a different unit than the one that was reviewed.
    """
    used: set[str] = set()
    out: list[str] = []
    for line in template.splitlines():
        found = _PLACEHOLDER.findall(line)
        for key in found:
            if key not in values:
                raise ValueError(f"template placeholder @@{key}@@ has no value")
            used.add(key)
        if not found:
            out.append(line)
            continue
        whole = _PLACEHOLDER.fullmatch(line)
        if whole and values[whole.group(1)] == "":
            continue
        out.append(_PLACEHOLDER.sub(lambda m: values[m.group(1)], line))
    unused = set(values) - used
    if unused:
        raise ValueError(f"unused template values: {', '.join(sorted(unused))}")
    text = "\n".join(out) + "\n"
    for number, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("#") or _CPU_QUOTA.fullmatch(line):  # CPUQuota=NN% is a value, not a specifier
            continue
        if _FORBIDDEN.search(line):
            raise ValueError(f"line {number} contains a character that systemd would expand: {line!r}")
    return text


def exec_start(layout: Layout, opts: Options) -> str:
    """The ExecStart= line. Tokens are never arguments, only the names of the files that hold them: the system
    service gets root-only files as systemd credentials, the user service reads its own 0600 files."""
    if layout.scope == "system":
        token_args = "--token-file credential:api-token --mcp-token-file credential:mcp-token"
    else:
        token_args = f"--token-file {layout.api_token} --mcp-token-file {layout.mcp_token}"
    groups = [
        f"{layout.python} -I -u -m devserver",
        f"--home {layout.state_dir}",
        f"--host {opts.host} --port {opts.api_port}",
        f"--mcp-host {LOOPBACK} --mcp-port {opts.mcp_port}",
        token_args,
    ]
    if opts.authoring:
        groups += [
            f"--template {layout.templates} --sdk {layout.sdk}",
            f"--work-dir {layout.work_dir} --build-timeout {opts.build_timeout}",
        ]
    else:
        groups.append("--no-authoring")
    return "ExecStart=" + " \\\n    ".join(groups)


def path_environment(node_dir: PurePosixPath | None) -> str:
    if node_dir is None:
        return ""
    dirs = [str(node_dir), *(d for d in DEFAULT_PATH if d != str(node_dir))]
    return "Environment=PATH=" + ":".join(dirs)


def bind_note(opts: Options) -> str:
    if opts.loopback_only:
        return ""
    return (
        f"# WARNING: the phone API is bound to {opts.host}, which is not a loopback address. It speaks plain HTTP.\n"
        "# Put a private network (VPN, SSH tunnel) or a TLS reverse proxy in front of it; see README.md."
    )


def network_acl(opts: Options) -> str:
    """The service only listens and never connects out, so with a loopback bind nothing else needs the network."""
    if not opts.loopback_only:
        return "# IPAddressDeny is not set because the phone API is bound to a non-loopback address."
    return "\n".join([
        "# Only loopback traffic is allowed: the service never needs to reach (or be reached from) anything else.",
        "IPAddressDeny=any",
        "IPAddressAllow=localhost",
    ])


def user_sandbox(layout: Layout, opts: Options) -> str:
    if not opts.user_sandbox:
        return ""
    return "\n".join([
        "# Extra sandboxing (--user-sandbox). Needs unprivileged user namespaces; if the unit fails to start with",
        "# status 226/NAMESPACE, run the installer again without --user-sandbox.",
        "ProtectSystem=strict",
        "ProtectHome=read-only",
        f"ReadWritePaths={layout.state_dir}",
        "PrivateTmp=yes",
        "ProtectKernelTunables=yes",
        "ProtectControlGroups=yes",
    ])


def render_unit(layout: Layout, opts: Options, node_dir: PurePosixPath | None) -> str:
    values = {
        "SCHEMA": str(SCHEMA),
        "NAME": layout.name,
        "STATE_DIR": str(layout.state_dir),
        "ENVIRONMENT": path_environment(node_dir),
        "EXEC_START": exec_start(layout, opts),
        "BIND_NOTE": bind_note(opts),
    }
    if layout.scope == "system":
        values.update(API_TOKEN=str(layout.api_token), MCP_TOKEN=str(layout.mcp_token), NETWORK_ACL=network_acl(opts))
        return render_template(load_template("system.service.tmpl"), values)
    values["SANDBOX"] = user_sandbox(layout, opts)
    return render_template(load_template("user.service.tmpl"), values)


def limits_label(limits: Limits) -> str:
    return "profile for small hosts" if limits in (SMALL_DATA_ONLY, SMALL_WITH_BUILDS) else "custom values"


def render_dropin(layout: Layout, opts: Options) -> str | None:
    if opts.limits is None:
        return None
    values = {
        "SCHEMA": str(SCHEMA),
        "PROFILE": limits_label(opts.limits),
        "LIMITS": "\n".join(opts.limits.lines()),
    }
    return render_template(load_template("resources.conf.tmpl"), values)


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def render_manifest(data: Mapping[str, Any]) -> str:
    """Stable JSON: identical input gives identical bytes, so a repeated apply writes nothing."""
    return json.dumps(data, indent=2, sort_keys=True) + "\n"
