"""Types, validation and path layout of the server installer. Standard library only.

Everything here is pure: no filesystem access, no subprocesses. Paths that belong to the *target* Linux
host are `PurePosixPath` so that planning gives the same answer on any machine the installer is
reviewed on (including Windows); paths of the local checkout stay ordinary `Path` objects.
"""
from __future__ import annotations

import ipaddress
import re
from dataclasses import dataclass
from enum import IntEnum
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping

SCHEMA = 1
DEFAULT_NAME = "hermes-surfaces"
DEFAULT_MCP_NAME = "surfaces"
LOOPBACK = "127.0.0.1"
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "::1", "localhost"})
MIN_PYTHON = (3, 11)
MIN_NODE_MAJOR = 20
MIN_SYSTEMD = 247  # LoadCredential= (hands root-only token files to a dynamic user)
BUILD_MEMORY_FLOOR = 450 * 1024 * 1024  # measured: a full interface build peaks near 200 MB; 450M is the unit ceiling
SECRET_FILE_MODE = 0o600
TOKEN_ENV_VAR = "MOBILE_SURFACES_MCP_TOKEN"

# Characters allowed in any path or name that ends up in a unit file. Narrow on purpose: a unit line is
# split on spaces and expands `%` and `$`, so anything fancier would need quoting rules we do not want.
_SAFE_PATH = re.compile(r"^/[A-Za-z0-9_./@+-]*$")
_NAME = re.compile(r"^[a-z][a-z0-9-]{1,39}$")
_USER = re.compile(r"^[a-z_][a-z0-9_-]{0,31}$")
_HOSTNAME = re.compile(r"^(?=.{1,253}$)[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$")
_SIZE = re.compile(r"^([1-9][0-9]{0,6})([KMGT]?)$")
_CPU = re.compile(r"^[1-9][0-9]{0,3}%$")


class Exit(IntEnum):
    OK = 0
    FAILED = 1  # a step failed while running
    USAGE = 2  # bad command line (argparse uses this too)
    REFUSED = 3  # the request is unsafe or impossible here; nothing was changed
    NOT_INSTALLED = 4  # status/uninstall: no install of this name
    DEGRADED = 5  # status: installed, but something is wrong


class InstallError(Exception):
    """A request that is refused or a step that failed; `code` becomes the process exit status."""

    def __init__(self, message: str, code: Exit = Exit.REFUSED) -> None:
        super().__init__(message)
        self.code = code


# -- validation --------------------------------------------------------------------------------------


def check_name(value: str) -> str:
    if not _NAME.match(value):
        raise InstallError(f"--name {value!r}: use 2-40 characters, lower-case letters, digits and '-', starting with a letter")
    return value


def check_posix_dir(value: str, what: str) -> PurePosixPath:
    """An absolute path on the target host, restricted to characters that are safe inside a unit file."""
    if not _SAFE_PATH.match(value):
        raise InstallError(
            f"{what} {value!r}: must be an absolute POSIX path of the target host made of letters, digits and _ . / @ + -"
        )
    path = PurePosixPath(value)
    if ".." in path.parts or path == PurePosixPath("/"):
        raise InstallError(f"{what} {value!r}: must not be '/' or contain '..'")
    return path


def check_host(value: str) -> str:
    try:
        ipaddress.ip_address(value)
        return value
    except ValueError:
        pass
    if not _HOSTNAME.match(value):
        raise InstallError(f"--host {value!r}: not an IP address or host name")
    return value


def is_loopback(host: str) -> bool:
    if host in LOOPBACK_HOSTS:
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


def check_port(value: int, what: str) -> int:
    if not 1024 <= value <= 65535:
        raise InstallError(f"{what} {value}: use a port between 1024 and 65535")
    return value


def check_user(value: str) -> str:
    if not _USER.match(value):
        raise InstallError(f"--hermes-user {value!r}: not a valid user name")
    return value


def check_size(value: str, what: str) -> str:
    if value != "infinity" and not _SIZE.match(value):
        raise InstallError(f"{what} {value!r}: use a size such as 256M or 1G")
    return value


def check_cpu(value: str) -> str:
    if not _CPU.match(value):
        raise InstallError(f"--cpu-quota {value!r}: use a percentage such as 50% or 100%")
    return value


def size_bytes(value: str) -> int | None:
    """Bytes in a systemd size such as 450M; None for 'infinity'."""
    if value == "infinity":
        return None
    match = _SIZE.match(value)
    assert match, value
    unit = {"": 1, "K": 1 << 10, "M": 1 << 20, "G": 1 << 30, "T": 1 << 40}[match.group(2)]
    return int(match.group(1)) * unit


# -- resource limits -----------------------------------------------------------------------------------


