"""Runs a plan. The only module that changes the host, and only through `Deps`."""
from __future__ import annotations

import logging
import os
import re
from pathlib import Path, PurePosixPath

from . import hermes
from .effects import Deps, tail
from .model import MIN_NODE_MAJOR, MIN_PYTHON, MIN_SYSTEMD, SECRET_FILE_MODE, TOKEN_ENV_VAR, Exit, InstallError
from .plan import (
    PROTECTED_HOMES, Chmod, Chown, CopyFile, CopyTree, HermesFile, Mkdir, NewToken, Plan, Remove, Run, Step,
    WriteFile, authorization_for,
)


log = logging.getLogger("mobile_surfaces.install")


def preflight(plan: Plan, deps: Deps) -> None:
    """Checks that need the live host. All problems are collected, then reported together; nothing was changed."""
    host, opts, layout = deps.host, plan.opts, plan.layout
    problems = list(plan.refusals)
    if opts.wheelhouse is not None:
        if not opts.wheelhouse.is_dir() or not any(opts.wheelhouse.glob("mobile_surfaces-*.whl")):
            problems.append(f"--wheelhouse {opts.wheelhouse}: no mobile_surfaces-*.whl found in it (see README.md)")
    if opts.npm_cache is not None and not opts.npm_cache.is_dir():
        problems.append(f"--npm-cache {opts.npm_cache}: not a directory")
    if not deps.staging:
        if not host.is_linux:
            problems.append(
                f"`apply` runs on the Linux host that will run the service; this machine is '{host.platform}'. "
                "Use --root DIR to stage the files, or `plan` to review."
            )
        if layout.scope == "system" and not host.is_root:
            problems.append("system scope needs root: run with sudo, or install with --scope user.")
        if not host.which("systemctl"):
            problems.append("systemctl was not found: this host does not appear to run systemd.")
        elif layout.scope == "system":
            problems += _systemd_problems(deps)
        problems += _python_problems(plan, deps)
        if opts.authoring:
            problems += _node_problems(plan, deps)
        for bind_host, port in plan.ports_to_check:
            if deps.port_listening(bind_host, port):
                problems.append(f"{bind_host}:{port} already accepts connections; choose another port (--api-port/--mcp-port) or stop what uses it.")
        if opts.hermes_user:
            if deps.runner.run(["id", "-u", opts.hermes_user]).returncode != 0:
                problems.append(f"--hermes-user {opts.hermes_user}: no such user on this host.")
    if problems:
        raise InstallError("refused, nothing was changed:\n  - " + "\n  - ".join(dict.fromkeys(problems)))


def _systemd_problems(deps: Deps) -> list[str]:
    """The system unit hands root-only token files to a dynamic user with LoadCredential= (systemd 247)."""
    result = deps.runner.run(["systemctl", "--version"], timeout=15)
    match = re.match(r"systemd (\d+)", result.stdout.strip())
    if result.returncode != 0 or not match:
        return ["could not read the systemd version (`systemctl --version`); systemd 247 or newer is required."]
    if int(match.group(1)) < MIN_SYSTEMD:
        return [f"systemd {match.group(1)} is too old: the system service needs {MIN_SYSTEMD} or newer (LoadCredential=). "
                "Use --scope user, or upgrade the distribution."]
    return []


def _python_problems(plan: Plan, deps: Deps) -> list[str]:
    opts, host = plan.opts, deps.host
    problems: list[str] = []
    interpreter = opts.python or host.python
    # A virtualenv is a set of links to its base interpreter: if that lives under /root or /home, the sandboxed
    # service (ProtectHome=yes) could not start it. Same lesson as Node in the reference deployment.
    real = host.resolve(interpreter).replace("\\", "/")
    if plan.layout.scope == "system" and real.startswith(PROTECTED_HOMES):
        problems.append(
            f"the Python interpreter resolves to {real}, which the sandboxed service cannot read (ProtectHome=yes); "
            "use a system Python, for example --python /usr/bin/python3."
        )
    if opts.python:
        result = deps.runner.run([opts.python, "-c", "import sys; print('%d.%d' % sys.version_info[:2])"], timeout=20)
        match = re.fullmatch(r"(\d+)\.(\d+)", result.stdout.strip())
        if result.returncode != 0 or not match:
            return problems + [f"--python {opts.python}: cannot run it ({tail(result.stderr, 2) or 'no output'})"]
        version = (int(match.group(1)), int(match.group(2)))
    else:
        version = host.python_version
    if version < MIN_PYTHON:
        problems.append(f"Python {version[0]}.{version[1]} is too old: the service needs {MIN_PYTHON[0]}.{MIN_PYTHON[1]} or newer (pass --python).")
    return problems


def _node_problems(plan: Plan, deps: Deps) -> list[str]:
    opts, host, layout = plan.opts, deps.host, plan.layout
    problems: list[str] = []
    node = host.which(opts.node or "node")
    if not node:
        return ["--with-authoring needs Node.js (node on PATH, or --node PATH); see README.md"]
    if not host.which("npm"):
        problems.append("--with-authoring needs npm (it installs the pinned build dependencies once).")
    result = deps.runner.run([node, "--version"], timeout=20)
    match = re.match(r"v(\d+)\.", result.stdout.strip())
    if result.returncode != 0 or not match:
        problems.append(f"`{node} --version` failed; is it a working Node.js?")
    elif int(match.group(1)) < MIN_NODE_MAJOR:
        problems.append(f"Node.js {result.stdout.strip()} is too old: the interface toolchain needs {MIN_NODE_MAJOR} or newer.")
    real = host.realpath(node).replace("\\", "/")
    if layout.scope == "system" and not opts.copy_node and real.startswith(PROTECTED_HOMES):
        problems.append(
            f"node resolves to {real}, which the sandboxed service cannot read (ProtectHome=yes); "
            "install Node.js system-wide or pass --copy-node."
        )
    return problems


