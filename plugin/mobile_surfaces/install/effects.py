"""Side effects behind small, replaceable objects: filesystem, subprocesses, probes.

The installer logic only talks to `Fs`, `Runner` and the callables in `Deps`; tests substitute
recording fakes, and a staging `--root` maps the whole target filesystem into a directory.
"""
from __future__ import annotations

import hashlib
import os
import re
import secrets
import shutil
import socket
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Callable, Mapping, Sequence

from .model import HostEnv, InstallError, is_loopback

MIN_LOGICAL_PARTS = 3  # '/', 'opt', 'name': Fs.remove never touches anything shallower


# -- filesystem ----------------------------------------------------------------------------------------


def tree_digest(root: Path, exclude: Sequence[str] = ()) -> str | None:
    """sha256 over the relative names and contents of a directory tree; None when it does not exist.

    Names in `exclude` (at any depth) and symbolic links are ignored, so the digest of a template copy
    with an installed `node_modules` equals the digest of the source checkout."""
    if not root.is_dir():
        return None
    entries: list[tuple[str, str]] = []
    for current, dirs, files in os.walk(root, followlinks=False):
        dirs[:] = sorted(d for d in dirs if d not in exclude and not os.path.islink(os.path.join(current, d)))
        for name in sorted(files):
            full = Path(current, name)
            if name in exclude or full.is_symlink():
                continue
            entries.append((full.relative_to(root).as_posix(), hashlib.sha256(full.read_bytes()).hexdigest()))
    digest = hashlib.sha256()
    for rel, content in sorted(entries):
        digest.update(f"{rel}\0{content}\n".encode("utf-8"))
    return digest.hexdigest()


