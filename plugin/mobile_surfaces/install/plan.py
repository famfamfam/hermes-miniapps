"""Turns a request plus the current state of the host into a list of steps. Nothing here writes anything.

`plan_install` and `plan_uninstall` read the filesystem (through `Deps.fs`) to decide, for every step,
whether it would create, update or leave something unchanged; `execute.py` then runs exactly that list.
A plan never contains a secret: tokens are generated at execution time and are only ever written to files.
"""
from __future__ import annotations

import hashlib
import json
import re
import tomllib
from dataclasses import dataclass, field, replace
from pathlib import Path, PurePosixPath
from typing import Any

from . import hermes
from .effects import Deps, tree_digest
from .model import (
    BUILD_MEMORY_FLOOR, SCHEMA, TOKEN_ENV_VAR, InstallError, Layout, Limits, Options, check_posix_dir, make_layout,
    size_bytes,
)
from .render import DEFAULT_PATH, render_dropin, render_manifest, render_unit, sha256_text

TEMPLATE_EXCLUDE = ("node_modules", "dist", ".work")
# Hermes skills shipped with the plugin (directory name -> what the copy step says it is for).
SKILLS = {
    "surfaces-author": "Hermes skill for the interface author",
    "surfaces-connect-phone": "Hermes skill that hands the phone a one-time connection line",
}
# Never copied into the build snapshot: dev data (it holds the dev tokens), tests, caches, build output.
PLUGIN_EXCLUDE = (
    ".devhome", "tests", "skills", "__pycache__", ".pytest_cache", "build", "dist",
    "mobile_surfaces.egg-info", "mobile-surfaces.egg-info",
)
PROTECTED_HOMES = ("/root/", "/home/", "/run/user/")  # unreadable for a unit with ProtectHome=yes
MANAGED_HEADER = "# Managed by `python -m mobile_surfaces.install`"


# -- actions -------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Mkdir:
    path: PurePosixPath
    mode: int
    what: str = ""

    def describe(self) -> str:
        return f"mkdir  {self.mode:04o} {self.path}" + (f"   ({self.what})" if self.what else "")


@dataclass(frozen=True)
class WriteFile:
    path: PurePosixPath
    text: str
    mode: int
    what: str

    def describe(self) -> str:
        return f"write  {self.mode:04o} {self.path}   ({self.what})"


@dataclass(frozen=True)
class NewToken:
    """A random bearer token written straight to a file. The value is never held by the plan."""

    path: PurePosixPath
    what: str
    owner: str | None = None
    replace: bool = False

    def describe(self) -> str:
        who = f", owner {self.owner}" if self.owner else ""
        return f"token  0600 {self.path}   ({self.what}; random value written to the file only{who})"


@dataclass(frozen=True)
class CopyTree:
    src: Path
    dst: PurePosixPath
    exclude: tuple[str, ...]
    what: str

    def describe(self) -> str:
        return f"copy   {self.dst}   ({self.what}, from the checkout)"


@dataclass(frozen=True)
class CopyFile:
    src: str
    dst: PurePosixPath
    mode: int
    what: str

    def describe(self) -> str:
        return f"copy   {self.mode:04o} {self.dst}   ({self.what})"


@dataclass(frozen=True)
class Chmod:
    path: PurePosixPath
    mode: int
    what: str

    def describe(self) -> str:
        return f"chmod  {self.mode:04o} {self.path}   ({self.what})"


@dataclass(frozen=True)
class Chown:
    path: PurePosixPath
    user: str
    what: str

    def describe(self) -> str:
        return f"chown  {self.user} {self.path}   ({self.what})"


@dataclass(frozen=True)
class Run:
    argv: tuple[str, ...]
    what: str
    network: str | None = None  # what it downloads, if anything
    live_only: bool = True  # skipped when staging into --root
    allow_failure: bool = False
    cwd: PurePosixPath | None = None
    env: tuple[tuple[str, str], ...] = ()

    def describe(self) -> str:
        where = f" [in {self.cwd}]" if self.cwd else ""
        return f"exec   {' '.join(self.argv)}{where}   ({self.what})"


@dataclass(frozen=True)
class Remove:
    path: PurePosixPath
    what: str
    only_if_empty: bool = False

    def describe(self) -> str:
        return f"delete {self.path}   ({self.what})"