@dataclass(frozen=True)
class Limits:
    """Values of the `resources.conf` drop-in; None means the line is left out."""

    memory_high: str | None = None
    memory_max: str | None = None
    swap_max: str | None = None
    cpu_quota: str | None = None
    cpu_weight: int | None = None
    tasks_max: int | None = None
    nice: int | None = None
    io_weight: int | None = None

    def lines(self) -> list[str]:
        pairs = [
            ("MemoryHigh", self.memory_high), ("MemoryMax", self.memory_max), ("MemorySwapMax", self.swap_max),
            ("TasksMax", self.tasks_max), ("CPUQuota", self.cpu_quota), ("CPUWeight", self.cpu_weight),
            ("Nice", self.nice), ("IOWeight", self.io_weight),
        ]
        return [f"{key}={value}" for key, value in pairs if value is not None]

    def as_dict(self) -> dict[str, object]:
        return {key: value for key, value in self.__dict__.items() if value is not None}

    @classmethod
    def from_dict(cls, data: Mapping[str, object] | None) -> "Limits | None":
        if not data:
            return None
        known = {key: data[key] for key in cls.__dataclass_fields__ if key in data}
        return cls(**known) if known else None  # type: ignore[arg-type]


# What the isolated reference deployment measured: ~47 MiB for the data-only service and ~200 MiB
# peak for a session with full interface builds. The ceilings leave a margin and stay far below a 2 GiB host.
SMALL_DATA_ONLY = Limits(memory_high="128M", memory_max="192M", swap_max="64M", cpu_quota="25%",
                         tasks_max=32, nice=10, io_weight=10)
SMALL_WITH_BUILDS = Limits(memory_high="320M", memory_max="450M", swap_max="128M", cpu_quota="100%",
                           cpu_weight=20, tasks_max=128, nice=10, io_weight=10)


def resolve_limits(
    profile: str | None, authoring: bool, memory_high: str | None, memory_max: str | None, cpu_quota: str | None,
    current: Limits | None = None,
) -> Limits | None:
    """Limits for the drop-in. `profile` None keeps `current` (what an existing install recorded) and applies
    only the explicit overrides on top of it."""
    base = current or Limits()
    if profile == "small":
        base = SMALL_WITH_BUILDS if authoring else SMALL_DATA_ONLY
    elif profile == "none":
        base = Limits()
    elif profile is not None:
        raise InstallError(f"--limits {profile!r}: use 'none' or 'small'")
    values = dict(base.__dict__)
    if memory_high is not None:
        values["memory_high"] = check_size(memory_high, "--memory-high")
    if memory_max is not None:
        values["memory_max"] = check_size(memory_max, "--memory-max")
    if cpu_quota is not None:
        values["cpu_quota"] = check_cpu(cpu_quota)
    limits = Limits(**values)
    return limits if limits.lines() else None


# -- options -------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Options:
    """The resolved request (command line merged with what an existing install recorded)."""

    scope: str = "system"
    name: str = DEFAULT_NAME
    prefix: PurePosixPath | None = None
    host: str = LOOPBACK
    api_port: int = 8787
    mcp_port: int = 8788
    authoring: bool = False
    node: str | None = None
    copy_node: bool = False
    build_timeout: int = 150
    limits: Limits | None = None
    user_sandbox: bool = False
    hermes_user: str | None = None
    hermes_home: PurePosixPath | None = None
    write_hermes_config: bool = False
    hermes_token_mode: str = "env"
    mcp_name: str = DEFAULT_MCP_NAME
    wheelhouse: Path | None = None
    npm_cache: Path | None = None
    enable: bool = False
    start: bool = False
    upgrade: bool = False
    reuse_data: bool = False
    rotate_tokens: bool = False
    python: str | None = None
    purge: bool = False
    yes: bool = False

    def validate(self) -> "Options":
        if self.scope not in ("system", "user"):
            raise InstallError(f"--scope {self.scope!r}: use 'system' or 'user'")
        check_name(self.name)
        check_host(self.host)
        check_port(self.api_port, "--api-port")
        check_port(self.mcp_port, "--mcp-port")
        if self.api_port == self.mcp_port:
            raise InstallError("--api-port and --mcp-port must differ")
        if self.hermes_user is not None:
            check_user(self.hermes_user)
            if self.scope != "system":
                raise InstallError("--hermes-user only applies to --scope system")
        if self.hermes_token_mode not in ("env", "inline"):
            raise InstallError("--hermes-token-mode: use 'env' or 'inline'")
        if not 10 <= self.build_timeout <= 900:
            raise InstallError("--build-timeout: use 10..900 seconds")
        if not re.match(r"^[A-Za-z][A-Za-z0-9_-]{0,39}$", self.mcp_name):
            raise InstallError(f"--mcp-name {self.mcp_name!r}: use letters, digits, '_' and '-'")
        if self.npm_cache is not None and not self.authoring:
            raise InstallError("--npm-cache only makes sense with --with-authoring")
        if self.user_sandbox and self.scope != "user":
            raise InstallError("--user-sandbox only applies to --scope user (the system unit is always sandboxed)")
        if self.copy_node and not self.authoring:
            raise InstallError("--copy-node only makes sense with --with-authoring")
        if self.rotate_tokens and not self.upgrade:
            raise InstallError("--rotate-tokens is part of an upgrade: pass --upgrade as well")
        return self

    @property
    def loopback_only(self) -> bool:
        return is_loopback(self.host)