class Fs:
    """The target host's filesystem. With `root`, every path is placed below that directory (like DESTDIR)."""

    def __init__(self, root: Path | None = None) -> None:
        self.root = root

    def real(self, path: PurePosixPath) -> Path:
        if self.root is not None:
            return self.root.joinpath(*path.parts[1:])
        return Path(str(path))

    def exists(self, path: PurePosixPath) -> bool:
        return os.path.lexists(self.real(path))

    def is_dir(self, path: PurePosixPath) -> bool:
        return self.real(path).is_dir()

    def read_bytes(self, path: PurePosixPath) -> bytes | None:
        try:
            return self.real(path).read_bytes()
        except (FileNotFoundError, NotADirectoryError):
            return None

    def read_text(self, path: PurePosixPath) -> str | None:
        data = self.read_bytes(path)
        return None if data is None else data.decode("utf-8", errors="replace")

    def mode(self, path: PurePosixPath) -> int | None:
        """Permission bits, or None where the platform has none worth comparing (Windows)."""
        if os.name == "nt":
            return None
        try:
            return stat.S_IMODE(os.stat(self.real(path)).st_mode)
        except (FileNotFoundError, NotADirectoryError):
            return None

    def owner(self, path: PurePosixPath) -> tuple[int, int] | None:
        """(uid, gid) of an existing file, or None (missing, or a platform without owners)."""
        if os.name == "nt":
            return None
        try:
            info = os.stat(self.real(path))
        except (FileNotFoundError, NotADirectoryError):
            return None
        return info.st_uid, info.st_gid

    def owned_by(self, path: PurePosixPath, user: str) -> bool | None:
        """Whether `user` owns the file: True or False when that can be told, None when it cannot (no user
        database on this platform, an unknown user, a missing file)."""
        if os.name == "nt":
            return None
        try:
            import pwd

            uid = pwd.getpwnam(user).pw_uid
        except (ImportError, KeyError):
            return None
        ids = self.owner(path)
        return None if ids is None else ids[0] == uid

    def chown_ids(self, path: PurePosixPath, uid: int, gid: int) -> None:
        """Give a file back to its previous owner after an atomic replace made it ours."""
        os.chown(self.real(path), uid, gid)  # type: ignore[attr-defined,unused-ignore]

    def listdir(self, path: PurePosixPath) -> list[str]:
        try:
            return sorted(os.listdir(self.real(path)))
        except (FileNotFoundError, NotADirectoryError):
            return []

    def mkdir(self, path: PurePosixPath, mode: int) -> None:
        real = self.real(path)
        real.mkdir(parents=True, exist_ok=True)
        os.chmod(real, mode)  # explicit: the process umask must not decide who can enter the directory

    def write_bytes(self, path: PurePosixPath, data: bytes, mode: int) -> None:
        """Atomic replace; the temporary file is created with the final mode, so a secret is never readable."""
        real = self.real(path)
        real.parent.mkdir(parents=True, exist_ok=True)
        tmp = real.with_name(f".{real.name}.tmp{os.getpid()}")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_BINARY", 0)
        fd = os.open(tmp, flags, mode)
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(data)
                handle.flush()
                os.fsync(handle.fileno())
            os.chmod(tmp, mode)
            os.replace(tmp, real)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise

    def write_text(self, path: PurePosixPath, text: str, mode: int) -> None:
        self.write_bytes(path, text.encode("utf-8"), mode)

    def chmod(self, path: PurePosixPath, mode: int) -> None:
        os.chmod(self.real(path), mode)

    def chown(self, path: PurePosixPath, user: str) -> None:
        shutil.chown(self.real(path), user=user)  # type: ignore[arg-type]

    def copyfile(self, src: Path, dst: PurePosixPath, mode: int) -> None:
        self.write_bytes(dst, src.read_bytes(), mode)

    def copytree(self, src: Path, dst: PurePosixPath, exclude: Sequence[str] = ()) -> None:
        """Make `dst` mirror `src` (files 0644, directories 0755). Names in `exclude` are neither copied
        nor deleted, which is how an installed `node_modules` survives an upgrade of its template."""
        self.mkdir(dst, 0o755)
        wanted: set[PurePosixPath] = set()
        for current, dirs, files in os.walk(src, followlinks=False):
            dirs[:] = sorted(d for d in dirs if d not in exclude and not os.path.islink(os.path.join(current, d)))
            rel = PurePosixPath(Path(current).relative_to(src).as_posix())
            target_dir = dst / rel if str(rel) != "." else dst
            wanted.add(target_dir)
            if target_dir != dst:
                self.mkdir(target_dir, 0o755)
            for name in sorted(files):
                source = Path(current, name)
                if name in exclude or source.is_symlink():
                    continue
                target = target_dir / name
                wanted.add(target)
                data = source.read_bytes()
                if self.read_bytes(target) != data or self.mode(target) not in (None, 0o644):
                    self.write_bytes(target, data, 0o644)
        self._prune(dst, wanted, exclude)

    def _prune(self, directory: PurePosixPath, wanted: set[PurePosixPath], exclude: Sequence[str]) -> None:
        for name in self.listdir(directory):
            child = directory / name
            if name in exclude:
                continue
            if child not in wanted:
                self.remove(child)
            elif self.real(child).is_dir() and not self.real(child).is_symlink():
                self._prune(child, wanted, exclude)

    def tree_digest(self, path: PurePosixPath, exclude: Sequence[str] = ()) -> str | None:
        return tree_digest(self.real(path), exclude)

    def remove(self, path: PurePosixPath) -> None:
        if len(path.parts) < MIN_LOGICAL_PARTS:
            raise InstallError(f"refusing to remove {path}: too close to the filesystem root")
        real = self.real(path)
        if real.is_symlink() or real.is_file():
            real.unlink()
        elif real.is_dir():
            shutil.rmtree(real)


# -- subprocesses --------------------------------------------------------------------------------------


@dataclass(frozen=True)
class RunResult:
    returncode: int
    stdout: str = ""
    stderr: str = ""


class Runner:
    def run(
        self, argv: Sequence[str], *, env: Mapping[str, str] | None = None, cwd: str | None = None,
        timeout: float | None = None,
    ) -> RunResult:
        raise NotImplementedError