@dataclass(frozen=True)
class HermesFile:
    """An edit of a Hermes file (config.yaml or .env), always after a backup. Only with --write-hermes-config."""

    kind: str  # 'config' | 'env'
    op: str  # 'upsert' | 'remove'
    path: PurePosixPath
    what: str

    def describe(self) -> str:
        return f"edit   {self.path}   ({self.what}; backup first)"


Action = Mkdir | WriteFile | NewToken | CopyTree | CopyFile | Chmod | Chown | Run | Remove | HermesFile


@dataclass
class Step:
    action: Action
    state: str  # create | update | unchanged | run | remove
    note: str = ""

    @property
    def live_only(self) -> bool:
        """Steps that need the real host (commands, chown): a staging `--root` skips them."""
        return isinstance(self.action, Chown) or (isinstance(self.action, Run) and self.action.live_only)

    def changes(self, staging: bool) -> bool:
        return self.state != "unchanged" and not (staging and self.live_only)


@dataclass
class Plan:
    command: str
    opts: Options
    layout: Layout
    checkout: Path
    steps: list[Step] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    refusals: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    network: list[str] = field(default_factory=list)
    snippets: hermes.Snippets | None = None
    existing: dict[str, Any] | None = None
    hermes_home: PurePosixPath | None = None
    node_dir: PurePosixPath | None = None  # directory placed first in the unit's PATH
    node_source: str | None = None  # the executable --copy-node copies
    ports_to_check: list[tuple[str, int]] = field(default_factory=list)
    not_installed: bool = False  # uninstall: there is simply nothing of this name
    staging: bool = False  # files only: live-host steps are skipped, so they never count as changes

    @property
    def changes(self) -> list[Step]:
        return [s for s in self.steps if s.changes(self.staging)]

    def add(self, action: Action, state: str, note: str = "") -> None:
        self.steps.append(Step(action, state, note))


# -- reading the source checkout -----------------------------------------------------------------------


def check_checkout(checkout: Path, authoring: bool) -> list[str]:
    needed = ["plugin/pyproject.toml", "plugin/constraints.txt"] + [f"plugin/skills/{name}/SKILL.md" for name in SKILLS]
    if authoring:
        needed += ["templates/starter-app/package.json", "templates/starter-app/package-lock.json",
                   "packages/mobile-sdk/src/index.ts"]
    return [f"{rel} not found in {checkout} (pass --source DIR with a clone of the repository)"
            for rel in needed if not (checkout / rel).is_file()]


def package_version(checkout: Path) -> str:
    data = tomllib.loads((checkout / "plugin" / "pyproject.toml").read_text(encoding="utf-8"))
    return str(data["project"]["version"])


def source_digest(checkout: Path, opts: Options) -> str | None:
    """Fingerprint of what pip would install: the plugin sources (with constraints.txt), or the prebuilt wheel.
    An upgrade whose fingerprint matches the recorded one has nothing to reinstall."""
    if opts.wheelhouse is not None:
        wheels = sorted(opts.wheelhouse.glob("mobile_surfaces-*.whl")) if opts.wheelhouse.is_dir() else []
        return hashlib.sha256(wheels[-1].read_bytes()).hexdigest() if wheels else None
    return tree_digest(checkout / "plugin", PLUGIN_EXCLUDE)


def source_commit(deps: Deps, checkout: Path) -> str | None:
    result = deps.runner.run(["git", "-C", str(checkout), "rev-parse", "HEAD"], timeout=10)
    out = result.stdout.strip()
    return out if result.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", out) else None


# -- manifest ------------------------------------------------------------------------------------------


def read_manifest(deps: Deps, layout: Layout) -> dict[str, Any] | None:
    text = deps.fs.read_text(layout.manifest)
    if text is None:
        return None
    try:
        data = json.loads(text)
    except ValueError:
        return {"_unreadable": True}
    return data if isinstance(data, dict) else {"_unreadable": True}


def is_ours(manifest: dict[str, Any] | None, layout: Layout) -> bool:
    return bool(
        manifest and manifest.get("schema") == SCHEMA and manifest.get("name") == layout.name
        and manifest.get("scope") == layout.scope
    )


def options_from_manifest(manifest: dict[str, Any], base: Options) -> Options:
    """`base` carries scope, name and prefix (they locate the record); everything else comes from the record."""
    o = manifest.get("options", {})
    return replace(
        base,
        host=o.get("host", base.host), api_port=o.get("apiPort", base.api_port), mcp_port=o.get("mcpPort", base.mcp_port),
        authoring=bool(o.get("authoring", False)), copy_node=bool(o.get("copyNode", False)),
        build_timeout=o.get("buildTimeout", base.build_timeout), limits=Limits.from_dict(o.get("limits")),
        user_sandbox=bool(o.get("userSandbox", False)), hermes_user=o.get("hermesUser"),
        mcp_name=o.get("mcpName", base.mcp_name),
    )