# -- target host ---------------------------------------------------------------------------------------


@dataclass(frozen=True)
class HostEnv:
    """What the installer needs to know about the machine it runs on (injectable for tests)."""

    platform: str
    euid: int | None
    home: PurePosixPath
    environ: Mapping[str, str]
    python: str
    python_version: tuple[int, int]
    checkout: Path
    which: Callable[[str], str | None]
    realpath: Callable[[str], str]

    def resolve(self, program: str) -> str:
        """Real path of a program. A bare name (`python3.12`) is looked up on PATH first: `realpath` alone
        would put it in the current directory and report a path that is not the one that runs."""
        if "/" not in program and "\\" not in program:
            program = self.which(program) or program
        return self.realpath(program)

    @property
    def is_linux(self) -> bool:
        return self.platform.startswith("linux")

    @property
    def is_root(self) -> bool:
        return self.euid == 0


# -- layout --------------------------------------------------------------------------------------------


@dataclass(frozen=True)
class Layout:
    scope: str
    name: str
    prefix: PurePosixPath
    state_dir: PurePosixPath
    secrets_dir: PurePosixPath
    unit: PurePosixPath

    @property
    def unit_name(self) -> str:
        return f"{self.name}.service"

    @property
    def venv(self) -> PurePosixPath:
        return self.prefix / "venv"

    @property
    def python(self) -> PurePosixPath:
        return self.venv / "bin" / "python"

    @property
    def templates(self) -> PurePosixPath:
        return self.prefix / "templates" / "starter-app"

    @property
    def sdk(self) -> PurePosixPath:
        return self.prefix / "sdk"

    @property
    def skills(self) -> PurePosixPath:
        return self.prefix / "skills"

    @property
    def node_bin(self) -> PurePosixPath:
        return self.prefix / "node" / "bin"

    @property
    def manifest(self) -> PurePosixPath:
        return self.prefix / "install.json"

    @property
    def work_dir(self) -> PurePosixPath:
        return self.state_dir / "work"

    @property
    def api_token(self) -> PurePosixPath:
        return self.secrets_dir / "api-token"

    @property
    def mcp_token(self) -> PurePosixPath:
        return self.secrets_dir / "mcp-token"

    @property
    def dropin_dir(self) -> PurePosixPath:
        return self.unit.parent / f"{self.unit_name}.d"

    @property
    def dropin(self) -> PurePosixPath:
        return self.dropin_dir / "resources.conf"

    @property
    def systemctl(self) -> tuple[str, ...]:
        return ("systemctl",) if self.scope == "system" else ("systemctl", "--user")

    def data_paths(self) -> list[PurePosixPath]:
        """Directories holding data that survives an uninstall (state and tokens)."""
        paths = [self.state_dir, self.secrets_dir]
        if self.scope == "system":
            paths.append(PurePosixPath("/var/lib/private") / self.name)  # where DynamicUser keeps StateDirectory=
        return paths


def _xdg(environ: Mapping[str, str], var: str, fallback: PurePosixPath) -> PurePosixPath:
    value = environ.get(var, "")
    # The XDG spec says a relative value must be ignored.
    if value.startswith("/") and _SAFE_PATH.match(value):
        return PurePosixPath(value)
    return fallback


def make_layout(opts: Options, home: PurePosixPath, environ: Mapping[str, str]) -> Layout:
    name = opts.name
    if opts.scope == "system":
        prefix = opts.prefix or PurePosixPath("/opt") / name
        return Layout(
            "system", name, prefix,
            state_dir=PurePosixPath("/var/lib") / name,  # StateDirectory= with DynamicUser fixes this location
            secrets_dir=PurePosixPath("/etc") / name,
            unit=PurePosixPath("/etc/systemd/system") / f"{name}.service",
        )
    data = _xdg(environ, "XDG_DATA_HOME", home / ".local" / "share")
    state = _xdg(environ, "XDG_STATE_HOME", home / ".local" / "state")
    config = _xdg(environ, "XDG_CONFIG_HOME", home / ".config")
    for path in (data, state, config):
        if not _SAFE_PATH.match(str(path)):
            raise InstallError(f"{path}: the user directories must use only letters, digits and _ . / @ + -")
    return Layout(
        "user", name, opts.prefix or data / name,
        state_dir=state / name,
        secrets_dir=config / name,
        unit=config / "systemd" / "user" / f"{name}.service",
    )