# -- execution -----------------------------------------------------------------------------------------


def execute(plan: Plan, deps: Deps) -> None:
    # A root shell with umask 077 would make the virtualenv unreadable for the service's own user.
    previous = os.umask(0o022)
    try:
        for step in plan.steps:
            if step.state == "unchanged":
                continue
            _announce(step, deps)
            _run_step(step, plan, deps)
    finally:
        os.umask(previous)


def _announce(step: Step, deps: Deps) -> None:
    action = step.action
    skipped = deps.staging and ((isinstance(action, Run) and action.live_only) or isinstance(action, Chown))
    deps.out(f"  {step.state:<9}{action.describe()}{'  [skipped: staging --root]' if skipped else ''}")
    log.info("%s: %s", step.state, action.describe())  # descriptions never contain secret values


def _run_step(step: Step, plan: Plan, deps: Deps) -> None:
    action, fs = step.action, deps.fs
    if isinstance(action, Mkdir):
        fs.mkdir(action.path, action.mode)
    elif isinstance(action, WriteFile):
        fs.write_text(action.path, action.text, action.mode)
    elif isinstance(action, NewToken):
        token = deps.token_factory()
        if len(token) < 32:
            raise InstallError("the token generator returned a short value; refusing to write it", Exit.FAILED)
        fs.write_text(action.path, token + "\n", SECRET_FILE_MODE)
        del token
        if action.owner and not deps.staging:
            fs.chown(action.path, action.owner)
    elif isinstance(action, CopyTree):
        fs.copytree(action.src, action.dst, action.exclude)
    elif isinstance(action, CopyFile):
        fs.copyfile(Path(action.src), action.dst, action.mode)
    elif isinstance(action, Chmod):
        fs.chmod(action.path, action.mode)
    elif isinstance(action, Chown):
        if not deps.staging:
            fs.chown(action.path, action.user)
    elif isinstance(action, Remove):
        if action.only_if_empty:
            if fs.exists(action.path) and not fs.listdir(action.path):
                fs.remove(action.path)
        elif fs.exists(action.path):
            fs.remove(action.path)
    elif isinstance(action, Run):
        _run_command(action, deps)
    elif isinstance(action, HermesFile):
        _edit_hermes(action, plan, deps)


def _run_command(action: Run, deps: Deps) -> None:
    if action.live_only and deps.staging:
        return
    env = {**deps.host.environ, **dict(action.env)}
    cwd = str(deps.fs.real(action.cwd)) if action.cwd else None
    result = deps.runner.run(action.argv, env=env, cwd=cwd, timeout=1800)
    if result.returncode == 0 or action.allow_failure:
        return
    detail = tail(result.stderr or result.stdout)
    hint = ""
    if "ensurepip" in (result.stderr + result.stdout):
        hint = "\nOn Debian/Ubuntu install the venv module first: apt install python3-venv"
    raise InstallError(
        f"step failed (exit {result.returncode}): {' '.join(action.argv)}\n{detail}{hint}\n"
        "The install is incomplete. Fix the cause and re-run with --upgrade to resume, or run `uninstall`.",
        Exit.FAILED,
    )


def _backup(path: PurePosixPath, deps: Deps) -> PurePosixPath:
    fs = deps.fs
    target = path.parent / f"{path.name}.bak.surfaces.{deps.now()}"
    counter = 1
    while fs.exists(target):
        counter += 1
        target = path.parent / f"{path.name}.bak.surfaces.{deps.now()}-{counter}"
    original = fs.read_bytes(path)
    assert original is not None
    fs.write_bytes(target, original, fs.mode(path) or 0o600)
    owner = fs.owner(path)
    if owner is not None and not deps.staging:
        fs.chown_ids(target, *owner)  # the copy belongs to whoever owns the file it protects
    return target


def _edit_hermes(action: HermesFile, plan: Plan, deps: Deps) -> None:
    fs, opts, layout = deps.fs, plan.opts, plan.layout
    text = fs.read_text(action.path)
    if action.kind == "config" and action.op == "upsert":
        authorization = authorization_for(deps, layout, opts)
        if authorization is None:
            raise InstallError("the MCP token file is missing; cannot write the Hermes configuration", Exit.FAILED)
        new, state = hermes.upsert_mcp_entry(text or "", opts.mcp_name, opts.mcp_port, authorization)
    elif action.kind == "config":
        new, state = hermes.remove_mcp_entry(text or "", opts.mcp_name)
    elif action.op == "upsert":
        token = fs.read_text(layout.mcp_token)
        if token is None:
            raise InstallError("the MCP token file is missing; cannot write the Hermes .env", Exit.FAILED)
        new, state = hermes.upsert_env(text or "", TOKEN_ENV_VAR, token.strip())
    else:
        new, state = hermes.remove_env(text or "", TOKEN_ENV_VAR)
    if state in ("unchanged", "absent"):
        return
    mode = fs.mode(action.path) if text is not None else None
    owner = fs.owner(action.path) if text is not None else None
    if text is not None:
        deps.out(f"            backup  {_backup(action.path, deps)}")
    default_mode = 0o600
    fs.write_text(action.path, new, mode if mode is not None else default_mode)
    if owner is not None and not deps.staging:
        # The atomic replace made the file ours (root's): Hermes, which owns it, must keep reading it.
        fs.chown_ids(action.path, *owner)