def build_manifest(
    layout: Layout, opts: Options, version: str, commit: str | None, digests: dict[str, Any], node_dir: PurePosixPath | None,
    complete: bool,
) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "name": layout.name,
        "scope": layout.scope,
        "complete": complete,
        "package": {"name": "mobile-surfaces", "version": version},
        "source": {"commit": commit},
        "paths": {
            "prefix": str(layout.prefix), "state": str(layout.state_dir), "secrets": str(layout.secrets_dir),
            "unit": str(layout.unit),
        },
        "options": {
            "host": opts.host, "apiPort": opts.api_port, "mcpPort": opts.mcp_port, "authoring": opts.authoring,
            "copyNode": opts.copy_node, "nodeDir": str(node_dir) if node_dir else None,
            "buildTimeout": opts.build_timeout, "limits": opts.limits.as_dict() if opts.limits else None,
            "userSandbox": opts.user_sandbox, "hermesUser": opts.hermes_user, "mcpName": opts.mcp_name,
        },
        "digests": digests,
    }


# -- small helpers -------------------------------------------------------------------------------------


def _mode_ok(actual: int | None, wanted: int) -> bool:
    return actual is None or actual == wanted  # None: the platform has no meaningful modes (Windows)


def _dir_step(plan: Plan, deps: Deps, path: PurePosixPath, mode: int, what: str) -> None:
    if not deps.fs.exists(path):
        plan.add(Mkdir(path, mode, what), "create")
    elif _mode_ok(deps.fs.mode(path), mode):
        plan.add(Mkdir(path, mode, what), "unchanged")
    else:
        plan.add(Mkdir(path, mode, what), "update", f"mode is {deps.fs.mode(path):04o}")


def _file_step(plan: Plan, deps: Deps, path: PurePosixPath, text: str, mode: int, what: str) -> None:
    current = deps.fs.read_text(path)
    if current is None:
        plan.add(WriteFile(path, text, mode, what), "create")
    elif current == text and _mode_ok(deps.fs.mode(path), mode):
        plan.add(WriteFile(path, text, mode, what), "unchanged")
    else:
        plan.add(WriteFile(path, text, mode, what), "update")


def hermes_home_for(opts: Options, deps: Deps) -> PurePosixPath:
    if opts.hermes_home is not None:
        return opts.hermes_home
    env = deps.host.environ.get("HERMES_HOME", "")
    try:
        if env:
            return check_posix_dir(env, "HERMES_HOME")
    except InstallError:
        pass
    return deps.host.home / ".hermes"


def authorization_for(deps: Deps, layout: Layout, opts: Options) -> str | None:
    """Header value to put into config.yaml; None when the token does not exist yet. Held only in memory."""
    if opts.hermes_token_mode == "env":
        return hermes.env_authorization()
    token = deps.fs.read_text(layout.mcp_token)
    return None if token is None else "Bearer " + token.strip()


# -- install -------------------------------------------------------------------------------------------


