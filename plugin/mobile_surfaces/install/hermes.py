"""What the installer tells Hermes, and (only on request) how it edits Hermes' files.

By default nothing here touches the Hermes configuration: `snippets()` renders text for the person
installing to review and paste. `upsert_mcp_entry` / `upsert_env` / `remove_mcp_entry` are used only
behind `--write-hermes-config`, and always after a backup (see `plan.py`).

Assumptions about Hermes (checked against its public documentation, to be confirmed on the Hermes
version in use): servers live under `mcp_servers:` in `~/.hermes/config.yaml`; an HTTP server takes `url`,
`headers`, `timeout`; the key `trust: untrusted` is understood (it is what the reference deployment uses);
`${VAR}` in a header is expanded from `~/.hermes/.env`; the official API server is switched on with
API_SERVER_* variables in `~/.hermes/.env`.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import PurePosixPath

from .model import TOKEN_ENV_VAR, InstallError, Layout, Options

API_SERVER_PORT = 8642
MCP_TIMEOUT = 180  # a build takes 10-60 s; the VPS deployment uses the same value


class ConfigConflict(InstallError):
    """The existing Hermes file cannot be edited safely by text surgery; the caller prints the snippet instead."""


@dataclass(frozen=True)
class Snippets:
    mcp_yaml: str
    token_env_command: str | None  # copies the token into Hermes' .env without printing it
    api_env: str
    skills_yaml: str | None
    hermes_home_display: str


# -- the MCP entry -------------------------------------------------------------------------------------


def start_marker(name: str) -> str:
    return f"# >>> mobile-surfaces:{name} (managed by mobile_surfaces.install; edit outside the markers) >>>"


def end_marker(name: str) -> str:
    return f"# <<< mobile-surfaces:{name} <<<"


def entry_lines(name: str, port: int, authorization: str, indent: int) -> list[str]:
    """The managed block: `authorization` is the header value, e.g. 'Bearer ${MOBILE_SURFACES_MCP_TOKEN}'."""
    pad = " " * indent
    return [
        f"{pad}{start_marker(name)}",
        f"{pad}{name}:",
        f'{pad}  url: "http://127.0.0.1:{port}/mcp"',
        f"{pad}  trust: untrusted",
        f"{pad}  timeout: {MCP_TIMEOUT}",
        f"{pad}  headers:",
        f'{pad}    Authorization: "{authorization}"',
        f"{pad}{end_marker(name)}",
    ]


def env_authorization() -> str:
    return "Bearer ${" + TOKEN_ENV_VAR + "}"


def snippets(layout: Layout, opts: Options, hermes_home: PurePosixPath, home: PurePosixPath) -> Snippets:
    display = "~/.hermes" if hermes_home == home / ".hermes" else str(hermes_home)
    if opts.hermes_token_mode == "env":
        authorization = env_authorization()
        command = (
            "umask 077 && printf '%s=%s\\n' " + f"{TOKEN_ENV_VAR} \"$(cat {layout.mcp_token})\" >> {display}/.env"
        )
    else:
        authorization = f"Bearer <paste the contents of {layout.mcp_token}>"
        command = None
    mcp = "mcp_servers:\n" + "\n".join(entry_lines(opts.mcp_name, opts.mcp_port, authorization, 2)) + "\n"
    api = "\n".join([
        "API_SERVER_ENABLED=true",
        "API_SERVER_KEY=<your own long random key; do not reuse the tokens above>",
        "API_SERVER_HOST=127.0.0.1",
        f"API_SERVER_PORT={API_SERVER_PORT}",
    ]) + "\n"
    skills = f"skills:\n  external_dirs:\n    - {layout.skills}\n"
    return Snippets(mcp, command, api, skills, display)


# -- editing config.yaml (text surgery; comments and ordering of the rest of the file are preserved) ----

_TOP_KEY = re.compile(r"^mcp_servers\s*:\s*(#.*)?$")
_ANY_KEY = re.compile(r"^mcp_servers\s*:")


def _newline(text: str) -> str:
    return "\r\n" if "\r\n" in text else "\n"


def _indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def _is_content(line: str) -> bool:
    return bool(line.strip()) and not line.lstrip().startswith("#")


def _block_bounds(lines: list[str], key_index: int) -> tuple[int, int]:
    """(first line after the key, index after the last content line) of the `mcp_servers` mapping."""
    end = len(lines)
    for i in range(key_index + 1, len(lines)):
        line = lines[i]
        if _is_content(line) and not line.startswith((" ", "\t")):
            end = i
            break
    last = end
    while last - 1 > key_index and not (_is_content(lines[last - 1]) or lines[last - 1].startswith((" ", "\t"))):
        last -= 1  # trailing blank lines and column-0 comments belong to whatever follows the block
    return key_index + 1, last


def _find_managed(lines: list[str], lo: int, hi: int, name: str) -> tuple[int, int] | None:
    start = next((i for i in range(lo, hi) if lines[i].strip() == start_marker(name)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, hi) if lines[i].strip() == end_marker(name)), None)
    if end is None:
        raise ConfigConflict(f"found the start marker of '{name}' but not its end marker; fix the file by hand")
    return start, end


def _validate(text: str, name: str, port: int) -> None:
    try:
        import yaml  # optional: only used as a safety net when it happens to be installed
    except ImportError:
        return
    try:
        data = yaml.safe_load(text)
        url = data["mcp_servers"][name]["url"]
    except Exception as exc:
        raise ConfigConflict(f"the edited config.yaml would not parse as expected ({type(exc).__name__}); not writing it") from None
    if url != f"http://127.0.0.1:{port}/mcp":
        raise ConfigConflict("the edited config.yaml does not contain the expected server entry; not writing it")


def upsert_mcp_entry(text: str, name: str, port: int, authorization: str) -> tuple[str, str]:
    """Return (new text, 'added' | 'updated' | 'unchanged'). Raises ConfigConflict when the file is not safe to edit."""
    nl = _newline(text)
    lines = text.split(nl) if text else []
    key_index = next((i for i, line in enumerate(lines) if _TOP_KEY.match(line)), None)
    if key_index is None:
        if any(_ANY_KEY.match(line) for line in lines):
            raise ConfigConflict("`mcp_servers` is written inline (for example `{}`); add the server by hand with the printed snippet")
        body = ["mcp_servers:", *entry_lines(name, port, authorization, 2)]
        if lines and lines[-1] == "":
            lines.pop()
        if lines and lines[-1].strip():
            lines.append("")
        new = nl.join([*lines, *body]) + nl
        _validate(new, name, port)
        return new, "added"

    lo, hi = _block_bounds(lines, key_index)
    managed = _find_managed(lines, lo, hi, name)
    if managed:
        first, last = managed
        indent = _indent_of(lines[first])
        block = entry_lines(name, port, authorization, indent)
        if lines[first : last + 1] == block:
            return text, "unchanged"
        lines[first : last + 1] = block
        new = nl.join(lines)
        _validate(new, name, port)
        return new, "updated"

    contents = [lines[i] for i in range(lo, hi) if _is_content(lines[i])]
    if any(line.startswith("\t") for line in contents):
        raise ConfigConflict("config.yaml indents with tabs; edit it by hand")
    indent = _indent_of(contents[0]) if contents else 2
    if indent == 0:
        raise ConfigConflict("`mcp_servers` is not a mapping of servers; edit it by hand")
    for line in contents:
        if _indent_of(line) == indent and line.strip().startswith(f"{name}:"):
            raise ConfigConflict(
                f"mcp_servers already has an entry named '{name}' that this installer did not create; "
                "choose another name with --mcp-name or edit the file by hand"
            )
    lines[hi:hi] = entry_lines(name, port, authorization, indent)
    new = nl.join(lines)
    _validate(new, name, port)
    return new, "added"


def remove_mcp_entry(text: str, name: str) -> tuple[str, str]:
    """Remove the managed block of `name`; returns (new text, 'removed' | 'absent')."""
    nl = _newline(text)
    lines = text.split(nl) if text else []
    key_index = next((i for i, line in enumerate(lines) if _TOP_KEY.match(line)), None)
    if key_index is None:
        return text, "absent"
    lo, hi = _block_bounds(lines, key_index)
    managed = _find_managed(lines, lo, hi, name)
    if not managed:
        return text, "absent"
    first, last = managed
    del lines[first : last + 1]
    # If our entry was the only thing under a bare `mcp_servers:` key (the installer added the key), a lone
    # `mcp_servers:` would parse as null and trip a client that expects a mapping: take the key out as well.
    lo, hi = _block_bounds(lines, key_index)
    if lines[key_index].strip() == "mcp_servers:" and not any(_is_content(lines[i]) for i in range(lo, hi)):
        del lines[key_index:hi]
        if key_index > 0 and lines[key_index - 1] == "" and (key_index == len(lines) or lines[key_index] == ""):
            del lines[key_index - 1]  # the separating blank line the installer put before the key
    return nl.join(lines), "removed"


# -- editing .env --------------------------------------------------------------------------------------


def upsert_env(text: str, key: str, value: str) -> tuple[str, str]:
    """Set KEY=value in dotenv text, keeping everything else byte for byte. Returns (text, state)."""
    nl = _newline(text)
    lines = text.split(nl) if text else []
    pattern = re.compile(rf"^\s*(?:export\s+)?{re.escape(key)}\s*=")
    positions = [i for i, line in enumerate(lines) if pattern.match(line)]
    wanted = f"{key}={value}"
    if positions:
        if lines[positions[0]] == wanted and len(positions) == 1:
            return text, "unchanged"
        for i in reversed(positions[1:]):
            del lines[i]
        lines[positions[0]] = wanted
        return nl.join(lines), "updated"
    if lines and lines[-1] == "":
        lines.pop()
    lines.append(wanted)
    return nl.join(lines) + nl, "added"


def remove_env(text: str, key: str) -> tuple[str, str]:
    nl = _newline(text)
    lines = text.split(nl) if text else []
    pattern = re.compile(rf"^\s*(?:export\s+)?{re.escape(key)}\s*=")
    kept = [line for line in lines if not pattern.match(line)]
    if len(kept) == len(lines):
        return text, "absent"
    return nl.join(kept), "removed"