class SubprocessRunner(Runner):
    def run(
        self, argv: Sequence[str], *, env: Mapping[str, str] | None = None, cwd: str | None = None,
        timeout: float | None = None,
    ) -> RunResult:
        try:
            proc = subprocess.run(
                list(argv), capture_output=True, encoding="utf-8", errors="replace", env=dict(env) if env else None,
                cwd=cwd, timeout=timeout, stdin=subprocess.DEVNULL, check=False,
            )
        except FileNotFoundError as exc:
            return RunResult(127, "", str(exc))
        except subprocess.TimeoutExpired:
            return RunResult(124, "", f"timed out after {timeout}s")
        return RunResult(proc.returncode, proc.stdout or "", proc.stderr or "")


def tail(text: str, lines: int = 12) -> str:
    chunk = [line for line in text.strip().splitlines() if line.strip()]
    return "\n".join(chunk[-lines:])


# -- probes (loopback only) ----------------------------------------------------------------------------


def tcp_listening(host: str, port: int) -> bool:
    """True when something already accepts connections on the address the service would bind."""
    target = {"0.0.0.0": "127.0.0.1", "::": "::1", "localhost": "127.0.0.1"}.get(host, host)
    try:
        with socket.create_connection((target, port), timeout=0.5):
            return True
    except OSError:
        return False


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: object, **kwargs: object) -> None:  # type: ignore[override]
        return None


def http_status(url: str, headers: Mapping[str, str], timeout: float = 5.0) -> int | None:
    """Status code of a GET, or None when the connection fails. Only loopback URLs are ever contacted,
    so a token read from a file cannot be sent anywhere else, and redirects are not followed."""
    match = re.match(r"^http://(\[[^\]]+\]|[^:/]+)(?::\d+)?/", url)
    if not match or not is_loopback(match.group(1).strip("[]")):
        raise ValueError("health probes only contact loopback addresses")
    request = urllib.request.Request(url, headers=dict(headers), method="GET")
    opener = urllib.request.build_opener(_NoRedirect)
    try:
        with opener.open(request, timeout=timeout) as response:
            return int(response.status)
    except urllib.error.HTTPError as exc:
        return int(exc.code)
    except (urllib.error.URLError, OSError):
        return None


# -- dependency bundle ---------------------------------------------------------------------------------


def new_token() -> str:
    return secrets.token_urlsafe(32)


def timestamp() -> str:
    return time.strftime("%Y%m%d-%H%M%S")


@dataclass
class Deps:
    host: HostEnv
    fs: Fs
    runner: Runner
    token_factory: Callable[[], str]
    now: Callable[[], str]
    port_listening: Callable[[str, int], bool]
    http_status: Callable[[str, Mapping[str, str]], int | None]
    out: Callable[[str], None]
    err: Callable[[str], None]
    staging: bool = False


def detect_host(environ: Mapping[str, str] | None = None) -> HostEnv:
    environ = os.environ if environ is None else environ
    euid = os.geteuid() if hasattr(os, "geteuid") else None
    if sys.platform.startswith(("linux", "darwin")):
        home = PurePosixPath(Path.home().as_posix())
    else:  # planning from a workstation: pretend a conventional Linux home
        user = re.sub(r"[^A-Za-z0-9_-]", "_", environ.get("USERNAME") or environ.get("USER") or "user")
        home = PurePosixPath("/home") / user
    return HostEnv(
        platform=sys.platform,
        euid=euid,
        home=home,
        environ=dict(environ),
        python=sys.executable,
        python_version=(sys.version_info.major, sys.version_info.minor),
        checkout=Path(__file__).resolve().parents[3],
        which=shutil.which,
        realpath=os.path.realpath,
    )


def default_deps(root: Path | None, host: HostEnv | None = None) -> Deps:
    return Deps(
        host=host or detect_host(),
        fs=Fs(root),
        runner=SubprocessRunner(),
        token_factory=new_token,
        now=timestamp,
        port_listening=tcp_listening,
        http_status=http_status,
        out=lambda line: print(line, file=sys.stdout),
        err=lambda line: print(line, file=sys.stderr),
        staging=root is not None,
    )