def plan_install(opts: Options, deps: Deps, checkout: Path | None = None) -> Plan:
    host = deps.host
    checkout = checkout or host.checkout
    layout = make_layout(opts, host.home, host.environ)
    plan = Plan("install", opts, layout, checkout, staging=deps.staging)
    fs = deps.fs

    # -- the request itself
    plan.refusals += check_checkout(checkout, opts.authoring)
    if not host.is_linux:
        plan.warnings.append(
            f"this machine is '{host.platform}', not Linux: the plan is computed for a Linux target and `apply` "
            "will refuse to run here (use --root DIR to stage the files)."
        )
    if layout.scope == "system" and not host.is_root and not deps.staging:
        plan.warnings.append("system scope needs root: run `apply` with sudo, or use --scope user.")
    interpreter_real = host.resolve(opts.python or host.python).replace("\\", "/")
    if layout.scope == "system" and interpreter_real.startswith(PROTECTED_HOMES):
        plan.warnings.append(
            f"the Python interpreter resolves to {interpreter_real}, which the sandboxed unit cannot read "
            "(ProtectHome=yes); apply will refuse. Use a system Python, for example --python /usr/bin/python3."
        )
    if not opts.loopback_only:
        plan.warnings.append(
            f"--host {opts.host}: the phone API will listen on a non-loopback address over plain HTTP. Keep it on "
            "127.0.0.1 and reach it through an SSH tunnel or VPN, or put a TLS reverse proxy in front. "
            "The MCP endpoint stays on 127.0.0.1 regardless."
        )
    if opts.hermes_user and not opts.write_hermes_config:
        plan.notes.append(f"the MCP token will be owned by '{opts.hermes_user}' so that Hermes can read it.")

    # -- what is on the host already
    existing = read_manifest(deps, layout)
    plan.existing = existing
    ours = is_ours(existing, layout)
    if existing and existing.get("schema", SCHEMA) != SCHEMA and not existing.get("_unreadable"):
        plan.refusals.append(f"{layout.manifest} was written by a different installer version (schema {existing.get('schema')}).")
    elif existing is not None and not ours:
        plan.refusals.append(
            f"{layout.manifest} exists but does not describe an install named '{layout.name}' in {layout.scope} scope; "
            "choose another --name or remove it by hand."
        )
    elif not ours:
        taken = [p for p in (layout.prefix, layout.unit) if fs.exists(p)]
        if taken:
            plan.refusals.append(
                f"{', '.join(map(str, taken))} already exist and were not created by this installer; "
                "choose another --name (or --prefix), or remove them by hand."
            )
    if ours and not opts.upgrade:
        state = "complete" if existing.get("complete") else "incomplete"
        plan.refusals.append(
            f"'{layout.name}' is already installed here ({state}). Use `status` to inspect it, `apply --upgrade` to "
            "refresh it (tokens and data are kept), or `uninstall` first."
        )
    if opts.upgrade and not ours:
        plan.refusals.append("--upgrade: there is no install of this name to upgrade; run `apply` without --upgrade.")
    leftovers = [p for p in layout.data_paths() if fs.exists(p)]
    if leftovers and not ours:
        if opts.reuse_data:
            plan.notes.append(
                f"reusing data left by an earlier install ({', '.join(map(str, leftovers))}); existing tokens are kept."
            )
        else:
            plan.refusals.append(
                f"data from an earlier install exists ({', '.join(map(str, leftovers))}). Pass --reuse-data to keep and "
                "reuse it (existing tokens are not regenerated), or remove it by hand."
            )

    # -- artifacts
    version = package_version(checkout) if (checkout / "plugin" / "pyproject.toml").is_file() else "0"
    node_dir, node_source = _node_setup(plan, opts, deps, layout)
    plan.node_dir, plan.node_source = node_dir, node_source
    unit_text = render_unit(layout, opts, node_dir)
    dropin_text = render_dropin(layout, opts)
    if opts.authoring and opts.limits and opts.limits.memory_max:
        cap = size_bytes(opts.limits.memory_max)
        if cap is not None and cap < BUILD_MEMORY_FLOOR:
            plan.warnings.append(
                f"MemoryMax={opts.limits.memory_max} is below 450M: an interface build (tsc + vite) may be killed. "
                "Raise it, or leave --with-authoring off on this host."
            )
    if not opts.authoring:
        plan.notes.append("interface authoring is off: Hermes gets the data tools only. Add --with-authoring (needs Node.js) to enable builds.")

    template_src = checkout / "templates" / "starter-app"
    lock_sha = None
    if opts.authoring and (template_src / "package-lock.json").is_file():
        lock_sha = sha256_text((template_src / "package-lock.json").read_text(encoding="utf-8"))
    digests = {
        "unit": sha256_text(unit_text),
        "dropin": sha256_text(dropin_text) if dropin_text else None,
        "templateLock": lock_sha,
        "plugin": source_digest(checkout, opts),
    }
    commit = source_commit(deps, checkout) if (checkout / "plugin" / "pyproject.toml").is_file() else None

    # -- steps
    _dir_step(plan, deps, layout.prefix, 0o755, "code, virtualenv and read-only data of the service")
    secrets_mode = 0o711 if opts.hermes_user else 0o700
    _dir_step(plan, deps, layout.secrets_dir, secrets_mode, "bearer tokens, root only" if not opts.hermes_user else "bearer tokens; traversable so that the Hermes user can read its own file")
    if layout.scope == "user":
        _dir_step(plan, deps, layout.state_dir, 0o700, "databases and bundles")
    else:
        plan.notes.append(f"{layout.state_dir} is created by systemd on first start (StateDirectory=, mode 0700, dynamic user).")

    for name, purpose in SKILLS.items():
        _copy_step(plan, deps, checkout / "plugin" / "skills" / name, layout.skills / name, ("__pycache__",), purpose)
    if opts.authoring:
        _copy_step(plan, deps, template_src, layout.templates, TEMPLATE_EXCLUDE, "interface template (read-only for the service)")
        _copy_step(plan, deps, checkout / "packages" / "mobile-sdk" / "src", layout.sdk, (), "SDK sources for builds")
        if opts.copy_node and node_source:
            target = layout.node_bin / "node"
            same = fs.read_bytes(target) is not None and _same_file(deps, node_source, target)
            plan.add(CopyFile(node_source, target, 0o755, "private copy of the Node binary"), "unchanged" if same else "create")

    same_code = bool(
        ours and existing and existing.get("complete") and digests["plugin"] is not None
        and existing.get("digests", {}).get("plugin") == digests["plugin"] and (deps.staging or deps.fs.exists(layout.python))
    )
    _python_steps(plan, deps, opts, layout, checkout, version, ours, same_code)
    if opts.authoring:
        has_modules = fs.is_dir(layout.templates / "node_modules")
        lock_changed = bool(ours and (existing or {}).get("digests", {}).get("templateLock") != lock_sha)
        npm = ["npm", "ci", "--ignore-scripts", "--no-audit", "--no-fund"]
        if opts.npm_cache is not None:
            npm += ["--offline", "--cache", str(opts.npm_cache)]
        what = "install the pinned build dependencies, no package scripts"
        network = None if opts.npm_cache is not None else "npm registry: the packages pinned in templates/starter-app/package-lock.json"
        plan.add(Run(tuple(npm), what, network, cwd=layout.templates, env=(("npm_config_update_notifier", "false"),)),
                 "unchanged" if has_modules and not lock_changed else "run")

    _token_steps(plan, deps, opts, layout)
    _file_step(plan, deps, layout.unit, unit_text, 0o644, "systemd unit")
    unit_step = plan.steps[-1]
    dropin_step_state = "unchanged"
    if dropin_text is not None:
        foreign = fs.read_text(layout.dropin)
        if foreign is not None and not foreign.startswith(MANAGED_HEADER):
            plan.refusals.append(
                f"{layout.dropin} exists and was not created by this installer; move it away or drop --limits "
                "(the installer never overwrites an administrator's drop-in)."
            )
        else:
            _file_step(plan, deps, layout.dropin, dropin_text, 0o644, "resource limits drop-in")
            dropin_step_state = plan.steps[-1].state
    else:
        current = fs.read_text(layout.dropin)
        if current is not None and current.startswith(MANAGED_HEADER):
            plan.add(Remove(layout.dropin, "resource limits are no longer requested"), "remove")
            dropin_step_state = "remove"
    ctl = layout.systemctl
    changed_units = unit_step.state != "unchanged" or dropin_step_state != "unchanged"
    plan.add(Run((*ctl, "daemon-reload"), "make systemd read the unit"), "run" if changed_units else "unchanged")
    if opts.enable:
        plan.add(Run((*ctl, "enable", layout.unit_name), "start at boot" if layout.scope == "system" else "start at login"), "run")
    if opts.start:
        plan.add(Run((*ctl, "restart", layout.unit_name), "start (or restart) the service"), "run")
    elif ours and changed_units:
        plan.notes.append(f"the unit changed: restart it when convenient ({' '.join(ctl)} restart {layout.unit_name}).")
    elif ours and not same_code:
        plan.notes.append(
            "the installed code was refreshed: the running service still uses the old one until it restarts "
            f"({' '.join(ctl)} restart {layout.unit_name})."
        )
    if not opts.start and not ours:
        plan.notes.append(f"the service is not started by this install; start it with: {' '.join(ctl)} start {layout.unit_name}")
    if layout.scope == "user":
        plan.notes.append("a user service stops when the last login session ends; run `loginctl enable-linger` once to keep it running.")

    if opts.write_hermes_config:
        _hermes_steps(plan, deps, opts, layout)
    plan.snippets = hermes.snippets(layout, opts, hermes_home_for(opts, deps), host.home)
    plan.hermes_home = hermes_home_for(opts, deps)

    # The record is written twice: first marked incomplete (so a half-finished run is recognisable and can be
    # resumed with --upgrade), last marked complete. A run that changes nothing writes it only once.
    final_text = render_manifest(build_manifest(layout, opts, version, commit, digests, node_dir, complete=True))
    current = fs.read_text(layout.manifest)
    partial_written = bool(plan.changes)
    if partial_written:
        partial_text = render_manifest(build_manifest(layout, opts, version, commit, digests, node_dir, complete=False))
        plan.steps.insert(1, Step(
            WriteFile(layout.manifest, partial_text, 0o644, "install record, marked incomplete until the end"),
            "create" if current is None else "update",
        ))
    # Once the incomplete record has been written the file differs from `current`, which was read before the run:
    # comparing the closing write with it would skip it and leave the install marked incomplete for good (an
    # upgrade whose only change is a restart did exactly that).
    if current is None:
        closing = "create"
    elif partial_written or current != final_text:
        closing = "update"
    else:
        closing = "unchanged"
    plan.add(WriteFile(layout.manifest, final_text, 0o644, "install record, complete"), closing)

    plan.ports_to_check = _ports(opts, existing if ours else None)
    plan.network = _network(plan)
    return plan


def _same_file(deps: Deps, source: str, target: PurePosixPath) -> bool:
    try:
        return Path(source).read_bytes() == deps.fs.read_bytes(target)
    except OSError:
        return False


def _ports(opts: Options, existing: dict[str, Any] | None) -> list[tuple[str, int]]:
    wanted = [(opts.host, opts.api_port), ("127.0.0.1", opts.mcp_port)]
    if existing:  # an upgrade: the running service already owns its own ports
        old = existing.get("options", {})
        return [(h, p) for h, p in wanted if p not in (old.get("apiPort"), old.get("mcpPort"))]
    return wanted


def _copy_step(plan: Plan, deps: Deps, src: Path, dst: PurePosixPath, exclude: tuple[str, ...], what: str) -> None:
    want = tree_digest(src, exclude)
    have = deps.fs.tree_digest(dst, exclude)
    state = "create" if have is None else ("unchanged" if have == want else "update")
    plan.add(CopyTree(src, dst, exclude, what), state)


def _node_setup(plan: Plan, opts: Options, deps: Deps, layout: Layout) -> tuple[PurePosixPath | None, str | None]:
    """(directory for PATH in the unit, binary that --copy-node copies). Problems become warnings here and
    refusals in the live preflight, because planning may happen on a machine without Node."""
    if not opts.authoring:
        return None, None
    host = deps.host
    found = host.which(opts.node or "node")
    if opts.copy_node:
        if not found:
            plan.warnings.append("--copy-node: no `node` found on this machine; apply will refuse.")
            return layout.node_bin, None
        return layout.node_bin, host.realpath(found)
    if not found:
        plan.warnings.append("Node.js was not found on this machine; apply will refuse (install Node.js 20 or newer).")
        return None, None
    real = host.realpath(found).replace("\\", "/")
    if layout.scope == "system" and real.startswith(PROTECTED_HOMES):
        plan.warnings.append(
            f"node resolves to {real}, which the sandboxed unit cannot read (ProtectHome=yes). "
            "Install Node.js system-wide, or pass --copy-node to use a private copy; apply will refuse otherwise."
        )
    directory = PurePosixPath(found.replace("\\", "/")).parent
    if str(directory) in DEFAULT_PATH:
        return None, None
    try:
        check_posix_dir(str(directory), "node directory")
    except InstallError:
        plan.warnings.append(f"node is at {found}; its directory has characters not allowed in a unit file: use --copy-node.")
        return None, None
    return directory, None


def _python_steps(
    plan: Plan, deps: Deps, opts: Options, layout: Layout, checkout: Path, version: str, ours: bool, same_code: bool
) -> None:
    py = opts.python or deps.host.python
    plan.add(Run((py, "-m", "venv", str(layout.venv)), "isolated virtualenv for the service"),
             "unchanged" if deps.fs.exists(layout.python) else "run")
    constraints = checkout / "plugin" / "constraints.txt"
    pip = [str(layout.python), "-m", "pip", "install", "--disable-pip-version-check", "--no-input",
           "-c", str(constraints).replace("\\", "/")]
    if ours:
        pip.append("--force-reinstall")  # same version number, possibly new code: reinstall it and its pinned dependencies
    env = (("PIP_DISABLE_PIP_VERSION_CHECK", "1"), ("PYTHONNOUSERSITE", "1"))
    todo = "unchanged" if same_code else "run"
    if opts.wheelhouse is not None:
        pip += ["--no-index", "--find-links", str(opts.wheelhouse).replace("\\", "/"), f"mobile-surfaces=={version}"]
        plan.add(Run(tuple(pip), "install the prebuilt wheels; no network", None, env=env), todo)
    else:
        build = layout.prefix / ".build" / "plugin"
        plan.add(CopyTree(checkout / "plugin", build, PLUGIN_EXCLUDE, "source snapshot for the build"),
                 "unchanged" if same_code else "create")
        pip.append(str(build))
        plan.add(Run(tuple(pip), "install the package pinned by constraints.txt",
                     "PyPI (or the configured index): fastapi, uvicorn, mcp and their dependencies, plus setuptools to build",
                     env=env), todo)
        plan.add(Remove(build.parent, "remove the build snapshot"), "unchanged" if same_code else "remove")
    plan.add(Run((str(layout.python), "-I", "-c", "import devserver, ms_admin, mobile_surfaces, mobile_surfaces_core"),
                 "check that the installed package imports"), todo)


def _token_steps(plan: Plan, deps: Deps, opts: Options, layout: Layout) -> None:
    for path, what, owner in (
        (layout.api_token, "phone API bearer token", None),
        (layout.mcp_token, "MCP bearer token", opts.hermes_user),
    ):
        exists = deps.fs.exists(path)
        if not exists:
            plan.add(NewToken(path, what, owner), "create")
        elif opts.rotate_tokens:
            plan.add(NewToken(path, what, owner, replace=True), "update", "rotated: the old value stops working")
        else:
            plan.add(NewToken(path, what, owner), "unchanged", "kept")
            if owner and deps.fs.owned_by(path, owner) is False:
                # An upgrade that newly names --hermes-user: the kept token is still root's and Hermes could not read it.
                plan.add(Chown(path, owner, what), "update", f"owner is not {owner}")
            mode = deps.fs.mode(path)
            if mode is not None and mode & 0o077:
                plan.add(Chmod(path, 0o600, what), "update", f"mode is {mode:04o}")
                plan.warnings.append(f"{path} was readable by others (mode {mode:04o}); it will be set to 0600. Consider --rotate-tokens.")


def _hermes_steps(plan: Plan, deps: Deps, opts: Options, layout: Layout) -> None:
    home = hermes_home_for(opts, deps)
    config = home / "config.yaml"
    env_file = home / ".env"
    if not deps.fs.is_dir(home):
        plan.refusals.append(
            f"--write-hermes-config: {home} does not exist. Pass --hermes-home with the directory that holds Hermes' "
            "config.yaml (the installer never creates a Hermes home)."
        )
        return
    plan.notes.append(f"--write-hermes-config: Hermes files under {home} will be edited after a backup of each.")
    plan.notes.append(
        "pair the phone as the approver BEFORE Hermes connects: until a device is paired, app_publish publishes "
        "without review (the installer never pairs a device)."
    )
    authorization = authorization_for(deps, layout, opts) or hermes.env_authorization()
    text = deps.fs.read_text(config)
    state = "create"
    try:
        _, edit = hermes.upsert_mcp_entry(text or "", opts.mcp_name, opts.mcp_port, authorization)
        if text is not None:
            state = {"added": "create", "updated": "update", "unchanged": "unchanged"}[edit]
    except hermes.ConfigConflict as exc:
        plan.refusals.append(f"{config}: {exc}")
    if opts.rotate_tokens and opts.hermes_token_mode == "inline" and state == "unchanged":
        state = "update"  # the header carries the token, which is about to change
    plan.add(HermesFile("config", "upsert", config, f"mcp_servers.{opts.mcp_name}"), state)
    if opts.hermes_token_mode == "env":
        token = deps.fs.read_text(layout.mcp_token)
        current = deps.fs.read_text(env_file)
        state = "create"
        if token is not None and current is not None:
            _, st = hermes.upsert_env(current, TOKEN_ENV_VAR, token.strip())
            state = {"added": "create", "updated": "update", "unchanged": "unchanged"}[st]
        if opts.rotate_tokens and state == "unchanged":
            state = "update"  # compared with the old token file; the file is replaced earlier in this run
        plan.add(HermesFile("env", "upsert", env_file, TOKEN_ENV_VAR + " (value read from the token file)"), state)


def _network(plan: Plan) -> list[str]:
    seen: list[str] = []
    for step in plan.steps:
        if isinstance(step.action, Run) and step.action.network and step.state != "unchanged":
            if step.action.network not in seen:
                seen.append(step.action.network)
    return seen


# -- uninstall -----------------------------------------------------------------------------------------


def plan_uninstall(opts: Options, deps: Deps) -> Plan:
    host = deps.host
    layout = make_layout(opts, host.home, host.environ)
    plan = Plan("uninstall", opts, layout, host.checkout, staging=deps.staging)
    fs = deps.fs
    existing = read_manifest(deps, layout)
    plan.existing = existing
    if existing is None:
        leftovers = [p for p in (layout.prefix, layout.unit, *layout.data_paths()) if fs.exists(p)]
        if leftovers:
            plan.refusals.append(
                f"no install record at {layout.manifest}, but {', '.join(map(str, leftovers))} exist. They were not "
                "created by this installer (or the install was removed by hand); nothing will be deleted."
            )
        else:
            plan.refusals.append(f"nothing to uninstall: no install named '{layout.name}' in {layout.scope} scope.")
            plan.not_installed = True
        return plan
    if not is_ours(existing, layout):
        plan.refusals.append(f"{layout.manifest} does not describe an install named '{layout.name}' in {layout.scope} scope; nothing will be deleted.")
        return plan
    recorded = existing.get("paths", {})
    expected = {"prefix": str(layout.prefix), "state": str(layout.state_dir), "secrets": str(layout.secrets_dir), "unit": str(layout.unit)}
    if recorded != expected:
        plan.refusals.append("the install record lists different paths than the ones computed for this --name/--scope/--prefix; pass the same options as at install time.")
        return plan
    if opts.purge and not opts.yes:
        plan.refusals.append("--purge deletes the databases and the tokens for good: add --yes to confirm.")
    ctl = layout.systemctl
    plan.add(Run((*ctl, "stop", layout.unit_name), "stop the service", allow_failure=True), "run")
    plan.add(Run((*ctl, "disable", layout.unit_name), "do not start it any more", allow_failure=True), "run")
    plan.add(Remove(layout.unit, "systemd unit"), "remove" if fs.exists(layout.unit) else "unchanged")
    dropin = fs.read_text(layout.dropin)
    if dropin is not None:
        plan.add(Remove(layout.dropin, "resource limits drop-in"), "remove")
    if fs.exists(layout.dropin_dir):
        plan.add(Remove(layout.dropin_dir, "drop-in directory, only if nothing else is in it", only_if_empty=True), "remove")
    plan.add(Run((*ctl, "daemon-reload"), "make systemd forget the unit", allow_failure=True), "run")
    plan.add(Remove(layout.prefix, "virtualenv, templates, skill and install record"), "remove")
    if opts.purge:
        for path in layout.data_paths():
            if fs.exists(path):
                plan.add(Remove(path, "data and tokens (--purge)"), "remove")
    else:
        kept = [str(p) for p in layout.data_paths() if fs.exists(p)]
        if kept:
            plan.notes.append(
                f"kept: {', '.join(kept)} (databases and tokens). A later `apply --reuse-data` picks them up again; "
                "`uninstall --purge --yes` deletes them."
            )
    if opts.write_hermes_config:
        home = hermes_home_for(opts, deps)
        config_text, env_text = fs.read_text(home / "config.yaml"), fs.read_text(home / ".env")
        try:
            config_state = "remove" if config_text and hermes.remove_mcp_entry(config_text, opts.mcp_name)[1] == "removed" else "unchanged"
        except hermes.ConfigConflict as exc:
            plan.refusals.append(f"{home / 'config.yaml'}: {exc}")
            config_state = "unchanged"
        env_state = "remove" if env_text and hermes.remove_env(env_text, TOKEN_ENV_VAR)[1] == "removed" else "unchanged"
        plan.add(HermesFile("config", "remove", home / "config.yaml", f"remove mcp_servers.{opts.mcp_name}"), config_state)
        plan.add(HermesFile("env", "remove", home / ".env", f"remove {TOKEN_ENV_VAR}"), env_state)
    else:
        plan.notes.append(
            f"Hermes was not touched: remove the mcp_servers.{opts.mcp_name} block (and {TOKEN_ENV_VAR} in .env) "
            "from your Hermes configuration by hand, or re-run with --write-hermes-config; then /reload-mcp in Hermes."
        )
    return plan
